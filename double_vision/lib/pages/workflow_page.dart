import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/node_registry.dart';
import '../models/aa_payload.dart';
import '../models/content_payload.dart';
import '../models/workflow.dart';
import '../services/storage_service.dart';
import '../widgets/focus_panel.dart';
import '../widgets/nodes/nodes.dart';

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

  /// D4M/AA payload streams published by AA-emitting source nodes (URLNode),
  /// keyed by node id. Consumed by downstream AA-in nodes (FetchNode).
  final Map<int, Stream<AaPayload>> _aaOutputs = {};

  /// Raw location strings published by URL Source nodes, keyed by node id.
  /// Consumed by Inventory's `urlInput`.
  final Map<int, Stream<String>> _locationOutputs = {};

  /// Fetched asset streams published by Inventory's `content` port, keyed by id.
  final Map<int, Stream<ContentPayload>> _contentOutputs = {};

  /// Filenames published by source nodes (out-of-band metadata), keyed by id.
  final Map<int, String> _sourceNames = {};

  int _nextId = 1;
  bool _saving = false;

  /// True while the workflow run is in flight; disables re-clicks on "Go".
  bool _isRunning = false;

  /// Canvas geometry + keyboard focus (for Delete/Backspace on a selected edge).
  final GlobalKey _canvasKey = GlobalKey();
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'workflowCanvas');

  /// In-progress connection drag (the live preview noodle).
  PortRef? _pendingSource;
  Offset? _pendingEndpoint; // canvas-local; snapped to a port when near one
  PortRef? _pendingSnapTarget;

  /// The currently selected completed edge, if any.
  WorkflowEdge? _selectedEdge;

  /// The currently selected node, if any (distinct outline; Delete removes it).
  int? _selectedNodeId;

  /// The edge under the pointer, for hover feedback.
  WorkflowEdge? _hoveredEdge;

  /// Canvas view transform (pan + zoom). Applied to the node Stack; the Stack's
  /// own coordinate space stays untransformed, so drag/connect/hit-test math is
  /// unaffected — only the presentation moves.
  Matrix4 _view = Matrix4.identity();
  bool _isMiddlePanning = false;
  static const double _minZoom = 0.3;
  static const double _maxZoom = 3.0;

  /// Image sidebar state — the most recent image received by a Segmentation
  /// node's `preview` input, plus the resizable panel width.
  Uint8List? _sidebarImage;
  String? _sidebarName;
  int _sidebarBytes = 0;

  /// Focus Panel state — the right-margin slideout that renders heavy content
  /// so canvas nodes stay compact. [_focusNodeId] is the node whose assets are
  /// shown; [_focusUrl] is its target (local path or web address).
  bool _isFocusOpen = false;
  int? _focusNodeId;
  String? _focusUrl;

  /// Emit sinks for each Image Display node, so the Focus Panel can route
  /// overlay interactions back out of the node that owns the image.
  final Map<int, ImageDisplayOutputs> _imageDisplayOutputs = {};

  /// The three interactive output streams published by Image Display nodes,
  /// keyed by node id, so downstream nodes can subscribe.
  final Map<int, Stream<String>> _promptOutputs = {};
  final Map<int, Stream<List<double>>> _boxSelectOutputs = {};
  final Map<int, Stream<List<double>>> _pointClickOutputs = {};

  /// Which node the panel is showing, and where its asset came from.
  String? _focusSubtitle() {
    final parts = <String>[
      if (_focusNodeId != null) 'Node $_focusNodeId',
      if (_focusUrl != null)
        _focusUrl!
      else ...[
        if (_sidebarName != null) _sidebarName!,
        if (_sidebarBytes > 0) _humanSize(_sidebarBytes),
      ],
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Open the Focus Panel on a specific node instance.
  void _openImageAssets(int nodeId, String targetUrl) {
    setState(() {
      _focusNodeId = nodeId;
      _focusUrl = targetUrl;
      _isFocusOpen = true;
    });
  }

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
      case 'fetch':
      case 'chunk':
      case 'review':
      case 'aa2jsonl':
      case 'image_display':
      case 'inventory':
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
    // Clicking empty canvas selects the edge there (if any) and clears node
    // selection.
    setState(() {
      _selectedEdge = _edgeAt(d.localPosition);
      _selectedNodeId = null;
    });
  }

  void _onCanvasSecondaryTapUp(TapUpDetails d) {
    final edge = _edgeAt(d.localPosition);
    if (edge != null) {
      setState(() => _selectedEdge = edge);
      _showEdgeMenu(d.globalPosition, edge);
    } else {
      // Empty canvas → offer to add a node at the click point.
      _showAddNodeMenu(d.globalPosition, d.localPosition);
    }
  }

  /// Select a node: distinct outline, brought to the front, keyboard focus for
  /// Delete. Clears any edge selection.
  void _selectNode(int id) {
    _canvasFocus.requestFocus();
    _bringToFront(id);
    if (_selectedNodeId == id && _selectedEdge == null) return;
    setState(() {
      _selectedNodeId = id;
      _selectedEdge = null;
    });
  }

  /// Raise a node to the top of the paint order (Z-ordering convention).
  void _bringToFront(int id) {
    final i = _nodes.indexWhere((n) => n.id == id);
    if (i < 0 || i == _nodes.length - 1) return;
    setState(() {
      final n = _nodes.removeAt(i);
      _nodes.add(n);
    });
  }

  void _deleteNode(int id) {
    setState(() {
      _nodes.removeWhere((n) => n.id == id);
      _edges.removeWhere((e) => e.from.nodeId == id || e.to.nodeId == id);
      _outputs.remove(id);
      _aaOutputs.remove(id);
      _locationOutputs.remove(id);
      _contentOutputs.remove(id);
      _sourceNames.remove(id);
      if (_selectedNodeId == id) _selectedNodeId = null;
    });
  }

  void _duplicateNode(int id) {
    final src = _nodes.firstWhere((n) => n.id == id, orElse: () => _nodes.first);
    setState(() {
      _nodes.add(WorkflowNode(
        id: _nextId++,
        type: src.type,
        x: src.x + 24,
        y: src.y + 24,
      ));
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isDelete = event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace;
    if (!isDelete) return KeyEventResult.ignored;
    if (_selectedNodeId != null) {
      _deleteNode(_selectedNodeId!);
      return KeyEventResult.handled;
    }
    if (_selectedEdge != null) {
      _deleteEdge(_selectedEdge!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showNodeMenu(Offset globalPos, int id) async {
    setState(() => _selectedNodeId = id);
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      items: const [
        PopupMenuItem(value: 'duplicate', child: Text('Duplicate Node')),
        PopupMenuItem(value: 'delete', child: Text('Delete Node')),
      ],
    );
    switch (result) {
      case 'duplicate':
        _duplicateNode(id);
      case 'delete':
        _deleteNode(id);
    }
  }

  Future<void> _showAddNodeMenu(Offset globalPos, Offset canvasPos) async {
    final type = await showMenu<NodeType>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      items: [
        for (final t in nodeTypes)
          PopupMenuItem(value: t, child: Text('Add ${t.name}')),
      ],
    );
    if (type != null) _addNodeAt(type, canvasPos);
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

  /// Add a node with its top-left at a specific canvas position (from the
  /// right-click "Add" menu).
  void _addNodeAt(NodeType type, Offset canvasPos) {
    setState(() {
      _nodes.add(WorkflowNode(
        id: _nextId++,
        type: type.type,
        x: canvasPos.dx.clamp(0, 4000),
        y: canvasPos.dy.clamp(_kPortY, 4000),
      ));
    });
  }

  // --- Canvas pan & zoom (applied to the node Stack via [_view]) ---

  /// Cumulative trackpad scale since the current pan/zoom gesture began.
  double _panZoomScale = 1.0;

  double get _zoom => _view.getMaxScaleOnAxis();

  /// Zoom by [factor] keeping the point [focal] (viewport coords) fixed.
  void _zoomAt(double factor, Offset focal) {
    final s = (_zoom * factor).clamp(_minZoom, _maxZoom) / _zoom;
    if ((s - 1).abs() < 1e-3) return;
    // Scale-about-focal matrix, built column-major to avoid deprecated helpers.
    final zoom = Matrix4(
      s, 0, 0, 0,
      0, s, 0, 0,
      0, 0, 1, 0,
      focal.dx * (1 - s), focal.dy * (1 - s), 0, 1,
    );
    setState(() => _view = zoom..multiply(_view));
  }

  /// Pan the view by a viewport-space delta.
  void _panBy(Offset delta) {
    setState(() =>
        _view = Matrix4.translationValues(delta.dx, delta.dy, 0)..multiply(_view));
  }

  void _onCanvasPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Scroll up → zoom in, around the pointer.
      _zoomAt(event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1, event.localPosition);
    }
  }

  void _onCanvasPointerDown(PointerDownEvent event) {
    // Middle mouse button starts a pan (never a node drag).
    if (event.buttons & kMiddleMouseButton != 0) _isMiddlePanning = true;
  }

  void _onCanvasPointerMove(PointerMoveEvent event) {
    if (_isMiddlePanning) _panBy(event.delta);
  }

  void _onCanvasPointerUp(PointerUpEvent event) => _isMiddlePanning = false;

  // Trackpad two-finger pan + pinch zoom.
  void _onPanZoomStart(PointerPanZoomStartEvent event) => _panZoomScale = 1.0;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (event.panDelta != Offset.zero) _panBy(event.panDelta);
    if (event.scale != _panZoomScale) {
      _zoomAt(event.scale / _panZoomScale, event.localPosition);
      _panZoomScale = event.scale;
    }
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

  /// Resolve the upstream D4M/AA stream wired into [nodeId]'s input, if any.
  Stream<AaPayload>? _aaInputFor(int nodeId) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId) return _aaOutputs[e.from.nodeId];
    }
    return null;
  }

  /// Resolve the raw location stream wired into [nodeId]'s input, if any.
  Stream<String>? _locationInputFor(int nodeId) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId) return _locationOutputs[e.from.nodeId];
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

  /// Output port indices of [nodeId] that currently have an outgoing edge.
  Set<int> _connectedOutputs(int nodeId) =>
      {for (final e in _edges) if (e.from.nodeId == nodeId) e.from.idx};

  /// Resolve the graph into evaluation order: sources first (nodes with no
  /// incoming edge, e.g. Inventory / URL Source), then downstream consumers.
  /// Returns null when the graph contains a cycle, which cannot be evaluated.
  List<WorkflowNode>? _resolveExecutionOrder() {
    final byId = {for (final n in _nodes) n.id: n};
    final inDegree = {for (final n in _nodes) n.id: 0};
    final adjacency = {for (final n in _nodes) n.id: <int>[]};

    for (final e in _edges) {
      if (!byId.containsKey(e.from.nodeId) || !byId.containsKey(e.to.nodeId)) {
        continue; // edge referencing a deleted node
      }
      adjacency[e.from.nodeId]!.add(e.to.nodeId);
      inDegree[e.to.nodeId] = inDegree[e.to.nodeId]! + 1;
    }

    // Seed with the source nodes, in stable id order.
    final queue = [
      for (final n in _nodes)
        if (inDegree[n.id] == 0) n.id
    ]..sort();

    final order = <WorkflowNode>[];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      order.add(byId[id]!);
      for (final next in adjacency[id]!) {
        inDegree[next] = inDegree[next]! - 1;
        if (inDegree[next] == 0) queue.add(next);
      }
    }
    return order.length == _nodes.length ? order : null;
  }

  /// "Go" — evaluate the graph currently displayed on the canvas.
  Future<void> _runWorkflow() async {
    if (_isRunning || _nodes.isEmpty) return;
    setState(() => _isRunning = true);
    try {
      final order = _resolveExecutionOrder();
      if (order == null) {
        _showMessage('This workflow contains a cycle, so it cannot run.');
        return;
      }
      // NOTE: node widgets currently self-execute in response to their own
      // inputs (a picked file, a pressed Validate, an upstream stream event) —
      // there is no per-node run() contract to dispatch to yet. Until one
      // exists this resolves and reports the order rather than forcing
      // evaluation, so it never claims work it did not do.
      final chain = order.map((n) => n.type).join(' → ');
      _showMessage('Resolved ${order.length} node(s): $chain');
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      _aaOutputs.clear();
      _locationOutputs.clear();
      _contentOutputs.clear();
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
            onRun: _nodes.isEmpty ? null : _runWorkflow,
            running: _isRunning,
            onSave: _save,
            saving: _saving,
            onClear: _nodes.isEmpty ? null : _clear,
          ),
          Expanded(
            child: Row(
              children: [
                // Node workspace.
                Expanded(child: _canvas(context)),
                // Focus Panel: the right-margin slideout that renders heavy
                // content, so canvas nodes stay compact routing boxes. Shares
                // this horizontal shell with the canvas and toggles 0 ↔ 45%.
                FocusPanel(
                  isOpen: _isFocusOpen,
                  onToggle: () =>
                      setState(() => _isFocusOpen = !_isFocusOpen),
                  title: 'Image Assets',
                  subtitle: _focusSubtitle(),
                  targetUrl: _focusUrl,
                  // Falls back to in-memory bytes (e.g. a Segmentation
                  // preview) when no target address is focused.
                  imageBytes: _focusUrl == null ? _sidebarImage : null,
                ),
              ],
            ),
          ),
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
        // Scroll-to-zoom, middle-mouse pan, and trackpad two-finger pan/zoom.
        // The Listener passes normal events through, so node drag/connect are
        // untouched; it only *adds* view-transform handling.
        child: Listener(
          onPointerSignal: _onCanvasPointerSignal,
          onPointerDown: _onCanvasPointerDown,
          onPointerMove: _onCanvasPointerMove,
          onPointerUp: _onCanvasPointerUp,
          onPointerPanZoomStart: _onPanZoomStart,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          child: ClipRect(
            // Transform is applied to the Stack; `_canvasKey` stays on the
            // Stack so globalToLocal keeps mapping correctly under pan/zoom.
            child: Transform(
              transform: _view,
              child: Stack(
                key: _canvasKey,
                // Don't clip to the viewport-sized Stack — panning must reveal
                // nodes positioned beyond it. The outer ClipRect bounds paint.
                clipBehavior: Clip.none,
                children: [
                  // Edge layer (beneath nodes): select/deselect, right-click
                  // menu, and hover feedback. Curves live in empty canvas space.
                  Positioned.fill(
                    child: MouseRegion(
                      onHover: _onCanvasHover,
                      onExit: (_) {
                        if (_hoveredEdge != null) {
                          setState(() => _hoveredEdge = null);
                        }
                      },
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
                            hovered: _hoveredEdge,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Nodes — each is: pointer-down selects + raises it; the title
                  // bar is the drag handle; a right-click opens its menu; a
                  // distinct outline marks the selection.
                  for (final node in _nodes)
                    Positioned(
                      // Keyed so the shell (incl. its drag recogniser) survives
                      // the list reorder that brings a node to the front.
                      key: ValueKey(node.id),
                      left: node.x,
                      top: node.y,
                      child: _nodeShell(node, scheme),
                    ),

                  // Live in-progress connection curve, above everything.
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
          ),
        ),
      ),
    );
  }

  /// A node plus its interaction chrome (selection, title-bar drag handle,
  /// context menu, selected outline). The overlays size to the node via a
  /// Stack, so they adapt to each node's own width.
  Widget _nodeShell(WorkflowNode node, ColorScheme scheme) {
    return Listener(
      // Any press on the node selects it and raises it to the front.
      onPointerDown: (_) => _selectNode(node.id),
      child: GestureDetector(
        // Right-click anywhere on the node → its context menu.
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _showNodeMenu(d.globalPosition, node.id),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            KeyedSubtree(key: ValueKey(node.id), child: _buildNode(node)),

            // Title-bar drag handle — spans the node's real width, top strip.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: kTitleBarHeight,
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (_) => _bringToFront(node.id),
                  onPanUpdate: (d) => _moveNode(node.id, d.delta),
                ),
              ),
            ),

          // Selected outline: a distinct ring drawn over the node bounds.
          if (_selectedNodeId == node.id)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(kNodeRadius),
                    border: Border.all(color: scheme.tertiary, width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: scheme.tertiary,
                          blurRadius: 6,
                          spreadRadius: 1),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onCanvasHover(PointerHoverEvent event) {
    final edge = _edgeAt(event.localPosition);
    if (!identical(edge, _hoveredEdge)) {
      setState(() => _hoveredEdge = edge);
    }
  }

  Widget _buildNode(WorkflowNode node) {
    switch (node.type) {
      case 'file_source':
        return FileSourceNode(
          node: node,
          onConnect: (stream) => _outputs[node.id] = stream,
          onFileName: (name) => setState(() => _sourceNames[node.id] = name),
        );
      case 'image_display':
        return ImageDisplayNode(
          node: node,
          // `urlInput` — the source location arrives from an upstream URL
          // Source node's AA payload; the edge is recorded on drop.
          aaInput: _aaInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // The lower-right indicator opens the Focus Panel for this instance.
          onViewImageAssets: _openImageAssets,
          // The three interactive outputs, published for downstream nodes.
          onPromptConnect: (stream) => _promptOutputs[node.id] = stream,
          onBoxSelectConnect: (stream) => _boxSelectOutputs[node.id] = stream,
          onPointClickConnect: (stream) =>
              _pointClickOutputs[node.id] = stream,
          // Sinks the Focus Panel drives once overlay modes are interactive.
          onOutputsReady: (id, outputs) => _imageDisplayOutputs[id] = outputs,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'url_source':
        return UrlSourceNode(
          node: node,
          // Manual entry point: publishes the raw location string for Inventory.
          onConnect: (stream) => _locationOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'inventory':
        return InventoryNode(
          node: node,
          // `urlInput` — a raw location from an upstream URL Source node.
          locationInput: _locationInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // Catalog row for AA consumers, plus the fetched asset itself.
          onConnect: (stream) => _aaOutputs[node.id] = stream,
          onContentConnect: (stream) => _contentOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'fetch':
        return FetchNode(
          node: node,
          // Consume the upstream URLNode AA and record the input edge.
          aaInput: _aaInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // Publish the cleaned-text AA for a downstream ChunkNode.
          onConnect: (stream) => _aaOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'chunk':
        return ChunkNode(
          node: node,
          // Consume the upstream FetchNode AA and record the input edge.
          aaInput: _aaInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // Publish the passage AA for downstream processing.
          onConnect: (stream) => _aaOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'review':
        return ReviewNode(
          node: node,
          // Consume the upstream ChunkNode AA and record the input edge.
          aaInput: _aaInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // Publish the curated AA (approved + edited) for AA2JSONLNode.
          onConnect: (stream) => _aaOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'aa2jsonl':
        return Aa2JsonlNode(
          node: node,
          // Consume the upstream ChunkNode/ReviewNode AA and record the edge.
          aaInput: _aaInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // Publish the provenance AA (write manifest) for downstream use.
          onConnect: (stream) => _aaOutputs[node.id] = stream,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'preview':
        return PreviewNode(
          node: node,
          input: _inputFor(node.id),
          fileName: _fileNameFor(node.id),
          onConnect: (source) => _connect(source, node.id),
        );
      case 'sam3':
        return Sam3Node(
          node: node,
          // Register the `preview` input with the canvas so drops form an edge
          // (same wiring every other input node uses).
          onPreviewConnect: (source) => _connect(source, node.id),
          // Feed the wired-in bytes so the node can surface the image, and
          // light up the connected-port highlight (input + outputs).
          previewInput: _inputFor(node.id),
          previewFileName: _fileNameFor(node.id),
          connectedOutputs: _connectedOutputs(node.id),
          onPreviewImage: (bytes, name) => setState(() {
            _sidebarImage = bytes;
            _sidebarName = name;
            _sidebarBytes = bytes.length;
          }),
        );
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
  final WorkflowEdge? hovered;

  _EdgePainter({
    required this.edges,
    required this.byId,
    required this.color,
    required this.selectColor,
    this.selected,
    this.hovered,
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
      final isHovered = !isSelected && (identical(e, hovered) || e == hovered);

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
        ..strokeWidth = isSelected
            ? 3
            : isHovered
                ? 3
                : 2
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
      old.selected != selected ||
      old.hovered != hovered;
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

/// Human-readable byte size, e.g. 8230865 -> "7.8 MB".
String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes / 1024;
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(1)} ${units[i]}';
}


/// The thin top header: a "Workflow" dropdown of node names, the primary "Go"
/// run trigger, and Save / Clear.
class _Header extends StatelessWidget {
  final ValueChanged<NodeType> onAdd;

  /// Evaluate the graph on the canvas; null disables it (nothing to run).
  final VoidCallback? onRun;

  /// True while a run is in flight — shows the active state and blocks reclicks.
  final bool running;

  final VoidCallback onSave;
  final bool saving;

  /// Clear the workflow; null disables the button (nothing to clear).
  final VoidCallback? onClear;

  const _Header({
    required this.onAdd,
    required this.onSave,
    required this.saving,
    this.onRun,
    this.running = false,
    this.onClear,
  });

  // Reference style: dark fill, coloured border + content, rounded corners.
  static const _runColor = Color(0xFF43A047); // green (Colors.green.shade600)
  static const _saveColor = Color(0xFF5B8DEF); // blue
  static const _deleteColor = Color(0xFFE5534B); // red

  ButtonStyle _outlined(Color color) {
    // Disabled keeps the accent hue but drops to a muted tone. Without this the
    // static `side` stayed fully coloured while the label/icon fell back to the
    // theme's disabled grey — border and content disagreeing.
    final disabled = Color.lerp(color, Colors.black, 0.55)!;
    return OutlinedButton.styleFrom(
      // Colour the label and the icon explicitly, in both states.
      foregroundColor: color,
      iconColor: color,
      disabledForegroundColor: disabled,
      disabledIconColor: disabled,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ).copyWith(
      // Resolve the outline per state so it tracks the content colour.
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.disabled) ? disabled : color,
          width: 1.5,
        ),
      ),
    );
  }

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
          // Primary execution trigger — first in the action bar, before Save.
          OutlinedButton.icon(
            onPressed: running ? null : onRun,
            style: _outlined(_runColor),
            icon: running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(running ? 'Running…' : 'Go'),
          ),
          const SizedBox(width: 8),
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
