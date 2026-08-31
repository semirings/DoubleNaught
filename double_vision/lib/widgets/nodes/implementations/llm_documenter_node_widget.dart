import 'dart:convert';

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
import '../base/execute_button.dart';
import '../base/input_connector.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// Which model generates each docstring. [local] needs no credential;
/// [gemini] is remote and needs a matching Secure Settings credential on
/// `authInput` before Execute enables — see [_LLMDocumenterNodeWidgetState.isReady].
///
/// Gemini, not a generic "remote" choice: `RemoteRequest.defaultModels`
/// deliberately ships no default model id for Gemini (unlike Anthropic's
/// `claude-opus-5`) — "the others vary per account and deployment, so they
/// stay blank rather than shipping a guess that 404s." That established
/// convention is why this entry's own model-id field starts blank rather
/// than pre-filled: there is no real Gemini id in this codebase to reuse,
/// and inventing one would be exactly the guessed-id risk that convention
/// avoids. The user fetches (via Available Models) or types one instead.
enum _ModelChoice { local, gemini }

/// Enriches an AST index with LLM-generated better_docstring column.
///
/// Takes the 7-column documented index from Function Extraction and
/// generates an improved docstring for every definition, either:
/// - **remotely** (default: [_ModelChoice.gemini]) — via a Secure Settings
///   credential connected on `authInput`, matching the selected Model's
///   provider. The prompt and the D4M merge are still the backend's
///   (`/llm/build-prompts`, `/llm/merge-docstrings`); only the LLM call
///   itself moves client-side, since the vault-redeemed API key must never
///   reach this backend.
/// - **locally** ([_ModelChoice.local], no credential ever needed) — the
///   backend's own fixed small model, via `/llm/enrich-ast`.
///
/// Ports: `astIndex` (in) the 7-column input; `authInput` (in, optional) a
/// Secure Settings credential — required for the Gemini choice, ignored for
/// local; `promptInput` (in, optional) an additive style/instruction hint
/// from a Prompt node — it never replaces the code-aware template, only
/// adds to it; `documented` (out) the 8-column enriched index.
///
/// Execute's readiness needs `astIndex` to have data AND, for the Gemini
/// choice specifically, a matching credential connected — selecting Gemini
/// with no (or the wrong) credential connected disables Execute rather than
/// silently falling back to the local model (`EXECUTION_MODEL.md` §5: no
/// silent substitution). `promptInput` stays independently optional either
/// way.
class LLMDocumenterNodeWidget extends BaseNodeWidget {
  final String? baseUrl;
  final http.Client Function() clientFactory;

  /// Called when an edge is dropped on `authInput`.
  final void Function(PortRef source)? onAuthConnect;

  /// Called when an edge is dropped on `promptInput`.
  final void Function(PortRef source)? onPromptConnect;

  /// Registers the `authInput` port.
  final void Function(InputPort port)? onAuthInputPort;

  /// Registers the `promptInput` port.
  final void Function(InputPort port)? onPromptInputPort;

  /// Whether `authInput` has an incoming edge.
  final bool authConnected;

  /// Whether `promptInput` has an incoming edge.
  final bool promptConnected;

  /// Vault seam; defaults to the real vault. Overridden by tests.
  final KeyVault? vault;

  /// Model-catalog seam; defaults to the real fetch. Overridden by tests.
  final ModelCatalog? modelCatalog;

  const LLMDocumenterNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.baseUrl,
    this.clientFactory = http.Client.new,
    this.onAuthConnect,
    this.onPromptConnect,
    this.onAuthInputPort,
    this.onPromptInputPort,
    this.authConnected = false,
    this.promptConnected = false,
    this.vault,
    this.modelCatalog,
  });

  @override
  State<LLMDocumenterNodeWidget> createState() =>
      _LLMDocumenterNodeWidgetState();
}

class _LLMDocumenterNodeWidgetState extends BaseNodeState<LLMDocumenterNodeWidget>
    with WaitGatedExecution<LLMDocumenterNodeWidget> {
  @override String   get nodeTitle    => 'LLM Documenter';
  @override IconData get nodeIcon     => Icons.cloud_sync_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'enriching';

  /// The only model the local path ever loads — see `llm_better_doc.py`'s
  /// own default. Not user-editable; used whenever no remote credential is
  /// connected.
  static const _localModelId = 'mlx-community/Phi-4-mini-instruct-4bit';

  late final KeyVault _vault;
  late final ModelCatalog _modelCatalog;

  late final InputPort _in;
  late final InputPort _authIn;
  late final InputPort _promptIn;
  final OutputPort _out = OutputPort('documented');

  late final TextEditingController _maxTokens;
  late final TextEditingController _temperature;
  late final TextEditingController _remoteModel;

  AaPayload? _incoming;
  AuthProfile? _authProfile;
  String? _promptHint;

  /// Defaults to [_ModelChoice.gemini] — this node's primary purpose is now
  /// remote-provider documentation generation; the local SLM remains a
  /// selectable, no-credential fallback, not the default.
  _ModelChoice _modelChoice = _ModelChoice.gemini;

  bool _fetchingModels = false;
  String? _modelFetchError;

  ({int rowsProcessed, int colCount, int failed})? _result;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely
  /// watch it. One client covers the whole run — build-prompts, every
  /// per-row remote call, and merge-docstrings alike — so closing it aborts
  /// whichever of those is actually in flight at cancel time. Null whenever
  /// nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. Checked after every await in
  /// [_enrich] (including inside the per-row remote loop) — a completed
  /// step whose captured generation no longer matches the current one
  /// belongs to a superseded or cancelled run and must not touch state or
  /// keep dispatching further rows.
  int _execGen = 0;

  bool get _isRemoteChoice => _modelChoice == _ModelChoice.gemini;

  /// Whether the connected credential (if any) actually matches the
  /// selected model choice — connecting an Anthropic profile while Gemini
  /// is selected must not silently dispatch to Anthropic (no silent
  /// substitution, `EXECUTION_MODEL.md` §5), so it counts the same as no
  /// credential at all for [isReady]'s purposes.
  bool get _matchingCredential =>
      _authProfile != null && _authProfile!.provider == AuthProvider.googleGemini;

  /// True for the local choice (no credential ever needed) or the remote
  /// choice with a matching credential connected.
  bool get _hasCredentialForChoice => !_isRemoteChoice || _matchingCredential;

  @override
  bool get isReady => _incoming != null && _hasCredentialForChoice;

  @override
  void initState() {
    super.initState();
    _vault = widget.vault ?? KeyVault();
    _modelCatalog = widget.modelCatalog ?? const ModelCatalog();
    _modelChoice = switch (widget.initialParams?['modelChoice']) {
      'local' => _ModelChoice.local,
      'gemini' => _ModelChoice.gemini,
      _ => _ModelChoice.gemini,
    };

    // Only the canonical port goes through initInputPort — it always calls
    // the single widget.onInputPort callback, so the other two register via
    // their own dedicated callbacks directly (same convention as
    // ModelClassifierNode's categoryIn).
    _in = InputPort('astIndex');
    initInputPort(_in, _onIngress);
    _in.onDisconnected.listen((_) => _dropIncoming());

    _authIn = InputPort('authInput');
    widget.onAuthInputPort?.call(_authIn);
    _authIn.onDataArrived.listen(_onAuthData);
    _authIn.onDisconnected.listen((_) => _dropAuth());

    _promptIn = InputPort('promptInput');
    widget.onPromptInputPort?.call(_promptIn);
    _promptIn.onDataArrived.listen(_onPromptData);
    _promptIn.onDisconnected.listen((_) => _dropPrompt());

    initOutputPort(_out);

    _maxTokens = TextEditingController(
      text: widget.initialParams?['maxTokens'] ?? '256',
    );
    _temperature = TextEditingController(
      text: widget.initialParams?['temperature'] ?? '0.7',
    );
    _remoteModel = TextEditingController(
      text: widget.initialParams?['remoteModel'] ?? '',
    );
  }

  @override
  void dispose() {
    _maxTokens.dispose();
    _temperature.dispose();
    _remoteModel.dispose();
    _in.dispose();
    _authIn.dispose();
    _promptIn.dispose();
    _out.dispose();
    _execClient?.close();
    super.dispose();
  }

  void _persist() => saveParams({
        'maxTokens': _maxTokens.text.trim(),
        'temperature': _temperature.text.trim(),
        'remoteModel': _remoteModel.text.trim(),
        'modelChoice': _modelChoice.name,
      });

  /// Drop the retained payload when the `astIndex` wire is cut or re-pointed,
  /// so [isReady] genuinely reflects "is there live data to act on" rather
  /// than lingering on a since-disconnected upstream's last delivery.
  void _dropIncoming() {
    if (!mounted || (_incoming == null && _result == null)) return;
    setState(() {
      _incoming = null;
      _result = null;
    });
    setIdle();
  }

  void _onIngress(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      // A new payload invalidates the previous run's output.
      _result = null;
    });
    maybeAutoFire();
  }

  void _dropAuth() {
    if (!mounted || _authProfile == null) return;
    setState(() {
      _authProfile = null;
      _modelFetchError = null;
      _result = null;
    });
    maybeAutoFire();
  }

  void _onAuthData(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _authProfile = AuthProfile.fromAa(payload);
      _modelFetchError = null;
      _result = null;
    });
    maybeAutoFire();
  }

  /// Switching model choice changes [isReady] itself (a remote choice with
  /// no matching credential is not ready) — applies live, per the approved
  /// spec, whether or not the node is mid-idle with data already queued.
  void _onModelChoiceChanged(_ModelChoice choice) {
    setState(() {
      _modelChoice = choice;
      _modelFetchError = null;
      _result = null;
    });
    _persist();
    setIdle();
    maybeAutoFire();
  }

  void _dropPrompt() {
    if (!mounted || _promptHint == null) return;
    setState(() {
      _promptHint = null;
      _result = null;
    });
    maybeAutoFire();
  }

  void _onPromptData(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _promptHint = payload.value('prompt');
      _result = null;
    });
    maybeAutoFire();
  }

  Uri _endpoint(String path) =>
      Uri.parse('${widget.baseUrl ?? "http://localhost:8000"}$path');

  @override
  void fire() => _enrich();

  Future<void> _enrich() async {
    final payload = _incoming;
    if (payload == null || !isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final client = widget.clientFactory();
    _execClient = client;

    try {
      if (_isRemoteChoice) {
        // isReady already required a matching credential, so this is
        // non-null — the explicit dropdown choice decides the dispatch
        // path, not merely "is some credential connected" (a mismatched
        // provider must not silently dispatch elsewhere).
        await _enrichRemote(payload, _authProfile!, client, gen);
      } else {
        await _enrichLocal(payload, client, gen);
      }
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      client.close();
    }
  }

  // ── Local path (unchanged shape: one backend call) ──────────────────────

  Future<void> _enrichLocal(
    AaPayload payload,
    http.Client client,
    int gen,
  ) async {
    // Unparseable text falls back to the field's own default rather than
    // blocking the run — same convention as Polyglot Exec's Timeout field.
    final maxTokens = int.tryParse(_maxTokens.text.trim()) ?? 256;
    final temperature = double.tryParse(_temperature.text.trim()) ?? 0.7;

    final request = http.Request('POST', _endpoint('/llm/enrich-ast'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'astIndex': {'rows': payload.rows, 'cols': payload.cols, 'vals': payload.vals},
        'modelId': _localModelId,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'promptHint': _promptHint ?? '',
      });

    final response = await client.send(request);
    final body = await response.stream.bytesToString();
    if (gen != _execGen || !mounted) return;

    if (response.statusCode != 200) {
      setError(jsonDecode(body)['detail'] ?? 'HTTP ${response.statusCode}');
      return;
    }

    final result = jsonDecode(body);
    _finish(
      AaPayload(
        rows: List<String>.from(result['enrichedIndex']['rows'] ?? []),
        cols: List<String>.from(result['enrichedIndex']['cols'] ?? []),
        vals: List.from(result['enrichedIndex']['vals'] ?? []),
      ),
      rowsProcessed: (result['rowsProcessed'] ?? 0) as int,
      failed: 0,
    );
  }

  // ── Remote path: build-prompts → per-row RemoteRequest → merge-docstrings ─

  Future<void> _enrichRemote(
    AaPayload payload,
    AuthProfile profile,
    http.Client client,
    int gen,
  ) async {
    final apiKey = await _vault.secretFor(profile);
    if (gen != _execGen || !mounted) return;

    final buildRequest = http.Request('POST', _endpoint('/llm/build-prompts'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'astIndex': {'rows': payload.rows, 'cols': payload.cols, 'vals': payload.vals},
        'promptHint': _promptHint ?? '',
      });
    final buildResponse = await client.send(buildRequest);
    final buildBody = await buildResponse.stream.bytesToString();
    if (gen != _execGen || !mounted) return;

    if (buildResponse.statusCode != 200) {
      setError(jsonDecode(buildBody)['detail'] ?? 'HTTP ${buildResponse.statusCode}');
      return;
    }

    final prompts = List<Map<String, dynamic>>.from(
      (jsonDecode(buildBody)['prompts'] as List?) ?? [],
    );
    if (prompts.isEmpty) {
      setError('No documentable definitions in this index');
      return;
    }

    final model = _remoteModel.text.trim();
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    final temperature = double.tryParse(_temperature.text.trim());
    final remote = RemoteRequest(client: client);

    final docstrings = <String, String>{};
    var failed = 0;
    for (final entry in prompts) {
      if (gen != _execGen || !mounted) return; // cancelled mid-loop

      final result = await remote.send(
        profile: profile,
        model: model,
        prompt: entry['prompt'] as String,
        apiKey: apiKey,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      if (gen != _execGen || !mounted) return; // cancelled while awaiting

      if (result.ok && result.text.isNotEmpty) {
        docstrings[entry['rowKey'] as String] = result.text;
      } else {
        failed++;
      }
    }

    if (docstrings.isEmpty) {
      setError('All $failed remote call(s) failed — nothing to merge');
      return;
    }

    final mergeRequest = http.Request('POST', _endpoint('/llm/merge-docstrings'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'astIndex': {'rows': payload.rows, 'cols': payload.cols, 'vals': payload.vals},
        'docstrings': docstrings,
      });
    final mergeResponse = await client.send(mergeRequest);
    final mergeBody = await mergeResponse.stream.bytesToString();
    if (gen != _execGen || !mounted) return;

    if (mergeResponse.statusCode != 200) {
      setError(jsonDecode(mergeBody)['detail'] ?? 'HTTP ${mergeResponse.statusCode}');
      return;
    }

    final result = jsonDecode(mergeBody);
    _finish(
      AaPayload(
        rows: List<String>.from(result['enrichedIndex']['rows'] ?? []),
        cols: List<String>.from(result['enrichedIndex']['cols'] ?? []),
        vals: List.from(result['enrichedIndex']['vals'] ?? []),
      ),
      rowsProcessed: docstrings.length,
      failed: failed,
    );
  }

  void _finish(
    AaPayload enrichedAa, {
    required int rowsProcessed,
    required int failed,
  }) {
    setState(() {
      _result = (rowsProcessed: rowsProcessed, colCount: enrichedAa.cols.length, failed: failed);
    });
    _out.emit(enrichedAa);
    setComplete(
      detail: '$rowsProcessed documented'
          '${failed > 0 ? ' · $failed failed' : ''}',
    );
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard
  /// abort: state flips to idle synchronously, right here, not after any
  /// awaited step notices a flag. `_execGen` guards the in-flight run's own
  /// awaits — including every iteration of the remote per-row loop —
  /// against then clobbering that idle state or dispatching further rows.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  // ── Model catalog fetch (remote path only) ──────────────────────────────

  Future<void> _fetchModels() async {
    final profile = _authProfile;
    if (profile == null || !_matchingCredential || _fetchingModels) return;
    setState(() {
      _fetchingModels = true;
      _modelFetchError = null;
    });

    final apiKey = await _vault.secretFor(profile);
    final result = await _modelCatalog.list(profile: profile, apiKey: apiKey);
    if (!mounted) return;
    setState(() {
      _fetchingModels = false;
      _modelFetchError = result.error;
    });

    if (result.ids.isEmpty || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final position = RelativeRect.fromLTRB(
      box.localToGlobal(Offset.zero).dx,
      box.localToGlobal(Offset.zero).dy,
      0,
      0,
    );
    if (!mounted) return;
    final picked = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final id in result.ids) PopupMenuItem(value: id, child: Text(id)),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _remoteModel.text = picked);
    _persist();
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'astIndex'),
        InputConnector(
          label: 'authInput',
          idx: 1,
          active: widget.authConnected,
          onConnect: widget.onAuthConnect,
        ),
        InputConnector(
          label: 'promptInput',
          idx: 2,
          active: widget.promptConnected,
          onConnect: widget.onPromptConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'documented',
          idx: 0,
          hasData: (_result?.rowsProcessed ?? 0) > 0,
        ),
      ];

  // ── Body ─────────────────────────────────────────────────────────────────

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(3)),
        _modelChoiceField(busy),
        if (_isRemoteChoice) ...[
          const SizedBox(height: 8),
          _remoteModelField(busy),
        ],
        if (_isRemoteChoice && !_matchingCredential) ...[
          const SizedBox(height: 4),
          Text(
            'Connect a Secure Settings credential for '
            '${AuthProvider.googleGemini.label} to enable Execute',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _maxTokens,
                enabled: !busy,
                onChanged: (_) => _persist(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Tokens',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _temperature,
                enabled: !busy,
                onChanged: (_) => _persist(),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Temperature',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        if (_modelFetchError case final error?) ...[
          const SizedBox(height: 4),
          Text(error, style: theme.textTheme.labelSmall?.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: 10),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  /// The "Model" dropdown itself: a choice between the local SLM (no
  /// credential ever needed) and Gemini (remote, the default — see
  /// [_ModelChoice]). Not the actual Gemini model id — that's
  /// [_remoteModelField], shown only for the Gemini choice.
  Widget _modelChoiceField(bool busy) => DropdownMenu<_ModelChoice>(
        enableSearch: false,
        expandedInsets: EdgeInsets.zero,
        enabled: !busy,
        label: const Text('Model'),
        initialSelection: _modelChoice,
        onSelected: (choice) => choice == null ? null : _onModelChoiceChanged(choice),
        dropdownMenuEntries: const [
          DropdownMenuEntry(value: _ModelChoice.local, label: _localModelId),
          DropdownMenuEntry(value: _ModelChoice.gemini, label: 'Gemini'),
        ],
      );

  Widget _remoteModelField(bool busy) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _remoteModel,
              enabled: !busy,
              onChanged: (_) => _persist(),
              decoration: InputDecoration(
                labelText: 'Model (${_authProfile?.provider.label ?? AuthProvider.googleGemini.label})',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: busy || _fetchingModels || !_matchingCredential ? null : _fetchModels,
            icon: _fetchingModels
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.list_alt_outlined, size: 18),
            tooltip: 'Available models',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      );
}
