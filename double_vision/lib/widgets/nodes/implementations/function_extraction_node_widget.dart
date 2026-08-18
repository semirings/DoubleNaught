import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../services/ast_extract_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';

/// Indexes every function and macro in a Julia source tree — see `DESIGN.md` →
/// "Function Extraction node".
///
/// Ports: `codebasePath` (idx 0) supplies the path to parse, `astIndex` (idx 0) carries the
/// 7-column definition index. The path can also be typed directly, so the node is
/// usable with nothing wired into it.
///
/// It **parses**, it does not run. `Polyglot Exec` is the node that executes a
/// file; this one reads it and answers "what does it define?".
class FunctionExtractionNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/ast/extract/aa` endpoint.
  final AstExtractApi? api;

  const FunctionExtractionNodeWidget({
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
  State<FunctionExtractionNodeWidget> createState() => _FunctionExtractionNodeWidgetState();
}

class _FunctionExtractionNodeWidgetState extends BaseNodeState<FunctionExtractionNodeWidget> {
  @override String   get nodeTitle    => 'Function Extraction';
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
  final OutputPort _out = OutputPort('astIndex');

  late TextEditingController _path;

  /// Path taken from `codebasePath`, if one arrived. Shown as the placeholder so it is
  /// obvious the node will use it when the box is empty.
  String? _upstreamPath;
  AaPayload? _incomingPayload;


  AstExtractResult? _result;
  bool _busy = false;

  /// The path that will actually be parsed: what was typed, else what arrived.
  String get _effectivePath {
    final typed = _path.text.trim();
    return typed.isNotEmpty ? typed : (_upstreamPath ?? '');
  }

  bool get _hasIncomingPath {
    if (_incomingPayload == null) return false;
    final aa = _incomingPayload!.toSparse();
    for (final col in aa.cols) {
      final normCol = col.replaceAll('-', '_').toLowerCase();
      if (_pathColumns.contains(normCol)) return true;
    }
    return false;
  }

  bool get _canExtract => !_busy && (_effectivePath.isNotEmpty || _hasIncomingPath);

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const AstExtractApi();
    _path = TextEditingController(text: widget.initialParams?['rootPath'] ?? '');
    _in = InputPort('codebasePath');
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
    debugPrint("[DEBUG Function Extraction Node] Ingress payload received on codebasePath!");
    debugPrint("[DEBUG Function Extraction Node] Payload dimensions: rows: ${payload.rows.length}, cols: ${payload.cols.length}, vals: ${payload.vals.length}");

    String? found;
    for (var i = 0; i < payload.cols.length && i < payload.vals.length; i++) {
      final column = payload.cols[i].replaceAll('-', '_').toLowerCase();
      if (!_pathColumns.contains(column)) continue;
      final value = '${payload.vals[i]}'.trim();
      if (value.isNotEmpty) {
        found = value;
        break;
      }
    }
    setState(() {
      _upstreamPath = found;
      _incomingPayload = payload;
      // A new payload invalidates the previous index.
      _result = null;
    });

    // Automatically trigger extraction on incoming port data when connected!
    // We can auto-extract if there is a path OR if the payload contains text!
    final hasText = payload.cols.contains('text') || payload.cols.contains('raw_text');
    final hasPath = found != null;

    debugPrint("[DEBUG Function Extraction] _onIngress triggered. inputConnected=${widget.inputConnected}, hasPath=$hasPath, hasText=$hasText");
    if (widget.inputConnected && (hasPath || hasText)) {
      debugPrint("[DEBUG Function Extraction] Dispatching to _extract()...");
      _extract();
    } else {
      debugPrint("[DEBUG Function Extraction] Skipped _extract(). inputConnected failed or no text/path found.");
      setIdle();
    }
  }

  Future<void> _extract() async {
    debugPrint("[DEBUG Function Extraction] ENTERING _extract()");
    if (!mounted) return;
    if (_incomingPayload == null && _upstreamPath == null && _path.text.trim().isEmpty) {
      debugPrint("[DEBUG Function Extraction] Aborting: Both _incomingPayload and _upstreamPath/manual path are empty.");
      return;
    }

    setState(() => _busy = true);
    setWorking();

    try {
      debugPrint("[DEBUG Function Extraction] Invoking backend API extract...");
      final res = await _api.extract(_effectivePath, parsedPayload: _incomingPayload);

      debugPrint("[DEBUG Function Extraction] RPC SUCCESS. Extracted ${res.aa.rows.length} rows, ${res.aa.cols.length} cols.");
      if (mounted) {
        setState(() {
          _result = res;
          _busy = false;
        });

        if (res.definitionCount == 0) {
          setError('No definitions found in ${_effectivePath.split('/').last}');
        } else {
          // Explicitly emit the extracted multi-row result downstream
          _out.emit(res.aa);
          setComplete(detail: '${res.definitionCount} definitions');
        }
        saveParams({'rootPath': _path.text.trim()});
      }
    } catch (e, stack) {
      debugPrint("[ERROR Function Extraction] RPC failed inside _extract(): $e\n$stack");
      if (mounted) {
        setState(() => _busy = false);
        setIdle();
        setError(e);
      }
    }
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'codebasePath'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'astIndex',
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
        if (widget.inputConnected) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(Icons.link_rounded, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: const Text(
                    'Bound: parsedPayload',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          TextField(
            controller: _path,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'File or directory',
              hintText: _upstreamPath ?? '/path/to/src',
              helperText: _upstreamPath != null && _path.text.trim().isEmpty
                  ? 'from codebasePath'
                  : null,
              helperStyle: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
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
