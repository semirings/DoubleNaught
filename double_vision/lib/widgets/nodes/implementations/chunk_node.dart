import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/chunk_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Lifecycle of a chunking operation, surfaced by the status indicator.
enum ChunkStatus { idle, chunking, complete, error }

/// A workflow **processing node** (AA-in → AA-out, per `DESIGN.md`): it consumes
/// the cleaned-text D4M/AA payload emitted by an upstream [FetchNode], applies
/// author-aware chunking on the backend, and emits an AA of discrete passages
/// out of its `chunks` output for downstream processing.
///
/// Structure mirrors [FetchNode]: the input-subscription convention (subscribe
/// in [initState], re-subscribe in [didUpdateWidget], cancel in [dispose]) plus
/// the source-node output convention (a broadcast port published to [onConnect],
/// replaying the last payload to late subscribers).
class ChunkNode extends StatefulWidget {
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
  final ChunkApi api;

  const ChunkNode({
    super.key,
    required this.node,
    this.inputConnected = false,
    this.onInputConnect,
    this.onInputPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.api = const ChunkApi(),
  });

  @override
  State<ChunkNode> createState() => _ChunkNodeState();
}

class _ChunkNodeState extends State<ChunkNode> {
  /// Ingress/egress ports. The node listens to its own [_in] from birth, so the
  /// upstream's retained value is delivered when the canvas calls connect().
  final InputPort _in = InputPort('text');
  final OutputPort _out = OutputPort('chunks');

  /// The most recent AA payload received from upstream, or null.
  AaPayload? _incoming;

  /// The most recent passage AA emitted, retained for the highlight.
  AaPayload? _lastOutput;

  /// Statistics from the last successful chunking run.
  ChunkStats? _stats;

  ChunkStatus _status = ChunkStatus.idle;
  String? _error;

  bool get _canChunk => _incoming != null && _status != ChunkStatus.chunking;

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
    super.dispose();
  }

  /// A fresh upstream payload resets the node to idle so the user can re-chunk.
  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _status = ChunkStatus.idle;
      _stats = null;
      _error = null;
    });
  }

  Future<void> _chunk() async {
    final incoming = _incoming;
    if (incoming == null || _status == ChunkStatus.chunking) return;
    setState(() {
      _status = ChunkStatus.chunking;
      _error = null;
    });
    try {
      final result = await widget.api.chunk(incoming);
      if (!mounted) return;
      _lastOutput = result.aa;
      _out.emit(result.aa);
      setState(() {
        _stats = result.stats;
        _status = ChunkStatus.complete;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = ChunkStatus.error;
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
      title: 'Chunk',
      icon: Icons.segment,
      inputPorts: [
        InputConnector(
          label: 'text',
          idx: 0,
          active: wired,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'aaOut',
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
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canChunk ? _chunk : null,
              icon: _status == ChunkStatus.chunking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.segment, size: 18),
              label: const Text('Chunk'),
            ),
          ),
          if (_stats != null) ...[
            const SizedBox(height: 10),
            _statsPanel(theme, _stats!),
          ],
          const SizedBox(height: 8),
          _statusIndicator(theme),
        ],
      ),
    );
  }

  /// The incoming author tag + work title pulled from the upstream AA payload.
  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a Fetch node',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final author = incoming.value('author');
    final workTitle = incoming.value('work_title');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (workTitle != null && workTitle.isNotEmpty) ? workTitle : '(untitled)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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

  /// Post-processing stats: chunk count and token statistics.
  Widget _statsPanel(ThemeData theme, ChunkStats stats) {
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
            '${stats.chunkCount} chunks',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'tokens: ${stats.totalTokens} total · '
            '${stats.meanTokens.toStringAsFixed(0)} avg · '
            '${stats.minTokens}–${stats.maxTokens} range',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Status dot + label: idle | chunking | complete | error.
  Widget _statusIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      ChunkStatus.idle => (scheme.outline, 'idle'),
      ChunkStatus.chunking => (scheme.primary, 'chunking'),
      ChunkStatus.complete => (Colors.green, 'complete'),
      ChunkStatus.error => (scheme.error, 'error'),
    };
    final detail = (_status == ChunkStatus.error && _error != null) ? ' · $_error' : '';

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
