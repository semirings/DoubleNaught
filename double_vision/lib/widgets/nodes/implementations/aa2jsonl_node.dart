import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/aa2jsonl_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Lifecycle of a write operation, surfaced by the status indicator.
enum Aa2JsonlStatus { idle, writing, complete, error }

/// A workflow **terminal processing node** (AA-in → AA-out, per `DESIGN.md`): it
/// consumes the passage D4M/AA payload emitted by an upstream [ChunkNode] and
/// writes it as a JSONL file formatted for Phi-4 fine-tuning. It emits a
/// provenance AA out of its `manifest` output — one row per source chunk,
/// recording the line written and its status — so the run can be audited or
/// chained further.
///
/// Structure mirrors the other processing nodes ([FetchNode] / [ChunkNode]): the
/// input-subscription convention plus the source-node broadcast-output
/// convention.
class Aa2JsonlNode extends StatefulWidget {
  /// The two Phi-4 fine-tuning line formats, selectable per run.
  static const List<String> formats = ['instruction-completion', 'continuation'];

  /// Graph metadata for this node (id/type/position).
  final WorkflowNode node;

  /// True when an edge feeds this node's input (drives the port highlight).
  final bool inputConnected;

  /// Called with the source endpoint when an edge is dropped on the input port.
  final void Function(PortRef source)? onInputConnect;

  /// Registers this node's ingress InputPort with the canvas bridge.
  final void Function(InputPort port)? onInputPort;

  /// Registers this node's egress OutputPort with the canvas bridge.
  final void Function(OutputPort port)? onOutputPort;

  /// Output port indices with an outgoing edge — drives the connected-port
  /// highlight, matching every other node.
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final Aa2JsonlApi api;

  const Aa2JsonlNode({
    super.key,
    required this.node,
    this.inputConnected = false,
    this.onInputConnect,
    this.onInputPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.api = const Aa2JsonlApi(),
  });

  @override
  State<Aa2JsonlNode> createState() => _Aa2JsonlNodeState();
}

class _Aa2JsonlNodeState extends State<Aa2JsonlNode> {
  /// Ingress/egress ports. The node listens to its own [_in] from birth, so the
  /// upstream's retained value is delivered when the canvas calls connect().
  final InputPort _in = InputPort('chunks');
  final OutputPort _out = OutputPort('manifest');

  /// The most recent AA payload received from upstream, or null.
  AaPayload? _incoming;

  final TextEditingController _pathController = TextEditingController();
  String _format = Aa2JsonlNode.formats.first;

  /// The most recent provenance AA emitted, retained for the highlight.
  AaPayload? _lastOutput;

  /// Statistics from the last successful write run.
  Aa2JsonlStats? _stats;

  Aa2JsonlStatus _status = Aa2JsonlStatus.idle;
  String? _error;

  bool get _canWrite =>
      _incoming != null &&
      _pathController.text.trim().isNotEmpty &&
      _status != Aa2JsonlStatus.writing;

  @override
  void initState() {
    super.initState();
    widget.onInputPort?.call(_in);
    widget.onOutputPort?.call(_out);
    _in.onDataArrived.listen(_onIncoming);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _pathController.dispose();
    super.dispose();
  }

  /// A fresh upstream payload resets the node to idle so the user can re-write.
  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _status = Aa2JsonlStatus.idle;
      _stats = null;
      _error = null;
    });
  }

  Future<void> _write() async {
    final incoming = _incoming;
    if (incoming == null || _status == Aa2JsonlStatus.writing) return;
    setState(() {
      _status = Aa2JsonlStatus.writing;
      _error = null;
    });
    try {
      final result = await widget.api.write(
        incoming,
        outputFile: _pathController.text.trim(),
        format: _format,
      );
      if (!mounted) return;
      _lastOutput = result.aa;
      _out.emit(result.aa);
      setState(() {
        _stats = result.stats;
        _status = Aa2JsonlStatus.complete;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = Aa2JsonlStatus.error;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wired = widget.inputConnected;
    final hasOutput = _lastOutput != null;

    return DoubleNaughtNodeWrapper(
      title: 'AA → JSONL',
      icon: Icons.data_object,
      inputPorts: [
        InputConnector(
          label: 'chunks',
          idx: 0,
          active: wired,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'manifest',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _upstreamInfo(theme),
          const SizedBox(height: 12),

          // Output file destination.
          TextField(
            controller: _pathController,
            enabled: _status != Aa2JsonlStatus.writing,
            onChanged: (_) => setState(() {}), // refresh _canWrite
            decoration: const InputDecoration(
              labelText: 'outputFile',
              hintText: '/path/to/train.jsonl',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),

          // Format selector.
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
            onChanged: _status == Aa2JsonlStatus.writing
                ? null
                : (value) => setState(() => _format = value ?? _format),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canWrite ? _write : null,
              icon: _status == Aa2JsonlStatus.writing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt, size: 18),
              label: const Text('Write'),
            ),
          ),

          if (_stats != null) ...[
            const SizedBox(height: 10),
            _resultPanel(theme, _stats!),
          ],
          const SizedBox(height: 8),
          _statusIndicator(theme),
        ],
      ),
    );
  }

  /// Incoming chunk count + author metadata from the upstream AA payload.
  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a Chunk node',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final count = incoming.distinctRows().length;
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

  /// Post-write result: output file path + line count (and skips / size).
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
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            '${stats.fileSizeBytes} bytes',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Status dot + label: idle | writing | complete | error.
  Widget _statusIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      Aa2JsonlStatus.idle => (scheme.outline, 'idle'),
      Aa2JsonlStatus.writing => (scheme.primary, 'writing'),
      Aa2JsonlStatus.complete => (Colors.green, 'complete'),
      Aa2JsonlStatus.error => (scheme.error, 'error'),
    };
    final detail =
        (_status == Aa2JsonlStatus.error && _error != null) ? ' · $_error' : '';

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
            '$label$detail',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
