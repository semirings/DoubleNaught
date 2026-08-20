import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// Enriches an AST index with LLM-generated better_docstring column.
///
/// Takes the 7-column documented index from Function Extraction, calls the backend
/// `/llm/enrich-ast` endpoint to generate improved docstrings via a local LLM, and
/// emits the enriched index (8 columns) downstream.
///
/// Ports: `astIndex` (idx 0) is the 7-column input, `documented` (idx 0) is
/// the 8-column output with better_docstring added.
///
/// The Model field is a pick list per the Global UX Contract §7, but — a
/// deliberate scope decision, not a placeholder — it currently holds exactly
/// one item: the only model this backend ever actually loads
/// (`llm_better_doc.py`'s own default). Broadening it to a real model source
/// (local registry, API-populated list, user-added) is a separate decision.
class LLMDocumenterNodeWidget extends BaseNodeWidget {
  final String? baseUrl;
  final http.Client Function() clientFactory;

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

  /// The only model this backend ever loads — see `llm_better_doc.py`'s own
  /// default. Not user-editable; the pick list exists for a future model
  /// source, not to offer a choice today.
  static const _modelId = 'mlx-community/Phi-4-mini-instruct-4bit';

  late final InputPort _in;
  final OutputPort _out = OutputPort('documented');

  late final TextEditingController _maxTokens;
  late final TextEditingController _temperature;

  AaPayload? _incoming;
  ({int rowsProcessed, int colCount})? _result;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely stop
  /// watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state.
  int _execGen = 0;

  @override
  bool get isReady => _incoming != null;

  @override
  void initState() {
    super.initState();
    _in = InputPort('astIndex');
    initInputPort(_in, _onIngress);
    _in.onDisconnected.listen((_) => _dropIncoming());
    initOutputPort(_out);

    _maxTokens = TextEditingController(
      text: widget.initialParams?['maxTokens'] ?? '256',
    );
    _temperature = TextEditingController(
      text: widget.initialParams?['temperature'] ?? '0.7',
    );
  }

  @override
  void dispose() {
    _maxTokens.dispose();
    _temperature.dispose();
    _in.dispose();
    _out.dispose();
    _execClient?.close();
    super.dispose();
  }

  void _persist() => saveParams({
        'maxTokens': _maxTokens.text.trim(),
        'temperature': _temperature.text.trim(),
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

  @override
  void fire() => _enrich();

  Future<void> _enrich() async {
    final payload = _incoming;
    if (payload == null || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    // Unparseable text falls back to the field's own default rather than
    // blocking the run — same convention as Polyglot Exec's Timeout field.
    final maxTokens = int.tryParse(_maxTokens.text.trim()) ?? 256;
    final temperature = double.tryParse(_temperature.text.trim()) ?? 0.7;

    final client = widget.clientFactory();
    _execClient = client;

    try {
      final url = Uri.parse(
          '${widget.baseUrl ?? "http://localhost:8000"}/llm/enrich-ast');
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'astIndex': {
            'rows': payload.rows,
            'cols': payload.cols,
            'vals': payload.vals,
          },
          'modelId': _modelId,
          'maxTokens': maxTokens,
          'temperature': temperature,
        });

      final response = await client.send(request);
      final body = await response.stream.bytesToString();
      if (gen != _execGen || !mounted) return;

      if (response.statusCode != 200) {
        final detail =
            jsonDecode(body)['detail'] ?? 'HTTP ${response.statusCode}';
        setError(detail);
        return;
      }

      final result = jsonDecode(body);
      final enrichedAa = AaPayload(
        rows: List<String>.from(result['enrichedIndex']['rows'] ?? []),
        cols: List<String>.from(result['enrichedIndex']['cols'] ?? []),
        vals: List.from(result['enrichedIndex']['vals'] ?? []),
      );

      setState(() {
        _result = (
          rowsProcessed: (result['rowsProcessed'] ?? 0) as int,
          colCount: enrichedAa.cols.length,
        );
      });
      _out.emit(enrichedAa);
      setComplete(
        detail: '${_result!.rowsProcessed} rows · ${_result!.colCount} cols',
      );
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      client.close();
    }
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard abort:
  /// state flips to idle synchronously, right here, not after any awaited
  /// step notices a flag. `_execGen` guards the in-flight run's own awaits
  /// against then clobbering that idle state if the request still resolves
  /// in the background.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'astIndex'),
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
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        DropdownMenu<String>(
          enableSearch: false,
          expandedInsets: EdgeInsets.zero,
          enabled: !busy,
          label: const Text('Model'),
          initialSelection: _modelId,
          dropdownMenuEntries: const [
            DropdownMenuEntry(value: _modelId, label: _modelId),
          ],
        ),
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
}
