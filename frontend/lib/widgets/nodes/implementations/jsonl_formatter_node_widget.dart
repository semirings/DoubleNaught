import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/jsonl_formatter_api.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// How a row becomes a JSONL line. Mirrors the backend's `format_mode`.
enum JsonlFormatMode {
  chatml('ChatML Doc', 'chatml'),
  instructionTask('Instruction / Task', 'prompt_completion'),
  passthrough('Passthrough', 'passthrough');

  const JsonlFormatMode(this.label, this.wire);

  final String label;
  final String wire;

  static JsonlFormatMode byWire(String? wire) => values.firstWhere(
        (m) => m.wire == wire,
        orElse: () => JsonlFormatMode.chatml,
      );
}

/// The canvas's only JSONL formatter — see `DESIGN.md` → "JSONL Formatter node".
///
/// Formats an AA into training lines: ChatML from code and docstrings,
/// instruction/task pairs, or one object per row. It replaces the deprecated
/// `Aa2JsonlNode`, which is no longer in the Node Catalog.
///
/// Ports: `astIndex` (idx 0) is the 7-column documented index, `jsonl` (idx 0) is
/// the 2-column result (`json_line`, `symbol_name`) — wire it into a Save File
/// node, which writes `.jsonl` when it sees that column.
class JsonlFormatterNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/jsonl/format/aa` endpoint.
  final JsonlFormatterApi? api;

  /// Clipboard seam for the preview's copy action.
  final Future<void> Function(String text)? onCopy;

  const JsonlFormatterNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.api,
    this.onCopy,
  });

  @override
  State<JsonlFormatterNodeWidget> createState() =>
      _JsonlFormatterNodeWidgetState();
}

class _JsonlFormatterNodeWidgetState extends BaseNodeState<JsonlFormatterNodeWidget>
    with WaitGatedExecution<JsonlFormatterNodeWidget> {
  @override String   get nodeTitle    => 'JSONL Formatter';
  @override IconData get nodeIcon     => Icons.data_object_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'formatting';

  late final JsonlFormatterApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('jsonl');

  AaPayload? _incoming;
  JsonlFormatMode _mode = JsonlFormatMode.chatml;
  JsonlFormatResult? _result;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely stop
  /// watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state.
  int _execGen = 0;

  /// First formatted line, shown as a sanity check on the training data.
  String? get _preview => _result?.aa.value('json_line');

  @override
  bool get isReady => _incoming != null;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const JsonlFormatterApi();
    _mode = JsonlFormatMode.byWire(widget.initialParams?['formatMode']);
    _in = InputPort('astIndex');
    initInputPort(_in, _onIngress);
    _in.onDisconnected.listen((_) => _dropIncoming());
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _execClient?.close();
    super.dispose();
  }

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

  /// Switching mode drops the previous result — it was built by a different
  /// mode — and, in reactive mode, re-runs immediately against the mode just
  /// picked rather than leaving stale output on screen.
  void _onModeChanged(JsonlFormatMode mode) {
    setState(() {
      _mode = mode;
      _result = null;
    });
    saveParams({'formatMode': mode.wire});
    setIdle();
    maybeAutoFire();
  }

  @override
  void fire() => _format();

  Future<void> _format() async {
    final payload = _incoming;
    if (payload == null || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api =
        owns ? JsonlFormatterApi(baseUrl: _api.baseUrl, client: client) : _api;

    try {
      final result = await api.format(payload, formatMode: _mode.wire);
      if (gen != _execGen || !mounted) return;

      setState(() => _result = result);

      if (result.lineCount == 0) {
        // Not an error in the sense of a failed request — a payload whose
        // teacher node has not run yet formats to nothing, and saying so is
        // more useful than a silent empty success.
        setError('No usable rows to format');
        return;
      }
      setComplete(detail: '${result.lineCount} lines');
      _out.emit(result.aa);
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
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

  Future<void> _copyPreview() async {
    final line = _preview;
    if (line == null) return;
    final copy = widget.onCopy ??
        (text) => Clipboard.setData(ClipboardData(text: text));
    await copy(line);
    if (!mounted) return;
    setState(() {});
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'astIndex'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'jsonl',
          idx: 0,
          hasData: (_result?.lineCount ?? 0) > 0,
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
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        DropdownMenu<JsonlFormatMode>(
          enableSearch: false,
          expandedInsets: EdgeInsets.zero,
          enabled: !busy,
          label: const Text('Format Mode'),
          initialSelection: _mode,
          onSelected: (m) => m == null ? null : _onModeChanged(m),
          dropdownMenuEntries: [
            for (final m in JsonlFormatMode.values)
              DropdownMenuEntry(value: m, label: m.label),
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
        if (_result != null) ...[
          const SizedBox(height: 8),
          _resultSummary(theme, scheme),
        ],
        if (_preview case final line?) ...[
          const SizedBox(height: 6),
          _previewBox(theme, scheme, line),
        ],
      ],
    );
  }

  Widget _resultSummary(ThemeData theme, ColorScheme scheme) {
    final result = _result!;
    final parts = <String>[
      '${result.lineCount} training lines',
      if (result.skippedNoDoc > 0) '${result.skippedNoDoc} undocumented',
      if (result.skippedNoCode > 0) '${result.skippedNoCode} without code',
      if (result.skippedIncomplete > 0) '${result.skippedIncomplete} incomplete',
    ];
    return Text(
      parts.join(' · '),
      style: theme.textTheme.labelSmall?.copyWith(
        color: result.lineCount > 0 ? Colors.green : scheme.error,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  /// One line of the training file, so its shape can be eyeballed before saving.
  ///
  /// Deliberately unwrapped and horizontally scrollable: a JSONL line *is* one
  /// line, and wrapping it would hide the property that matters.
  Widget _previewBox(ThemeData theme, ColorScheme scheme, String line) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'First line',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            IconButton(
              onPressed: _copyPreview,
              icon: const Icon(Icons.copy_all_outlined, size: 15),
              tooltip: 'Copy line',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              line,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFFE2E8F0),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
