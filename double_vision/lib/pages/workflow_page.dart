import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../config/node_registry.dart';
import '../models/workflow.dart';
import '../services/storage_service.dart';
import '../widgets/base_node.dart' show kPortLaneTop, kPortSpacing;
import '../widgets/file_source_node.dart';
import '../widgets/preview_node.dart';
import '../widgets/sam3_node.dart';

/// Fixed node width — used both for layout and to anchor edge endpoints.
const double _kNodeWidth = 240;

/// Vertical offset (from a node's top) at which edges attach. Approximate; the
/// real connectors sit at different heights per node type.
const double _kPortY = 40;

/// A minimal workflow editor: a thin header to instantiate and save nodes, a
/// draggable-node canvas, and connector-to-connector edge creation.
class WorkflowPage extends StatefulWidget {
  const WorkflowPage({super.key});

  @override
  State<WorkflowPage> createState() => _WorkflowPageState();
}

class _WorkflowPageState extends State<WorkflowPage> {
  static const _version = '0.1.0';

  final List<WorkflowNode> _nodes = [];
  final List<WorkflowEdge> _edges = [];

  /// Output byte streams published by source nodes, keyed by node id.
  final Map<int, Stream<Uint8List>> _outputs = {};

  int _nextId = 1;
  bool _saving = false;

  void _addNode(NodeType type) {
    setState(() {
      final offset = 32.0 + _nodes.length % 8 * 30.0;
      _nodes.add(WorkflowNode(
          id: _nextId++, type: type.type, x: offset, y: offset + 24));
    });
  }

  /// Move the node with [id] by the drag delta, clamped to the canvas.
  void _moveNode(int id, Offset delta) {
    final i = _nodes.indexWhere((n) => n.id == id);
    if (i < 0) return;
    final n = _nodes[i];
    setState(() {
      _nodes[i] = n.copyWith(
        x: (n.x + delta.dx).clamp(0, 4000),
        y: (n.y + delta.dy).clamp(_kPortY, 4000),
      );
    });
  }

  /// Record an edge from [source] (an output port) into [targetId]'s input,
  /// replacing any existing edge feeding that input.
  void _connect(PortRef source, int targetId) {
    setState(() {
      _edges.removeWhere((e) => e.to.nodeId == targetId);
      _edges.add(
        WorkflowEdge(from: source, to: PortRef(nodeId: targetId, idx: 0)),
      );
    });
  }

  /// Resolve the upstream stream wired into [nodeId]'s input, if any.
  Stream<Uint8List>? _inputFor(int nodeId) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId) return _outputs[e.from.nodeId];
    }
    return null;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final workflow = Workflow(version: _version, nodes: _nodes, edges: _edges);
    String message;
    try {
      await StorageService().write('workflow', workflow.toJson());
      message = 'Saved ${_nodes.length} node(s), ${_edges.length} edge(s) '
          'to ../storage/workflow.json';
    } catch (e) {
      // StorageService uses dart:io, which is unavailable on web.
      message = 'Save failed: $e';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Remove all nodes and edges from the canvas.
  void _clear() {
    setState(() {
      _nodes.clear();
      _edges.clear();
      _outputs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _Header(
            onAdd: _addNode,
            onSave: _save,
            saving: _saving,
            onClear: _nodes.isEmpty ? null : _clear,
          ),
          Expanded(child: _canvas(context)),
        ],
      ),
    );
  }

  Widget _canvas(BuildContext context) {
    if (_nodes.isEmpty) {
      return Center(
        child: Text('Use the Workflow menu to add a node.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }

    final byId = {for (final n in _nodes) n.id: n};

    return Stack(
      children: [
        // Edges, painted beneath the nodes.
        Positioned.fill(
          child: CustomPaint(
            painter: _EdgePainter(
              edges: _edges,
              byId: byId,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),

        // Nodes.
        for (final node in _nodes)
          Positioned(
            left: node.x,
            top: node.y,
            child: KeyedSubtree(
              key: ValueKey(node.id),
              child: _buildNode(node),
            ),
          ),

        // Drag handles, overlaid just above each node.
        for (final node in _nodes)
          Positioned(
            left: node.x,
            top: node.y - 16,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => _moveNode(node.id, d.delta),
              child: Container(
                width: _kNodeWidth,
                height: 16,
                alignment: Alignment.center,
                child: Icon(Icons.drag_indicator,
                    size: 16,
                    color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNode(WorkflowNode node) {
    switch (node.type) {
      case 'file_source':
        return FileSourceNode(
          node: node,
          onConnect: (stream) => _outputs[node.id] = stream,
        );
      case 'preview':
        return PreviewNode(
          node: node,
          input: _inputFor(node.id),
          onConnect: (source) => _connect(source, node.id),
        );
      case 'sam3':
        // The control panel needs a backend session (set once an image is
        // wired in); its segmentStream is consumed by a future viewport node.
        return Sam3Node(node: node);
      default:
        return PlaceholderNode(node: node);
    }
  }
}

/// Draws a curved line from each edge's source output to its target input.
class _EdgePainter extends CustomPainter {
  final List<WorkflowEdge> edges;
  final Map<int, WorkflowNode> byId;
  final Color color;

  _EdgePainter({required this.edges, required this.byId, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (final e in edges) {
      final from = byId[e.from.nodeId];
      final to = byId[e.to.nodeId];
      if (from == null || to == null) continue;

      // Anchor each endpoint on the actual port dot: same Edge-Anchor geometry
      // the wrapper uses to position the ports (lane top + idx * spacing).
      final start = Offset(from.x + _kNodeWidth,
          from.y + kPortLaneTop + e.from.idx * kPortSpacing);
      final end = Offset(to.x, to.y + kPortLaneTop + e.to.idx * kPortSpacing);
      final dx = (end.dx - start.dx).abs().clamp(40, 200).toDouble();

      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx + dx, start.dy, end.dx - dx, end.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);
      canvas.drawCircle(end, 3, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.edges != edges || old.byId != byId || old.color != color;
}

/// The thin top header: a "Workflow" dropdown of node names and a Save button.
class _Header extends StatelessWidget {
  final ValueChanged<NodeType> onAdd;
  final VoidCallback onSave;
  final bool saving;

  /// Clear the workflow; null disables the button (nothing to clear).
  final VoidCallback? onClear;

  const _Header({
    required this.onAdd,
    required this.onSave,
    required this.saving,
    this.onClear,
  });

  // Reference style: dark fill, coloured border + content, rounded corners.
  static const _saveColor = Color(0xFF5B8DEF); // blue
  static const _deleteColor = Color(0xFFE5534B); // red

  ButtonStyle _outlined(Color color) => OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color, width: 1.5),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          PopupMenuButton<NodeType>(
            tooltip: 'Add a node',
            onSelected: onAdd,
            itemBuilder: (context) => [
              for (final type in nodeTypes)
                PopupMenuItem(value: type, child: Text(type.name)),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Workflow', style: theme.textTheme.titleSmall),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: saving ? null : onSave,
            style: _outlined(_saveColor),
            icon: saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, size: 18),
            label: const Text('Save'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onClear,
            style: _outlined(_deleteColor),
            child: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }
}
