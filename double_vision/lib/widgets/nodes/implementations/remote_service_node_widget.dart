import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../models/auth_profile.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/remote/model_catalog.dart';
import '../../../services/remote/remote_request.dart';
import '../../../services/vault/key_vault.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// One service the node can dispatch to, as advertised on `authInput`.
///
/// A *reference*, not a credential: it carries the profile id, the endpoint, and
/// the vault handle, and the key is fetched only at dispatch time.
class ServiceRef {
  final String profileId;
  final String displayName;
  final AuthProvider provider;
  final String baseUrl;
  final String credentialRef;

  const ServiceRef({
    required this.profileId,
    required this.displayName,
    required this.provider,
    required this.baseUrl,
    required this.credentialRef,
  });

  /// Label shown in the dropdown — "Work Gemini Pro · Google Gemini".
  String get label =>
      displayName.isEmpty ? profileId : '$displayName · ${provider.label}';

  /// Enough to dispatch: an endpoint and a handle to redeem.
  bool get isValid => baseUrl.isNotEmpty && credentialRef.isNotEmpty;

  /// Every profile described by an `authInput` payload.
  ///
  /// Handles both shapes the Secure Settings node can send: the 1×5 single
  /// profile it emits today, and a multi-row AA listing several. Rows are grouped
  /// by row key (the profile id), so column order doesn't matter.
  static List<ServiceRef> fromAa(AaPayload aa) {
    final byRow = <String, Map<String, String>>{};
    for (var i = 0; i < aa.rows.length && i < aa.cols.length; i++) {
      if (i >= aa.vals.length) break;
      (byRow[aa.rows[i]] ??= {})[aa.cols[i]] = '${aa.vals[i]}';
    }
    return [
      for (final entry in byRow.entries)
        ServiceRef(
          profileId: entry.key,
          displayName: entry.value['displayName'] ?? '',
          provider: AuthProvider.byName(entry.value['provider']),
          baseUrl: entry.value['baseUrl'] ?? '',
          credentialRef: entry.value['credentialRef'] ?? '',
        ),
    ];
  }
}

/// Dispatches an upstream payload to a remote LLM / vision / API endpoint and
/// puts the response back on the graph — see `DESIGN.md` → "Remote Service node".
///
/// Ports: `dataInput` (AA, idx 0) is the payload, `authInput` (AA, idx 1) is what
/// the Secure Settings node publishes, `dataOutput` (AA, idx 0) is the result.
///
/// The credential never travels between nodes: `authInput` carries a
/// `credentialRef` handle, and the key is read from the vault at dispatch and
/// held only for the length of one request.
class RemoteServiceNodeWidget extends BaseNodeWidget {
  /// `authInput` port registration (idx 1); `dataInput` uses the canonical
  /// `onInputPort` (idx 0).
  final void Function(InputPort port)? onAuthInputPort;

  final bool authConnected;
  final void Function(PortRef source)? onAuthConnect;

  /// Injected in tests; defaults to the platform vault.
  final KeyVault? vault;

  /// HTTP seam. A fresh client per request, so cancelling can close it without
  /// affecting anything else.
  final http.Client Function() clientFactory;

  /// Asks the provider which models this credential can reach. Defaults to a
  /// catalogue sharing [clientFactory]; injected whole in tests.
  final ModelCatalog? catalog;

  const RemoteServiceNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.onAuthInputPort,
    this.authConnected = false,
    this.onAuthConnect,
    this.vault,
    this.clientFactory = http.Client.new,
    this.catalog,
  });

  @override
  State<RemoteServiceNodeWidget> createState() =>
      _RemoteServiceNodeWidgetState();
}

class _RemoteServiceNodeWidgetState
    extends BaseNodeState<RemoteServiceNodeWidget> {
  @override String   get nodeTitle => 'Remote Service';
  @override IconData get nodeIcon  => Icons.cloud_sync_outlined;
  @override double   get nodeWidth => 320;

  late final KeyVault _vault;
  late final InputPort _dataIn;
  late final InputPort _authIn;
  final OutputPort _out = OutputPort('dataOutput');

  late TextEditingController _model;

  AaPayload? _payload;
  List<ServiceRef> _services = const [];
  ServiceRef? _selected;

  RemotePhase _phase = RemotePhase.idle;
  int _bytes = 0;
  String? _detail;

  /// Non-null while a request is in flight — also the cancel handle.
  http.Client? _inFlight;
  bool _cancelled = false;

  late final ModelCatalog _catalog;

  /// Model ids the provider says this credential can reach, fetched on demand.
  List<String> _models = const [];
  bool _loadingModels = false;
  final GlobalKey _modelMenuKey = GlobalKey();

  bool get _busy => _inFlight != null;

  @override
  void initState() {
    super.initState();
    _vault = widget.vault ?? KeyVault();
    _catalog = widget.catalog ??
        ModelCatalog(clientFactory: widget.clientFactory);
    _model = TextEditingController(text: widget.initialParams?['model'] ?? '');

    _dataIn = InputPort('dataInput');
    _authIn = InputPort('authInput');
    initInputPort(_dataIn, _onData);
    widget.onAuthInputPort?.call(_authIn);
    _authIn.onDataArrived.listen(_onAuth);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _inFlight?.close();
    _model.dispose();
    _dataIn.dispose();
    _authIn.dispose();
    _out.dispose();
    super.dispose();
  }

  // ── Ingress ──────────────────────────────────────────────────────────────

  void _onData(AaPayload payload) {
    if (!mounted) return;
    setState(() => _payload = payload);
  }

  /// Merge the arriving profiles into the dropdown, keyed by profile id so a
  /// re-emission of the same profile updates rather than duplicates.
  void _onAuth(AaPayload payload) {
    if (!mounted) return;
    final merged = {for (final s in _services) s.profileId: s};
    for (final ref in ServiceRef.fromAa(payload)) {
      merged[ref.profileId] = ref;
    }
    final next = merged.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));

    setState(() {
      _services = next;
      // Auto-select the first valid profile, and re-resolve the current
      // selection so an updated base URL takes effect.
      final keep = _selected == null
          ? null
          : merged[_selected!.profileId];
      final previousId = _selected?.profileId;
      _selected = keep ?? next.where((s) => s.isValid).firstOrNull;
      if (_selected?.profileId != previousId) _models = const [];
      if (_selected != null) _fillModelDefault(_selected!.provider);
    });
    _persist();
  }

  /// Pre-fill the model box for [provider] when the user hasn't typed their own.
  /// Only Anthropic ships a default; other providers' ids vary per account, so a
  /// guess there would just 404.
  void _fillModelDefault(AuthProvider provider) {
    final current = _model.text.trim();
    final isAnotherDefault =
        RemoteRequest.defaultModels.values.contains(current);
    if (current.isEmpty || isAnotherDefault) {
      _model.text = RemoteRequest.defaultModels[provider] ?? '';
    }
  }

  void _persist() => saveParams({
        if (_selected != null) 'serviceProfileId': _selected!.profileId,
        'model': _model.text.trim(),
      });

  // ── Model catalogue ──────────────────────────────────────────────────────

  /// Offer the models this credential can reach, fetching the list on first use.
  ///
  /// The field stays editable: a provider's catalogue can omit an id that still
  /// works (a fine-tune, an alias, a private deployment), so the pick-list is a
  /// convenience over free text rather than a replacement for it.
  Future<void> _pickModel() async {
    final service = _selected;
    if (service == null || _busy || _loadingModels) return;

    if (_models.isEmpty) {
      setState(() {
        _loadingModels = true;
        _detail = 'Listing models…';
      });

      // Same resolution path as dispatch: the ref is redeemed against the vault,
      // never carried on the wire.
      final profile = await _vault.profileById(service.profileId);
      final apiKey = profile == null ? null : await _vault.secretFor(profile);
      final result = await _catalog.list(
        profile: profile ??
            AuthProfile(
              id: service.profileId,
              displayName: service.displayName,
              provider: service.provider,
              baseUrl: service.baseUrl,
              credentialRef: service.credentialRef,
              maxContextTokens: 0,
            ),
        apiKey: apiKey,
      );
      if (!mounted) return;

      setState(() {
        _loadingModels = false;
        _models = result.ids;
        _phase = result.error == null ? _phase : RemotePhase.error;
        _detail = result.error ?? '${result.ids.length} models available';
      });
      if (result.ids.isEmpty) return;
    }

    await _showModelMenu();
  }

  Future<void> _showModelMenu() async {
    final anchor = _modelMenuKey.currentContext;
    if (anchor == null || _models.isEmpty) return;

    final box = anchor.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await showMenu<String>(
      context: anchor,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy + box.size.height,
        overlay.size.width - topLeft.dx - box.size.width,
        0,
      ),
      items: [
        for (final id in _models)
          PopupMenuItem<String>(
            value: id,
            child: Text(id, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );

    if (chosen == null || !mounted) return;
    setState(() => _model.text = chosen);
    _persist();
  }

  // ── Dispatch ─────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final service = _selected;
    if (service == null || _busy) return;

    final prompt = _payload?.flattenText() ?? '';
    if (prompt.isEmpty) {
      setState(() {
        _phase = RemotePhase.error;
        _detail = 'No text in the dataInput payload';
      });
      return;
    }

    final client = widget.clientFactory();
    setState(() {
      _inFlight = client;
      _cancelled = false;
      _phase = RemotePhase.connecting;
      _bytes = 0;
      _detail = null;
    });
    _persist();

    // Resolve the credential through the vault. A ref only redeems on the
    // machine whose vault holds it, so a workflow shared with someone else
    // fails here with a clear message rather than a puzzling 401.
    final profile = await _vault.profileById(service.profileId);
    String? apiKey;
    if (profile != null) {
      apiKey = await _vault.secretFor(profile);
    }

    final request = RemoteRequest(
      client: client,
      onProgress: (phase, bytes) {
        if (!mounted || _inFlight != client) return;
        setState(() {
          _phase = phase;
          _bytes = bytes;
        });
      },
    );

    final result = await request.send(
      profile: profile ??
          AuthProfile(
            // No vault entry: dispatch will fail on the missing key, but keep
            // the endpoint so the error names the right service.
            id: service.profileId,
            displayName: service.displayName,
            provider: service.provider,
            baseUrl: service.baseUrl,
            credentialRef: service.credentialRef,
            maxContextTokens: 0,
          ),
      model: _model.text.trim(),
      prompt: prompt,
      apiKey: apiKey,
    );

    if (!mounted) return;

    // A cancel closes the client mid-flight, which the request layer reports as
    // a connection failure. Relabel it — the node knows it asked to stop.
    final finished = _cancelled
        ? RemoteResult(
            status: 'cancelled',
            errorMsg: 'Cancelled before completion',
            executionTimeMs: result.executionTimeMs,
            bytes: result.bytes,
          )
        : result;

    setState(() {
      _inFlight = null;
      _phase = finished.ok ? RemotePhase.done : RemotePhase.error;
      _detail = finished.ok
          ? '${finished.executionTimeMs} ms · ${finished.text.length} chars'
          : finished.errorMsg;
    });

    _out.emit(_resultAa(service, finished));
    client.close();
  }

  void _cancel() {
    final client = _inFlight;
    if (client == null) return;
    _cancelled = true;
    setState(() => _detail = 'Cancelling…');
    // Closing the client aborts the in-flight request; `_submit` finishes the
    // bookkeeping and emits a `cancelled` AA.
    client.close();
  }

  /// The 1×5 result matrix. Emitted on **every** outcome, success or not — a
  /// downstream node should be able to see a failure, not just infer it from
  /// silence.
  AaPayload _resultAa(ServiceRef service, RemoteResult r) {
    final row = _requestUuid();
    return AaPayload(
      rows: List.filled(5, row),
      cols: const [
        'text',
        'serviceProvider',
        'status',
        'executionTimeMs',
        'errorMsg',
      ],
      vals: [
        r.text,
        service.provider.name,
        r.status,
        r.executionTimeMs,
        r.errorMsg,
      ],
    );
  }

  /// Per-request row key. Time-ordered so results sort by dispatch, with a
  /// random-ish tail; avoids a uuid dependency for something that only has to be
  /// unique within a session's output.
  static String _requestUuid() {
    final now = DateTime.now();
    return 'request:${now.microsecondsSinceEpoch.toRadixString(36)}'
        '-${identityHashCode(now).toRadixString(36)}';
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'dataInput',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
        InputConnector(
          label: 'authInput',
          idx: 1,
          active: widget.authConnected,
          onConnect: widget.onAuthConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'dataOutput',
          idx: 0,
          active: _phase == RemotePhase.done ||
              widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(2)),
        if (_services.isEmpty)
          Text(
            'Waiting for authInput — wire a Secure Settings node',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          DropdownMenu<ServiceRef>(
            enableSearch: false,
            expandedInsets: EdgeInsets.zero,
            enabled: !_busy,
            label: const Text('Service / Resource'),
            initialSelection: _selected,
            onSelected: (s) {
              if (s == null) return;
              setState(() {
                _selected = s;
                // Another service means another catalogue.
                _models = const [];
              });
              _fillModelDefault(s.provider);
              _persist();
            },
            dropdownMenuEntries: [
              for (final s in _services)
                DropdownMenuEntry(
                  value: s,
                  label: s.label,
                  enabled: s.isValid,
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _model,
                enabled: !_busy,
                onChanged: (_) => _persist(),
                decoration: InputDecoration(
                  labelText: 'Model / Resource id',
                  hintText: _selected == null
                      ? 'model id'
                      : (RemoteRequest.defaultModels[_selected!.provider] ??
                          'pick or type an id'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: _modelMenuKey,
              onPressed: (_selected == null || _busy) ? null : _pickModel,
              icon: _loadingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_circle_down_outlined, size: 18),
              tooltip: 'Available models',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: _busy
              ? OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('Cancel Request'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error,
                  ),
                )
              : FilledButton.icon(
                  onPressed: _selected == null ? null : _submit,
                  icon: const Icon(Icons.send_outlined, size: 16),
                  label: const Text('Submit Request'),
                ),
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 5,
              backgroundColor: scheme.outlineVariant,
              // Indeterminate: providers don't send a content-length for a
              // generated reply, so there is no honest completion fraction.
              color: scheme.primary,
            ),
          ),
        ],
        const SizedBox(height: 8),
        _statusBar(theme, scheme),
        if (_payload != null) ...[
          const SizedBox(height: 4),
          Text(
            'payload · ${_payload!.distinctRows().length} rows',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _statusBar(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (_phase) {
      RemotePhase.idle => (scheme.outline, 'Idle'),
      RemotePhase.connecting => (scheme.primary, 'Connecting…'),
      RemotePhase.streaming => (
          scheme.primary,
          _bytes == 0
              ? 'Streaming response…'
              : 'Streaming response… $_bytes bytes',
        ),
      RemotePhase.done => (Colors.green, 'Complete'),
      RemotePhase.error => (scheme.error, 'Error'),
    };
    final detail = _detail;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail == null ? label : '$label · $detail',
            maxLines: 3,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
