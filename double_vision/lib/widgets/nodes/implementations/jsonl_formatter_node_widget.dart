import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/aa_payload.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/jsonl_formatter_api.dart';
import '../base/base_node_widget.dart';

/// How a row becomes a JSONL line. Mirrors the backend's `format_mode`.
///
/// [wire] is the canonical name the backend expects; [reads] are the columns that
/// make a row usable in this mode, which is what the card counts to decide whether
/// Format can do anything.
enum JsonlFormatMode {
  chatml(
    'ChatML (Code/Doc)',
    'chatml',
    ['better_docstring'],
    'No rows carry a better_docstring yet — run the teacher node first',
  ),
  promptCompletion(
    'Prompt / Completion',
    'prompt_completion',
    ['completion', 'target', 'output', 'text', 'raw_text'],
    'No rows carry a completion column (completion / target / output / text)',
  ),
  passthrough(
    'Row Passthrough',
    'passthrough',
    // Any non-empty cell will do — every column is data in this mode.
    [],
    'Every row is empty — nothing to write',
  );

  const JsonlFormatMode(this.label, this.wire, this.reads, this.emptyHint);

  final String label;
  final String wire;
  final List<String> reads;

  /// Shown when the payload has no row this mode can use.
  final String emptyHint;

  static JsonlFormatMode byWire(String? wire) => values.firstWhere(
        (m) => m.wire == wire,
        orElse: () => JsonlFormatMode.chatml,
      );
}

/// What the incoming payload looks like, before anything is formatted.
///
/// Counted on the client so the card can say what a run *would* produce before
/// you ask for it — the backend remains the authority on the actual result.
///
/// The count is **mode-dependent**: a payload with no `better_docstring` is
/// useless to ChatML but perfectly formattable as passthrough, so a single
/// definition of "ready" would disable the button on valid input.
class IndexTally {
  /// Distinct rows on the wire.
  final int rows;

  /// Rows carrying what the chosen mode reads.
  final int ready;

  const IndexTally({this.rows = 0, this.ready = 0});

  int get pending => rows - ready;
  bool get isEmpty => rows == 0;

  /// Group the sparse triples by row key and count the rows [mode] can use.
  ///
  /// Column names are matched in both snake_case and camelCase: the backend
  /// speaks the former and the wire the latter, and a payload can reach the canvas
  /// either way.
  static IndexTally of(AaPayload payload, [JsonlFormatMode mode = JsonlFormatMode.chatml]) {
    final aa = payload.toSparse();
    final wanted = {
      for (final name in mode.reads) name.replaceAll('_', ''),
    };
    final usable = <String, bool>{};

    for (var i = 0; i < aa.cols.length; i++) {
      if (i >= aa.rows.length || i >= aa.vals.length) break;
      final row = aa.rows[i];
      usable.putIfAbsent(row, () => false);
      final column =
          aa.cols[i].replaceAll('-', '').replaceAll('_', '').toLowerCase();
      final filled = '${aa.vals[i]}'.trim().isNotEmpty;
      if (!filled) continue;
      // Passthrough reads everything, so any filled cell makes the row usable.
      if (wanted.isEmpty || wanted.contains(column)) usable[row] = true;
    }

    return IndexTally(
      rows: usable.length,
      ready: usable.values.where((v) => v).length,
    );
  }
}

/// The canvas's only JSONL formatter — see `DESIGN.md` → "JSONL Formatter node".
///
/// Formats an AA into training lines: ChatML from code and docstrings,
/// prompt/completion pairs, or one object per row. It replaces the deprecated
/// `Aa2JsonlNode`, which is no longer in the Node Catalog.
///
/// Ports: `in_aa` (idx 0) is the 7-column documented index, `out_aa` (idx 0) is
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

class _JsonlFormatterNodeWidgetState
    extends BaseNodeState<JsonlFormatterNodeWidget> {
  @override String   get nodeTitle    => 'JSONL Formatter';
  @override IconData get nodeIcon     => Icons.data_object_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'formatting';

  late final JsonlFormatterApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('out_aa');

  AaPayload? _incoming;
  JsonlFormatMode _mode = JsonlFormatMode.chatml;
  IndexTally _tally = const IndexTally();
  JsonlFormatResult? _result;
  bool _busy = false;

  /// First formatted line, shown as a sanity check on the training data.
  String? get _preview => _result?.aa.value('json_line');

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const JsonlFormatterApi();
    _mode = JsonlFormatMode.byWire(widget.initialParams?['formatMode']);
    _in = InputPort('in_aa');
    initInputPort(_in, _onIngress);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIngress(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _tally = IndexTally.of(payload, _mode);
      // A new payload invalidates the previous run's output.
      _result = null;
    });
    setIdle();
  }

  bool get _canFormat => !_busy && _tally.ready > 0;

  /// Switching mode re-counts what is usable and drops the previous result: the
  /// lines it produced were built by a different mode.
  void _onModeChanged(JsonlFormatMode mode) {
    setState(() {
      _mode = mode;
      _result = null;
      final payload = _incoming;
      if (payload != null) _tally = IndexTally.of(payload, mode);
    });
    saveParams({'formatMode': mode.wire});
    setIdle();
  }

  Future<void> _format() async {
    final payload = _incoming;
    if (payload == null || !_canFormat) return;

    setState(() => _busy = true);
    setWorking();

    JsonlFormatResult result;
    try {
      result = await _api.format(payload, formatMode: _mode.wire);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      setError(e);
      return;
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });

    if (result.lineCount == 0) {
      // Not an error — a payload whose teacher node has not run yet formats to
      // nothing, and saying so is more useful than an empty success.
      setError('No usable rows to format');
      return;
    }
    setComplete(detail: '${result.lineCount} lines');
    _out.emit(result.aa);
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
        singleInputConnector(label: 'in_aa'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'out_aa',
          idx: 0,
          hasData: (_result?.lineCount ?? 0) > 0,
        ),
      ];

  // ── Body ─────────────────────────────────────────────────────────────────

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        _tallyRow(theme, scheme),
        const SizedBox(height: 10),
        DropdownMenu<JsonlFormatMode>(
          enableSearch: false,
          expandedInsets: EdgeInsets.zero,
          enabled: !_busy,
          label: const Text('Format Mode'),
          initialSelection: _mode,
          onSelected: (m) => m == null ? null : _onModeChanged(m),
          dropdownMenuEntries: [
            for (final m in JsonlFormatMode.values)
              DropdownMenuEntry(value: m, label: m.label),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            onPressed: _canFormat ? _format : null,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.format_align_left_rounded, size: 18),
            label: Text(_busy ? 'Formatting…' : 'Format ChatML'),
          ),
        ),
        if (_incoming == null) ...[
          const SizedBox(height: 6),
          Text(
            'Waiting for in_aa — wire a documented AST index',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ] else if (_tally.ready == 0) ...[
          const SizedBox(height: 6),
          Text(
            _mode.emptyHint,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          ),
        ],
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

  /// What arrived: how much of the index is ready to train on.
  Widget _tallyRow(ThemeData theme, ColorScheme scheme) {
    if (_tally.isEmpty) {
      return Text(
        'No index',
        style:
            theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    return Row(
      children: [
        Icon(Icons.input_outlined, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${_tally.rows} rows · ${_tally.ready} ready'
            '${_tally.pending > 0 ? ' · ${_tally.pending} pending' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
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
