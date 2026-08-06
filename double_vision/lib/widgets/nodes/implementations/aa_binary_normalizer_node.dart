import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../services/aa_binary_normalizer_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';

/// A workflow node that ingests raw source files, normalises them to the
/// canonical AA Arrow schema, and writes a persistent binary cache to disk.
///
/// **AA contract**
///
/// * Input (`aaIn`): AA payload carrying `filePath` and `outputDirectory`
///   columns from an upstream source node (e.g. FileSourceNode).  Values can
///   also be entered or overridden in the node's own text fields.
///
/// * Output (`aaOut`): metadata AA emitted on completion — `arrowFilePath`,
///   `rowCount`, `splitName`, `isMemoryMapped`, and one `schema:<field>`
///   column per canonical AA Arrow field.  Downstream nodes (e.g.
///   TokenizerNode) consume this to locate the memory-mapped cache.
class AaBinaryNormalizerNode extends BaseNodeWidget {
  static const double _width = 320;

  final AaBinaryNormalizerApi api;

  const AaBinaryNormalizerNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    super.initialParams,
    super.onParams,
    this.api = const AaBinaryNormalizerApi(),
  });

  @override
  State<AaBinaryNormalizerNode> createState() => _AaBinaryNormalizerNodeState();
}

class _AaBinaryNormalizerNodeState
    extends BaseNodeState<AaBinaryNormalizerNode> {
  @override String   get nodeTitle    => 'AA Binary Normalizer';
  @override IconData get nodeIcon     => Icons.table_view_outlined;
  @override double   get nodeWidth    => AaBinaryNormalizerNode._width;
  @override String   get workingLabel => _workingStage;

  final InputPort  _in  = InputPort('aaIn');
  final OutputPort _out = OutputPort('aaOut');

  late final TextEditingController _filePathCtrl;
  late final TextEditingController _outputDirCtrl;
  late final TextEditingController _splitNameCtrl;

  String _workingStage = 'normalizing';
  AaBinaryNormalizeResult? _lastResult;

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
    _filePathCtrl = TextEditingController(
        text: widget.initialParams?['filePath'] ?? '');
    _outputDirCtrl = TextEditingController(
        text: widget.initialParams?['outputDirectory'] ?? '');
    _splitNameCtrl = TextEditingController(
        text: widget.initialParams?['splitName'] ?? 'train');
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _filePathCtrl.dispose();
    _outputDirCtrl.dispose();
    _splitNameCtrl.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    final filePath  = payload.value('filePath');
    final outputDir = payload.value('outputDirectory');
    setState(() {
      if (filePath  != null && filePath.isNotEmpty)  _filePathCtrl.text  = filePath;
      if (outputDir != null && outputDir.isNotEmpty) _outputDirCtrl.text = outputDir;
    });
    _normalize();
  }

  Future<void> _normalize() async {
    final filePath  = _filePathCtrl.text.trim();
    final outputDir = _outputDirCtrl.text.trim();
    final splitName = _splitNameCtrl.text.trim().isEmpty
        ? 'train'
        : _splitNameCtrl.text.trim();

    if (filePath.isEmpty || outputDir.isEmpty) return;

    setState(() => _workingStage = 'ingesting');
    setWorking();

    try {
      final result = await widget.api.normalize(
        filePath:        filePath,
        outputDirectory: outputDir,
        splitName:       splitName,
      );

      if (!mounted) return;
      setState(() => _lastResult = result);
      _out.emit(_buildOutputAa(result, splitName));
      setComplete(detail: '${result.rowCount} rows');

      saveParams({
        'filePath':        filePath,
        'outputDirectory': outputDir,
        'splitName':       splitName,
      });
    } catch (e) {
      setError(e);
    } finally {
      if (mounted) setState(() => _workingStage = 'normalizing');
    }
  }

  AaPayload _buildOutputAa(AaBinaryNormalizeResult result, String splitName) {
    final nameWithExt = result.arrowFilePath.split('/').last;
    final dot         = nameWithExt.lastIndexOf('.');
    final bookId      = dot > 0 ? nameWithExt.substring(0, dot) : nameWithExt;
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];

    void add(String col, Object val) {
      rows.add(bookId);
      cols.add(col);
      vals.add(val);
    }

    add('arrowFilePath',  result.arrowFilePath);
    add('rowCount',       result.rowCount);
    add('splitName',      splitName);
    add('isMemoryMapped', result.isMemoryMapped.toString());
    for (final entry in result.columnSchema.entries) {
      add('schema:${entry.key}', entry.value);
    }

    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  // ── Build overrides ────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'aaIn')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) =>
      [singleOutputConnector(label: 'aaOut', idx: 0, hasData: _lastResult != null)];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme   = Theme.of(context);
    final muted   = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final isActive = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Reserve vertical space so the input-port dot clears the body text.
        SizedBox(height: BaseNodeState.portLaneClearance(1)),

        // ── filePath ────────────────────────────────────────────────────
        TextField(
          controller: _filePathCtrl,
          enabled:    !isActive,
          decoration: const InputDecoration(
            labelText:      'Source file',
            hintText:       '/data/corpus.jsonl',
            isDense:        true,
            border:         OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 8),

        // ── outputDirectory ─────────────────────────────────────────────
        TextField(
          controller: _outputDirCtrl,
          enabled:    !isActive,
          decoration: const InputDecoration(
            labelText:      'Output directory',
            hintText:       '/data/cache',
            isDense:        true,
            border:         OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 8),

        // ── splitName ───────────────────────────────────────────────────
        TextField(
          controller: _splitNameCtrl,
          enabled:    !isActive,
          decoration: const InputDecoration(
            labelText:      'Split',
            hintText:       'train',
            isDense:        true,
            border:         OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 12),

        // ── Normalize button ────────────────────────────────────────────
        SizedBox(
          height: 40,
          child: ElevatedButton.icon(
            onPressed: isActive ? null : _normalize,
            icon: isActive ? busyIcon() : const Icon(Icons.transform, size: 16),
            label: Text(isActive ? workingLabel : 'Normalize'),
          ),
        ),
        const SizedBox(height: 8),

        // ── Status row ──────────────────────────────────────────────────
        statusRow(),

        // ── Result summary ──────────────────────────────────────────────
        if (_lastResult != null) ...[
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 6),
          _resultSummary(theme, muted),
        ],
      ],
    );
  }

  Widget _resultSummary(ThemeData theme, TextStyle? muted) {
    final r = _lastResult!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${r.rowCount} rows · ${r.isMemoryMapped ? "mmap" : "heap"}',
          style: theme.textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          r.arrowFilePath,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
      ],
    );
  }
}
