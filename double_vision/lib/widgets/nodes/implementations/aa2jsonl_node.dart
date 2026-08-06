import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/aa2jsonl_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A workflow **terminal processing node** (AA-in → AA-out, per `DESIGN.md`): it
/// consumes the passage D4M/AA payload emitted by an upstream [ChunkNode] and
/// writes it as a JSONL file formatted for Phi-4 fine-tuning. It emits a
/// provenance AA out of its `manifest` output — one row per source chunk,
/// recording the line written and its status — so the run can be audited or
/// chained further.
class Aa2JsonlNode extends BaseNodeWidget {
  /// The two Phi-4 fine-tuning line formats, selectable per run.
  static const List<String> formats = ['instruction-completion', 'continuation'];

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final Aa2JsonlApi api;

  const Aa2JsonlNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const Aa2JsonlApi(),
  });

  @override
  State<Aa2JsonlNode> createState() => _Aa2JsonlNodeState();
}

class _Aa2JsonlNodeState extends BaseNodeState<Aa2JsonlNode> {
  @override String   get nodeTitle    => 'AA → JSONL';
  @override IconData get nodeIcon     => Icons.data_object;
  @override String   get workingLabel => 'writing';

  final InputPort  _in  = InputPort('chunks');
  final OutputPort _out = OutputPort('manifest');

  AaPayload? _incoming;
  AaPayload? _lastOutput;
  Aa2JsonlStats? _stats;

  final TextEditingController _pathController = TextEditingController();
  String _format = Aa2JsonlNode.formats.first;

  bool get _canWrite =>
      _incoming != null &&
      _pathController.text.trim().isNotEmpty &&
      status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _stats = null;
    });
    setIdle();
  }

  Future<void> _write() async {
    final incoming = _incoming;
    if (incoming == null || status == NodeStatus.working) return;
    setWorking();
    try {
      final result = await widget.api.write(
        incoming,
        outputFile: _pathController.text.trim(),
        format: _format,
      );
      if (!mounted) return;
      _lastOutput = result.aa;
      _out.emit(result.aa);
      setState(() => _stats = result.stats);
      setComplete();
    } catch (e) {
      if (mounted) setError(e);
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'chunks',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'manifest',
          idx: 0,
          active: _lastOutput != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _upstreamInfo(theme),
        const SizedBox(height: 12),

        TextField(
          controller: _pathController,
          enabled: !busy,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'outputFile',
            hintText: '/path/to/train.jsonl',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        const SizedBox(height: 12),

        DropdownButtonFormField<String>(
          initialValue: _format,
          isDense: true,
          decoration: const InputDecoration(
            labelText: 'format',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: [
            for (final f in Aa2JsonlNode.formats)
              DropdownMenuItem(value: f, child: Text(f)),
          ],
          onChanged: busy ? null : (v) => setState(() => _format = v ?? _format),
        ),
        const SizedBox(height: 12),

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canWrite ? _write : null,
            icon: busy ? busyIcon() : const Icon(Icons.save_alt, size: 18),
            label: const Text('Write'),
          ),
        ),

        if (_stats != null) ...[
          const SizedBox(height: 10),
          _resultPanel(theme, _stats!),
        ],
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a Chunk node',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final count  = incoming.distinctRows().length;
    final author = incoming.value('author');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$count chunk${count == 1 ? '' : 's'} incoming',
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (author != null && author.isNotEmpty)
          Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _resultPanel(ThemeData theme, Aa2JsonlStats stats) {
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${stats.linesWritten} line${stats.linesWritten == 1 ? '' : 's'} written'
            '${stats.skipped > 0 ? ' · ${stats.skipped} skipped' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            stats.outputFile,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            '${stats.fileSizeBytes} bytes',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
