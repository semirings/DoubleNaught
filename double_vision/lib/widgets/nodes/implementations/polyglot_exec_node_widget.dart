import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/polyglot_exec_api.dart';
import '../base/base_node_widget.dart';

/// A language the node can run, as offered by the override dropdown.
///
/// [wire] is what the backend's language table calls it; `''` means "let the
/// backend infer", so the two sides never disagree about precedence — inference
/// lives in one place only.
enum ExecLanguage {
  auto('Auto-detect', ''),
  julia('Julia', 'julia'),
  python('Python', 'python'),
  javascript('JavaScript', 'javascript'),
  bash('Bash', 'bash');

  const ExecLanguage(this.label, this.wire);

  final String label;
  final String wire;

  static ExecLanguage byWire(String? wire) => values.firstWhere(
        (l) => l.wire == (wire ?? ''),
        orElse: () => ExecLanguage.auto,
      );
}

/// What an incoming AA says about the code it carries.
///
/// A *view* of the payload, not a copy of the contract: the node shows this so
/// you can see what will run before running it. Column aliases and the
/// extension/shebang fallbacks mirror `polyglot_exec_node.py`, so the label
/// matches the interpreter the backend will actually choose.
class ExecSource {
  final String code;
  final String filePath;

  /// The language named by the payload, or inferred from the path or shebang.
  /// Empty when nothing in the payload settles it — then only the dropdown can.
  final String language;

  const ExecSource({
    this.code = '',
    this.filePath = '',
    this.language = '',
  });

  bool get hasCode => code.trim().isNotEmpty;

  /// Basename of [filePath], for display.
  String get fileName {
    if (filePath.isEmpty) return '';
    final cut = filePath.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? filePath : filePath.substring(cut + 1);
  }

  static const _codeCols = ['code', 'text', 'content', 'source', 'raw_code', 'val'];
  static const _pathCols = ['file_path', 'filepath', 'path', 'file', 'file_name'];
  static const _langCols = ['language', 'lang'];

  static const _byExtension = {
    '.jl': 'julia',
    '.py': 'python',
    '.js': 'javascript',
    '.mjs': 'javascript',
    '.cjs': 'javascript',
    '.sh': 'bash',
    '.bash': 'bash',
  };

  /// Read the first row that carries anything usable — the shape `Load File`
  /// emits for a text file is a single row whose only column is `text`.
  static ExecSource fromAa(AaPayload payload) {
    final aa = payload.toSparse();
    final byRow = <String, Map<String, String>>{};
    final order = <String>[];
    for (var i = 0; i < aa.cols.length; i++) {
      if (i >= aa.rows.length || i >= aa.vals.length) break;
      final row = aa.rows[i];
      if (byRow[row] == null) {
        byRow[row] = {};
        order.add(row);
      }
      byRow[row]![aa.cols[i].replaceAll('-', '_').toLowerCase()] =
          '${aa.vals[i]}';
    }

    String pick(Map<String, String> record, List<String> names) {
      for (final name in names) {
        final v = record[name];
        if (v != null && v.trim().isNotEmpty) return v;
      }
      return '';
    }

    for (final row in order) {
      final record = byRow[row]!;
      final code = pick(record, _codeCols);
      final path = pick(record, _pathCols);
      final lang = pick(record, _langCols);
      if (code.isEmpty && path.isEmpty && lang.isEmpty) continue;
      return ExecSource(
        code: code,
        filePath: path,
        language: lang.isNotEmpty ? lang : _infer(path, code),
      );
    }
    return const ExecSource();
  }

  /// Extension first, then the code's own shebang — the backend's order.
  static String _infer(String path, String code) {
    if (path.isNotEmpty) {
      final dot = path.lastIndexOf('.');
      if (dot >= 0) {
        final byExt = _byExtension[path.substring(dot).toLowerCase()];
        if (byExt != null) return byExt;
      }
    }
    final first = code.trimLeft().split('\n').firstOrNull ?? '';
    if (!first.startsWith('#!')) return '';
    for (final word in first.replaceFirst('#!', '').split(RegExp(r'\s+')).reversed) {
      final base = word.split(RegExp(r'[/\\]')).lastOrNull ?? '';
      final match = {
        'julia': 'julia',
        'python': 'python',
        'python3': 'python',
        'node': 'javascript',
        'bash': 'bash',
        'sh': 'bash',
      }[base.toLowerCase()];
      if (match != null) return match;
    }
    return '';
  }
}

/// Runs the source code on an incoming AA under a local interpreter and puts the
/// run's stdout / stderr / exit code back on the graph — see `DESIGN.md` →
/// "Polyglot Exec node".
///
/// Ports: `executionPayload` (idx 0) carries the code, `executionResult` (idx 0) carries the 1×8
/// result matrix. The result is emitted on **every** outcome, so a downstream
/// node sees a failure rather than silence.
class PolyglotExecNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/exec` endpoint.
  final PolyglotExecApi? api;

  const PolyglotExecNodeWidget({
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
  });

  @override
  State<PolyglotExecNodeWidget> createState() => _PolyglotExecNodeWidgetState();
}

class _PolyglotExecNodeWidgetState
    extends BaseNodeState<PolyglotExecNodeWidget> {
  @override String   get nodeTitle    => 'Polyglot Exec';
  @override IconData get nodeIcon     => Icons.terminal_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'running';

  static const double _defaultTimeout = 30;

  late final PolyglotExecApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('executionResult');

  late TextEditingController _timeout;

  ExecSource _source = const ExecSource();

  /// The payload exactly as it arrived. Kept whole, not just parsed: it is sent
  /// with the run so the backend can merge the result into it rather than
  /// replacing it, which is what keeps `text` alive on `executionResult`.
  AaPayload? _incomingAa;
  ExecLanguage _override = ExecLanguage.auto;
  bool _consoleOpen = true;
  bool _running = false;

  PolyglotExecResult? _last;

  /// Set when the run itself could not be made (backend down, bad request) — as
  /// opposed to a snippet that ran and failed, which arrives as a result.
  String? _transportError;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const PolyglotExecApi();
    final params = widget.initialParams;
    _override = ExecLanguage.byWire(params?['language']);
    _consoleOpen = params?['consoleOpen'] != 'false';
    _timeout = TextEditingController(
      text: params?['timeoutS'] ?? '${_defaultTimeout.toInt()}',
    );

    _in = InputPort('executionPayload');
    initInputPort(_in, _onIngress);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _timeout.dispose();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIngress(AaPayload payload) {
    debugPrint('[POLYGLOT-DEBUG] _onIngress called! cols=${payload.cols}, mounted=$mounted');
    if (!mounted) return;
    setState(() {
      _incomingAa = payload;
      _source = ExecSource.fromAa(payload);
      _transportError = null;
      debugPrint('[POLYGLOT-DEBUG] setState completed with ${payload.cols.length} cols');
    });
  }

  void _persist() => saveParams({
        'language': _override.wire,
        'timeoutS': _timeoutSeconds.toString(),
        'consoleOpen': '$_consoleOpen',
      });

  /// The timeout box, sanitised. A blank or nonsense entry falls back to the
  /// default rather than sending the backend something it will reject.
  double get _timeoutSeconds {
    final parsed = double.tryParse(_timeout.text.trim());
    return (parsed == null || parsed <= 0) ? _defaultTimeout : parsed;
  }

  /// The language that will actually be used: the override if set, else whatever
  /// the payload settles. Empty means neither, and Run stays disabled.
  String get _effectiveLanguage =>
      _override == ExecLanguage.auto ? _source.language : _override.wire;

  bool get _canRun =>
      !_running && _source.hasCode && _effectiveLanguage.isNotEmpty;

  Future<void> _run() async {
    if (!_canRun) return;
    setState(() {
      _running = true;
      _transportError = null;
    });
    setWorking();

    PolyglotExecResult? result;
    try {
      // The payload goes too, not just the code: the backend merges the result
      // into it so `executionResult` keeps the incoming columns and row keys. Without the
      // AA there is nothing to merge with and the output collapses to metadata.
      result = await _api.run(
        aa: _incomingAa,
        code: _source.code,
        language: _override.wire,
        filePath: _source.filePath,
        timeoutS: _timeoutSeconds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _transportError = cleanError(e);
        _consoleOpen = true;
      });
      setError(e);
      return;
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _last = result;
      // A run that produced output is worth showing without a click.
      if (result!.stdout.isNotEmpty || result.stderr.isNotEmpty) {
        _consoleOpen = true;
      }
    });

    final detail = '${result.executionTimeMs.round()} ms · exit ${result.exitCode}';
    if (result.ok) {
      setComplete(detail: detail);
    } else {
      setError('${result.status}: $detail');
    }

    // Downstream sees every outcome, not just the good ones.
    _out.emit(result.executionResult);
    _persist();
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'executionPayload'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'executionResult',
          idx: 0,
          hasData: _last != null,
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
        _badge(theme, scheme),
        const SizedBox(height: 8),
        _payloadSummary(theme, scheme),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: DropdownMenu<ExecLanguage>(
                enableSearch: false,
                expandedInsets: EdgeInsets.zero,
                enabled: !_running,
                label: const Text('Language'),
                initialSelection: _override,
                onSelected: (l) {
                  if (l == null) return;
                  setState(() => _override = l);
                  _persist();
                },
                dropdownMenuEntries: [
                  for (final l in ExecLanguage.values)
                    DropdownMenuEntry(value: l, label: l.label),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _timeout,
                enabled: !_running,
                keyboardType: TextInputType.number,
                onChanged: (_) => _persist(),
                decoration: const InputDecoration(
                  labelText: 'Timeout (s)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            onPressed: _canRun ? _run : null,
            icon: _running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(_running ? 'Running…' : 'Run'),
          ),
        ),
        if (!_source.hasCode) ...[
          const SizedBox(height: 6),
          Text(
            'Waiting for executionPayload — wire a Load File node',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ] else if (_effectiveLanguage.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Pick a language — the payload does not say and the file name '
            'does not either',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: 10),
        _console(theme, scheme),
      ],
    );
  }

  /// Status badge. It lives at the top of the body rather than in the title bar
  /// because the shared node header takes a title and icon only; this is the
  /// first thing under it, so it reads as part of the header.
  Widget _badge(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (status) {
      NodeStatus.idle => (scheme.outline, 'Idle'),
      NodeStatus.working => (scheme.primary, 'Running'),
      NodeStatus.complete => (Colors.green, 'Success'),
      NodeStatus.error => (scheme.error, 'Error'),
    };

    final result = _last;
    final trailing = _transportError ??
        (result == null
            ? null
            : '${result.language} · exit ${result.exitCode} · '
                '${result.executionTimeMs.round()} ms');

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trailing,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  /// What arrived on `executionPayload`, so the run is predictable before you press Run.
  Widget _payloadSummary(ThemeData theme, ColorScheme scheme) {
    if (!_source.hasCode && _source.fileName.isEmpty) {
      return Text(
        'No payload',
        style:
            theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    final parts = <String>[
      if (_effectiveLanguage.isNotEmpty)
        'Lang: $_effectiveLanguage'
      else
        'Lang: unknown',
      if (_source.fileName.isNotEmpty) 'File: ${_source.fileName}',
      '${_source.code.split('\n').length} lines',
    ];

    return Row(
      children: [
        Icon(Icons.input_outlined, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// Collapsible mini-terminal for the last run's output.
  ///
  /// Dark regardless of theme: it is a console, and the point is that it reads
  /// like one. stderr is kept visually distinct from stdout rather than
  /// interleaved, since exit-code-zero runs often print to both.
  Widget _console(ThemeData theme, ColorScheme scheme) {
    final result = _last;
    final stdout = result?.stdout ?? '';
    final stderr = _transportError ?? result?.stderr ?? '';
    final empty = stdout.isEmpty && stderr.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() => _consoleOpen = !_consoleOpen);
            _persist();
          },
          child: Row(
            children: [
              Icon(
                _consoleOpen ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                'Console',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (result != null)
                Text(
                  result.status,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: result.ok ? Colors.green : scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        if (_consoleOpen) ...[
          const SizedBox(height: 4),
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: empty
                  ? const Text(
                      'no output yet',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (stdout.isNotEmpty)
                          SelectableText(
                            stdout,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.35,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                        if (stderr.isNotEmpty)
                          SelectableText(
                            stderr,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.35,
                              color: Color(0xFFF87171),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ],
    );
  }
}
