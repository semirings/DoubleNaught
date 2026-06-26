import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/node_registry.dart';
import '../models/workflow.dart';
import '../services/storage_service.dart';
import '../widgets/base_node.dart' show kPortLaneTop, kPortSpacing;
import '../widgets/connection_drag_scope.dart';
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

class _WorkflowPageState extends State<WorkflowPage>
    with SingleTickerProviderStateMixin {
  static const _version = '0.1.0';

  final List<WorkflowNode> _nodes = [];
  final List<WorkflowEdge> _edges = [];

  /// Output byte streams published by source nodes, keyed by node id.
  final Map<int, Stream<Uint8List>> _outputs = {};

  /// Filenames published by source nodes (out-of-band metadata), keyed by id.
  final Map<int, String> _sourceNames = {};

  int _nextId = 1;
  bool _saving = false;

  /// Canvas geometry + keyboard focus (for Delete/Backspace on a selected edge).
  final GlobalKey _canvasKey = GlobalKey();
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'workflowCanvas');

  /// In-progress connection drag (the live preview noodle).
  PortRef? _pendingSource;
  Offset? _pendingEndpoint; // canvas-local; snapped to a port when near one
  PortRef? _pendingSnapTarget;

  /// The currently selected completed edge, if any.
  WorkflowEdge? _selectedEdge;

  /// Drives the marching-ants animation of the in-progress curve.
  late final AnimationController _ants;

  @override
  void initState() {
    super.initState();
    _ants = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void dispose() {
    _ants.dispose();
    _canvasFocus.dispose();
    super.dispose();
  }

  // --- Port geometry (shared with the painters via the same constants) ---

  Offset _outputPortPos(WorkflowNode n, int idx) =>
      Offset(n.x + _kNodeWidth, n.y + kPortLaneTop + idx * kPortSpacing);
  Offset _inputPortPos(WorkflowNode n, int idx) =>
      Offset(n.x, n.y + kPortLaneTop + idx * kPortSpacing);

  /// Input port indices a node exposes (for snap targeting).
  Iterable<int> _inputIndicesFor(WorkflowNode n) {
    switch (n.type) {
      case 'preview':
      case 'sam3':
        return const [0];
      default:
        return const [];
    }
  }

  // --- Live preview curve ---

  void _onDragStart(PortRef source) {
    _ants.repeat(); // animate the marching ants only while dragging
    setState(() {
      _pendingSource = source;
      _pendingEndpoint = null;
      _pendingSnapTarget = null;
    });
  }

  void _onDragUpdate(Offset globalPointer) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPointer);

    // Snap the endpoint to the nearest input port within range, highlighting it.
    const snapRadius = 20.0;
    PortRef? snap;
    Offset endpoint = local;
    var best = snapRadius;
    for (final n in _nodes) {
      for (final idx in _inputIndicesFor(n)) {
        final p = _inputPortPos(n, idx);
        final d = (p - local).distance;
        if (d < best) {
          best = d;
          snap = PortRef(nodeId: n.id, idx: idx);
          endpoint = p;
        }
      }
    }
    setState(() {
      _pendingEndpoint = endpoint;
      _pendingSnapTarget = snap;
    });
  }

  void _onDragEnd() {
    _ants.stop();
    setState(() {
      _pendingSource = null;
      _pendingEndpoint = null;
      _pendingSnapTarget = null;
    });
  }

  // --- Selection / deletion of completed edges ---

  /// The edge whose curve passes within ~6px of [local] (canvas coords), if any.
  WorkflowEdge? _edgeAt(Offset local) {
    const threshold = 6.0; // ~12px hit band
    final byId = {for (final n in _nodes) n.id: n};
    WorkflowEdge? hit;
    var best = threshold;
    for (final e in _edges) {
      final from = byId[e.from.nodeId];
      final to = byId[e.to.nodeId];
      if (from == null || to == null) continue;
      final d = _distanceToCurve(
        local,
        _outputPortPos(from, e.from.idx),
        _inputPortPos(to, e.to.idx),
      );
      if (d < best) {
        best = d;
        hit = e;
      }
    }
    return hit;
  }

  double _distanceToCurve(Offset p, Offset start, Offset end) {
    final dx = (end.dx - start.dx).abs().clamp(40, 200).toDouble();
    final c1 = Offset(start.dx + dx, start.dy);
    final c2 = Offset(end.dx - dx, end.dy);
    var best = double.infinity;
    const steps = 26;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final u = 1 - t;
      final pt = start * (u * u * u) +
          c1 * (3 * u * u * t) +
          c2 * (3 * u * t * t) +
          end * (t * t * t);
      final d = (pt - p).distance;
      if (d < best) best = d;
    }
    return best;
  }

  void _onCanvasTapUp(TapUpDetails d) {
    _canvasFocus.requestFocus(); // so Delete/Backspace target this canvas
    setState(() => _selectedEdge = _edgeAt(d.localPosition));
  }

  void _onCanvasSecondaryTapUp(TapUpDetails d) {
    final edge = _edgeAt(d.localPosition);
    if (edge == null) return;
    setState(() => _selectedEdge = edge);
    _showEdgeMenu(d.globalPosition, edge);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace) &&
        _selectedEdge != null) {
      _deleteEdge(_selectedEdge!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _deleteEdge(WorkflowEdge e) {
    setState(() {
      _edges.remove(e);
      if (identical(_selectedEdge, e)) _selectedEdge = null;
    });
  }

  void _disconnectSource(WorkflowEdge e) {
    setState(() {
      _edges.removeWhere(
          (x) => x.from.nodeId == e.from.nodeId && x.from.idx == e.from.idx);
      _selectedEdge = null;
    });
  }

  void _disconnectTarget(WorkflowEdge e) {
    setState(() {
      _edges.removeWhere(
          (x) => x.to.nodeId == e.to.nodeId && x.to.idx == e.to.idx);
      _selectedEdge = null;
    });
  }

  Future<void> _showEdgeMenu(Offset globalPos, WorkflowEdge edge) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      items: const [
        PopupMenuItem(value: 'delete', child: Text('Delete Connection')),
        PopupMenuItem(value: 'source', child: Text('Disconnect Source')),
        PopupMenuItem(value: 'target', child: Text('Disconnect Target')),
      ],
    );
    switch (result) {
      case 'delete':
        _deleteEdge(edge);
      case 'source':
        _disconnectSource(edge);
      case 'target':
        _disconnectTarget(edge);
    }
  }

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

  /// Resolve the filename of the source feeding [nodeId]'s input, if any.
  String? _fileNameFor(int nodeId) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId) return _sourceNames[e.from.nodeId];
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
      _sourceNames.clear();
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
    final scheme = Theme.of(context).colorScheme;

    return ConnectionDragScope(
      onDragStart: _onDragStart,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      child: Focus(
        focusNode: _canvasFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          key: _canvasKey,
          children: [
            // Edge layer (beneath nodes) + gestures for select/deselect and the
            // right-click menu. Curves live in otherwise-empty canvas space, so
            // these gestures don't compete with node interactions.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onCanvasTapUp,
                onSecondaryTapUp: _onCanvasSecondaryTapUp,
                child: CustomPaint(
                  painter: _EdgePainter(
                    edges: _edges,
                    byId: byId,
                    color: scheme.primary,
                    selectColor: scheme.tertiary,
                    selected: _selectedEdge,
                  ),
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
                        size: 16, color: scheme.outline),
                  ),
                ),
              ),

            // Live in-progress connection curve, painted above everything.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PendingEdgePainter(
                    source: _pendingSource,
                    byId: byId,
                    endpoint: _pendingEndpoint,
                    snapping: _pendingSnapTarget != null,
                    color: scheme.primary,
                    repaint: _ants,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNode(WorkflowNode node) {
    switch (node.type) {
      case 'file_source':
        return FileSourceNode(
          node: node,
          onConnect: (stream) => _outputs[node.id] = stream,
          onFileName: (name) => setState(() => _sourceNames[node.id] = name),
        );
      case 'preview':
        return PreviewNode(
          node: node,
          input: _inputFor(node.id),
          fileName: _fileNameFor(node.id),
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

/// Builds the bezier connecting an output port [start] to an input port [end].
Path _edgePath(Offset start, Offset end) {
  final dx = (end.dx - start.dx).abs().clamp(40, 200).toDouble();
  return Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(start.dx + dx, start.dy, end.dx - dx, end.dy, end.dx, end.dy);
}

/// Draws a curved line from each edge's source output to its target input,
/// highlighting [selected].
class _EdgePainter extends CustomPainter {
  final List<WorkflowEdge> edges;
  final Map<int, WorkflowNode> byId;
  final Color color;
  final Color selectColor;
  final WorkflowEdge? selected;

  _EdgePainter({
    required this.edges,
    required this.byId,
    required this.color,
    required this.selectColor,
    this.selected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edges) {
      final from = byId[e.from.nodeId];
      final to = byId[e.to.nodeId];
      if (from == null || to == null) continue;

      // Anchor each endpoint on the actual port dot: same Edge-Anchor geometry
      // the wrapper uses to position the ports (lane top + idx * spacing).
      final start = Offset(from.x + _kNodeWidth,
          from.y + kPortLaneTop + e.from.idx * kPortSpacing);
      final end = Offset(to.x, to.y + kPortLaneTop + e.to.idx * kPortSpacing);
      final path = _edgePath(start, end);
      final isSelected = identical(e, selected) || e == selected;

      if (isSelected) {
        // Glow halo behind the crisp line.
        canvas.drawPath(
          path,
          Paint()
            ..color = selectColor
            ..strokeWidth = 6
            ..style = PaintingStyle.stroke
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }

      final paint = Paint()
        ..color = isSelected ? selectColor : color
        ..strokeWidth = isSelected ? 3 : 2
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, paint);
      canvas.drawCircle(
          end, 3, Paint()..color = isSelected ? selectColor : color);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.edges != edges ||
      old.byId != byId ||
      old.color != color ||
      old.selected != selected;
}

/// Paints the live, dashed (marching-ants) preview curve while the user drags
/// from an output port, snapping its endpoint to a hovered input port.
class _PendingEdgePainter extends CustomPainter {
  final PortRef? source;
  final Map<int, WorkflowNode> byId;
  final Offset? endpoint; // canvas-local; already snapped when [snapping]
  final bool snapping;
  final Color color;
  final Animation<double> phase;

  _PendingEdgePainter({
    required this.source,
    required this.byId,
    required this.endpoint,
    required this.snapping,
    required this.color,
    required Animation<double> repaint,
  })  : phase = repaint,
        super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final src = source;
    final end = endpoint;
    if (src == null || end == null) return;
    final from = byId[src.nodeId];
    if (from == null) return;

    final start = Offset(from.x + _kNodeWidth,
        from.y + kPortLaneTop + src.idx * kPortSpacing);
    final path = _edgePath(start, end);

    // Same color/width as completed edges, but dashed to read as in-progress.
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(_dash(path, phase.value), paint);

    // Highlight a valid snap target; otherwise mark the free pointer endpoint.
    if (snapping) {
      canvas.drawCircle(
        end,
        8,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    } else {
      canvas.drawCircle(end, 3, Paint()..color = color);
    }
  }

  Path _dash(Path src, double t, {double dash = 7, double gap = 5}) {
    final out = Path();
    final shift = t * (dash + gap); // marching ants
    for (final m in src.computeMetrics()) {
      var dist = -shift;
      while (dist < m.length) {
        final s = dist < 0 ? 0.0 : dist;
        final e = (dist + dash).clamp(0.0, m.length);
        if (e > s) out.addPath(m.extractPath(s, e), Offset.zero);
        dist += dash + gap;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_PendingEdgePainter old) => true;
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
