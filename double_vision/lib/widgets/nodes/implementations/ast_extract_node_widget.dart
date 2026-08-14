import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../services/ast_extract_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';

/// Indexes every function and macro in a Julia source tree — see `DESIGN.md` →
/// "AST Extract node".
///
/// Ports: `in_aa` (idx 0) supplies the path to parse, `out_aa` (idx 0) carries the
/// 7-column definition index. The path can also be typed directly, so the node is
/// usable with nothing wired into it.
///
/// It **parses**, it does not run. `Polyglot Exec` is the node that executes a
/// file; this one reads it and answers "what does it define?".
class AstExtractNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/ast/extract/aa` endpoint.
  final AstExtractApi? api;

  const AstExtractNodeWidget({
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
  State<AstExtractNodeWidget> createState() => _AstExtractNodeWidgetState();
}

class _AstExtractNodeWidgetState extends BaseNodeState<AstExtractNodeWidget> {
  @override String   get nodeTitle    => 'AST Extract';
  @override IconData get nodeIcon     => Icons.account_tree_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'parsing';

  /// Columns an upstream AA may carry the path under. `Load File` sends
  /// `file_path` alongside a source file's text.
  static const _pathColumns = [
    'file_path',
    'filepath',
    'path',
    'root',
    'root_path',
    'rootpath',
    'file',
  ];

  late final AstExtractApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('out_aa');

  late TextEditingController _path;

  /// Path taken from `in_aa`, if one arrived. Shown as the placeholder so it is
  /// obvious the node will use it when the box is empty.
  String? _upstreamPath;

  AstExtractResult? _result;
  bool _busy = false;

  /// The path that will actually be parsed: what was typed, else what arrived.
  String get _effectivePath {
    final typed = _path.text.trim();
    return typed.isNotEmpty ? typed : (_upstreamPath ?? '');
  }

  bool get _canExtract => !_busy && _effectivePath.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const AstExtractApi();
    _path = TextEditingController(text: widget.initialParams?['rootPath'] ?? '');
    _in = InputPort('in_aa');
    initInputPort(_in, _onIngress);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _path.dispose();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  /// Read a path out of the arriving payload.
  ///
  /// Only a path is taken, never the text: the extractor parses files on disk, so
  /// handing it source over the wire would mean writing a temp file to read it
  /// straight back.
  void _onIngress(AaPayload payload) {
    if (!mounted) return;
    final aa = payload.toSparse();
    String? found;
    for (var i = 0; i < aa.cols.length && i < aa.vals.length; i++) {
      final column = aa.cols[i].replaceAll('-', '_').toLowerCase();
      if (!_pathColumns.contains(column)) continue;
      final value = '${aa.vals[i]}'.trim();
      if (value.isNotEmpty) {
        found = value;
        break;
      }
    }
    setState(() {
      _upstreamPath = found;
      // A new payload invalidates the previous index.
      _result = null;
    });
    setIdle();
  }

  Future<void> _extract() async {
    if (!_canExtract) return;
    setState(() => _busy = true);
    setWorking();

    AstExtractResult result;
    try {
      result = await _api.extract(_effectivePath);
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
    saveParams({'rootPath': _path.text.trim()});

    if (result.definitionCount == 0) {
      // Not an error, but not worth sending on either: an empty index downstream
      // would look like a successful extraction of nothing.
      setError('No definitions found in ${_effectivePath.split('/').last}');
      return;
    }
    setComplete(detail: '${result.definitionCount} definitions');
    _out.emit(result.aa);
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
          hasData: (_result?.definitionCount ?? 0) > 0,
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
        TextField(
          controller: _path,
          enabled: !_busy,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'File or directory',
            hintText: _upstreamPath ?? '/path/to/src',
            helperText: _upstreamPath != null && _path.text.trim().isEmpty
                ? 'from in_aa'
                : null,
            helperStyle: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            onPressed: _canExtract ? _extract : null,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.account_tree_outlined, size: 16),
            label: Text(_busy ? 'Parsing…' : 'Extract Definitions'),
          ),
        ),
        if (_effectivePath.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Wire a Load File node, or type a path',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        statusRow(),
        if (_result case final result?) ...[
          const SizedBox(height: 6),
          _summary(theme, scheme, result),
        ],
      ],
    );
  }

  /// What was found: totals, then the breakdown by kind — the answer to "did it
  /// see my macros?" without opening the panel.
  Widget _summary(ThemeData theme, ColorScheme scheme, AstExtractResult result) {
    final kinds = result.kindCounts;
    final breakdown = [
      for (final entry in kinds.entries) '${entry.value} ${entry.key}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The count itself is the status row's job (`complete · N definitions`);
        // repeating it here said the same thing twice on one card.
        Text(
          '${result.filesScanned} file${result.filesScanned == 1 ? '' : 's'} scanned',
          style: theme.textTheme.labelSmall?.copyWith(
            color: result.definitionCount > 0 ? Colors.green : scheme.error,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (breakdown.isNotEmpty)
          Text(
            breakdown,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (result.errors.isNotEmpty)
          Text(
            '${result.errors.length} file(s) skipped',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          ),
      ],
    );
  }
}
