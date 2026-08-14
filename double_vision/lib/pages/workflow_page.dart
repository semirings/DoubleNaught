import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/node_registry.dart';
import '../models/content_payload.dart';
import '../services/infobus/input_port.dart';
import '../services/infobus/output_port.dart';
import '../models/node_group.dart';
import '../models/workflow.dart';
import '../services/canvas/grouping.dart';
import '../services/workflow_api.dart';
import '../services/workflow_store.dart';
import '../widgets/focus_panel.dart';
import '../widgets/node_catalog_widget.dart';
import '../widgets/nodes/nodes.dart';

/// Default node width — used both for layout and to anchor edge endpoints.
const double _kNodeWidth = 240;

/// The box-select rectangle, so tests can assert it is drawn while dragging.
const Key marqueeKey = ValueKey('canvas-marquee');

/// Wider nodes. Must match the node widgets' own `_width` (InventoryNode /
/// ReviewNode = 320). Output ports anchor at `node.x + width`, so a wrong value
/// leaves the source end of a noodle floating inside the node.
const double _kWideNodeWidth = 320;

// D4M is wider than the standard wide group (340 vs 320).
const double _kD4mNodeWidth = 340;

/// Rendered width of a node by type, for anchoring its right-edge output ports.
double _nodeWidthFor(String type) {
  if (type == 'd4m') { return _kD4mNodeWidth; }
  if (type == NodeGroup.type) { return 260; }
  if (type == 'polyglotExecNode') { return 320; }
  if (type == 'jsonlFormatterNode') { return 320; }
  if (type == 'astExtractNode') { return 320; }
  if (type == 'inventory' ||
      type == 'review' ||
      type == 'load_model' ||
      type == 'model_classifier' ||
      type == 'text_model_loader' ||
      type == 'text_prompt' ||
      type == 'text_inference') { return _kWideNodeWidth; }
  return _kNodeWidth;
}

/// Re-point Load File edges saved against the removed `contents` port.
///
/// Load File used to expose `contents` at idx 0 and `aa` at idx 1; it now has only
/// `aa`, at idx 0. Workflows saved before that carry `fromIdx: 1`, which would
/// resolve to no registered port — the wire would draw a lane too low and carry
/// nothing. Both old indices mean the same port now, so both map to 0.
///
/// Only edges leaving a `load_file` / `file_source` node are touched: idx 1 is a
/// real second output elsewhere (Split's `val`, for one). Idempotent, and the
/// corrected edges are written back on the next save.
///
/// Top-level and public so it can be tested as the pure function it is.
List<WorkflowEdge> migrateLoadFilePorts(
  List<WorkflowNode> nodes,
  List<WorkflowEdge> edges,
) {
  final loaders = {
    for (final n in nodes)
      if (n.type == 'load_file' || n.type == 'file_source') n.id,
  };
  if (loaders.isEmpty) return edges;

  return [
    for (final e in edges)
      if (loaders.contains(e.from.nodeId) && e.from.idx != 0)
        e.copyWith(from: PortRef(nodeId: e.from.nodeId, idx: 0))
      else
        e,
  ];
}

/// Vertical offset (from a node's top) at which edges attach. Approximate; the
/// real connectors sit at different heights per node type.
const double _kPortY = 40;

/// A minimal workflow editor: a thin header to instantiate and save nodes, a
/// draggable-node canvas, and connector-to-connector edge creation.
class WorkflowPage extends StatefulWidget {
  /// Workflow CRUD backend. Injected in tests; defaults to the local service.
  final WorkflowApi? workflowApi;

  /// Saved-workflow storage. **Injected in tests** — the default points at the
  /// real `storage/workflows`, so a test that deletes without overriding this
  /// would remove the user's own files.
  final WorkflowStore? workflowStore;

  const WorkflowPage({super.key, this.workflowApi, this.workflowStore});

  @override
  State<WorkflowPage> createState() => _WorkflowPageState();
}

class _WorkflowPageState extends State<WorkflowPage>
    with SingleTickerProviderStateMixin {
  static const _version = '0.1.0';

  /// Saved-workflow storage — the injected one, or the default local store.
  WorkflowStore get _store => widget.workflowStore ?? WorkflowStore();

  /// Workflow CRUD client — the injected one, or the default local backend.
  WorkflowApi get _workflowApi => widget.workflowApi ?? const WorkflowApi();

  final List<WorkflowNode> _nodes = [];
  final List<WorkflowEdge> _edges = [];

  /// Output byte streams published by source nodes, keyed by node id.
  final Map<int, Stream<Uint8List>> _outputs = {};

  /// The AA payload bus. Each AA node registers its egress [OutputPort] and/or
  /// ingress [InputPort] here, keyed by node id, so a drawn wire binds them via
  /// `inputPort.connect(outputPort)` (and `disconnect()` on delete).
  final Map<int, OutputPort> _aaOutputPorts = {};

  /// Multi-output AA nodes (e.g. SplitNode with train+val) register each port
  /// here: nodeId → portIdx → OutputPort. [_bindAaPorts] checks this first and
  /// uses [PortRef.idx] to select the correct port.
  final Map<int, Map<int, OutputPort>> _aaMultiOutputPorts = {};

  /// AA ingress ports keyed by node id, then by input-port index — a node may
  /// expose more than one AA input (e.g. Model Classifier's `aaIn` at idx 0 and
  /// `categoryIn` at idx 2; Preview's `aa` at idx 1).
  final Map<int, Map<int, InputPort>> _aaInputPorts = {};

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

  /// The set of selected node IDs (distinct outline; Delete removes them all).
  /// Shift-click adds/toggles; plain click replaces.
  final Set<int> _selectedNodeIds = {};

  // Press bookkeeping, so a press on a member of a multi-selection can start a
  // drag of the whole selection while a *click* still narrows to one node.
  // Narrowing therefore happens on release, and only if nothing moved.
  /// Per-node keys, so a box-select can measure real card heights instead of
  /// guessing them. Only read while marquee-dragging.
  final Map<int, GlobalKey> _nodeKeys = {};

  /// Box-select drag, in scene coordinates. Null when no marquee is in flight.
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  /// Selection to union with while shift-dragging, so a marquee can add to an
  /// existing selection instead of replacing it.
  Set<int> _marqueeBase = const {};

  int? _pressedNodeId;

  /// True when the press deliberately *skipped* selecting, because the node was
  /// already part of a multi-selection. Only such a press narrows on release.
  bool _pressDeferredSelect = false;
  bool _draggedSincePress = false;

  /// The edge under the pointer, for hover feedback.
  WorkflowEdge? _hoveredEdge;

  /// Canvas view transform (pan + zoom). Applied to the node Stack; the Stack's
  /// own coordinate space stays untransformed, so drag/connect/hit-test math is
  /// unaffected — only the presentation moves.
  Matrix4 _view = Matrix4.identity();
  bool _isMiddlePanning = false;
  static const double _minZoom = 0.3;
  static const double _maxZoom = 3.0;

  /// Focus Panel state — the tabbed right-margin slideout that renders heavy
  /// content (images, prose, AA dataframes) so canvas nodes stay compact. One
  /// tab per node that has pushed content: [_focusContent] holds each node's
  /// current content, [_focusOrder] fixes the tab order, and [_focusSelected]
  /// is the visible tab.
  bool _isFocusOpen = false;
  final Map<int, FocusContent> _focusContent = {};
  final List<int> _focusOrder = [];
  int _focusSelected = 0;

  /// Resizable width of the open Focus Panel body, driven by the splitter drag.
  double _focusPanelWidth = 440;
  static const double _minFocusWidth = 260;
  static const double _maxFocusWidth = 3200;

  /// Saved-workflow identity of the current canvas. Null until the graph is
  /// named via Save / Save As; a plain Clear resets it to null (a fresh, unnamed
  /// workflow, so the next Save prompts for a name).
  String? _currentWorkflowSlug;
  String? _currentWorkflowName;

  /// Cached listing for the Workflows dropdown; refreshed after save/delete.
  List<WorkflowMeta> _savedWorkflows = const [];

  /// D4M nodes selected for the merge operation. When 2+ nodes are in this set
  /// the Merge button becomes active; the merge combines their scripts
  /// left-to-right, rewires all incoming edges to the first node, and deletes
  /// the rest.
  final Set<int> _d4mMergeSet = {};

  /// Per-node saved settings (dropdown selections, manual fields, …), keyed by
  /// node id. Nodes report changes via their `onParams` callback; the value is
  /// captured into each node's [WorkflowNode.params] at save time and restored
  /// as `initialParams` on load.
  final Map<int, Map<String, String>> _nodeParams = {};

  /// Bumped on every workflow load so node widget keys change, forcing fresh
  /// State (and thus a re-read of restored `initialParams`) even when the loaded
  /// graph reuses the same node ids as the canvas it replaced.
  int _loadGeneration = 0;

  /// Emit sinks for each Image Display node, so the Focus Panel can route
  /// overlay interactions back out of the node that owns the image.
  final Map<int, ImageDisplayOutputs> _imageDisplayOutputs = {};

  /// The three interactive output streams published by Image Display nodes,
  /// keyed by node id, so downstream nodes can subscribe.
  final Map<int, Stream<String>> _promptOutputs = {};
  final Map<int, Stream<List<double>>> _boxSelectOutputs = {};
  final Map<int, Stream<List<double>>> _pointClickOutputs = {};

  /// Friendly display name per node type, for the Focus Panel tab labels.
  static final Map<String, String> _typeNames = {
    for (final t in nodeTypes) t.type: t.name,
  };

  /// The Focus Panel tabs, derived from pushed content in insertion order,
  /// skipping any node that has since been deleted.
  List<FocusTab> _focusTabs() {
    final byId = {for (final n in _nodes) n.id: n};
    final tabs = <FocusTab>[];
    for (final id in _focusOrder) {
      final content = _focusContent[id];
      final node = byId[id];
      if (content == null || node == null) continue;
      tabs.add(
        FocusTab(
          nodeId: id,
          title: '${_typeNames[node.type] ?? node.type} $id',
          content: content,
        ),
      );
    }
    return tabs;
  }

  int _focusIndexOf(int nodeId) {
    final i = _focusTabs().indexWhere((t) => t.nodeId == nodeId);
    return i < 0 ? 0 : i;
  }

  /// Push (or refresh) a node's content into the panel. The first time a node
  /// contributes, the panel opens and selects its tab; later refreshes update
  /// in place without stealing the current selection.
  void _pushFocusContent(int nodeId, FocusContent content) {
    setState(() {
      final isNew = !_focusContent.containsKey(nodeId);
      _focusContent[nodeId] = content;
      if (!_focusOrder.contains(nodeId)) _focusOrder.add(nodeId);
      if (isNew) {
        _isFocusOpen = true;
        _focusSelected = _focusIndexOf(nodeId);
      }
    });
  }

  /// Retract a node's tab when it no longer has content to show — e.g. a
  /// Preview whose input was unwired. Without this the panel would keep
  /// rendering a payload the node itself has already dropped.
  void _clearFocusContent(int nodeId) {
    if (!_focusContent.containsKey(nodeId)) return;
    setState(() {
      _focusContent.remove(nodeId);
      _focusOrder.remove(nodeId);
      _focusSelected = _focusSelected.clamp(
        0,
        _focusOrder.isEmpty ? 0 : _focusOrder.length - 1,
      );
    });
  }

  /// Open the panel and select a node's tab (the node's "View" affordance).
  void _openFocusTab(int nodeId) {
    setState(() {
      _isFocusOpen = true;
      _focusSelected = _focusIndexOf(nodeId);
    });
  }

  /// Open the Focus Panel on an Image Display node's target as an image tab.
  void _openImageAssets(int nodeId, String targetUrl) {
    _pushFocusContent(
      nodeId,
      FocusContent.image(url: targetUrl, subtitle: targetUrl),
    );
    _openFocusTab(nodeId);
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
    _refreshSavedWorkflows();
  }

  @override
  void dispose() {
    _ants.dispose();
    _canvasFocus.dispose();
    super.dispose();
  }

  // --- Port geometry (shared with the painters via the same constants) ---

  Offset _outputPortPos(WorkflowNode n, int idx) => Offset(
    n.x + _nodeWidthFor(n.type),
    n.y + kPortLaneTop + idx * kPortSpacing,
  );
  Offset _inputPortPos(WorkflowNode n, int idx) =>
      Offset(n.x, n.y + kPortLaneTop + idx * kPortSpacing);

  /// Input port indices a node exposes (for snap targeting).
  Iterable<int> _inputIndicesFor(WorkflowNode n) {
    switch (n.type) {
      case 'preview':
        // Two inputs: `bytes` (idx 0) and `aa` (idx 1).
        return const [0, 1];
      case 'load_model':
        // Two inputs: `trigger` (AA, idx 0) and `urlIn` (String, idx 1).
        return const [0, 1];
      case 'model_classifier':
        // Three inputs: `aaIn` (AA, idx 0), `modelIn` (String, idx 1),
        // `categoryIn` (AA, idx 2).
        return const [0, 1, 2];
      case 'save_file':
        // Three inputs: `aaIn` (AA, idx 0), `textIn` (String, idx 1),
        // `imageIn` (bytes, idx 2).
        return const [0, 1, 2];
      case NodeGroup.type:
        // One input per boundary the group exposes.
        return [
          for (final b in (NodeGroup.subgraphOf(n)?.inputs ?? const []))
            b.idx,
        ];
      case 'promptNode':
      case 'prompt_node': // tolerate a snake_case spelling in saved workflows
        // One input: `fileInput` (AA, idx 0).
        return const [0];
      case 'remoteServiceNode':
      case 'remote_service': // tolerate a snake_case spelling in saved workflows
        // Two inputs: `dataInput` (AA, idx 0), `authInput` (AA, idx 1).
        return const [0, 1];
      case 'polyglotExecNode':
      case 'polyglot_exec': // tolerate a snake_case spelling in saved workflows
        // One input: `in_aa` (AA, idx 0).
        return const [0];
      case 'jsonlFormatterNode':
      case 'jsonl_formatter': // tolerate a snake_case spelling in saved workflows
        // One input: `in_aa` (AA, idx 0).
        return const [0];
      case 'astExtractNode':
      case 'ast_extract': // tolerate a snake_case spelling in saved workflows
        // One input: `in_aa` (AA, idx 0) — supplies the path to parse.
        return const [0];
      case 'text_model_loader':
        // One optional input: `trigger` (AA, idx 0).
        return const [0];
      case 'text_inference':
        // Two inputs: `modelHandle` (AA, idx 0), `promptIn` (AA, idx 1).
        return const [0, 1];
      case 'text_preview':
        // One input: `resultIn` (AA, idx 0).
        return const [0];
      case 'd4m':
        // Dynamic: snap to whichever input indices are actually registered.
        return _aaInputPorts[n.id]?.keys ?? const [0];
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
      final pt =
          start * (u * u * u) +
          c1 * (3 * u * u * t) +
          c2 * (3 * u * t * t) +
          end * (t * t * t);
      final d = (pt - p).distance;
      if (d < best) best = d;
    }
    return best;
  }

  void _onCanvasTapUp(TapUpDetails d) {
    debugPrint('[D4M-diag] _onCanvasTapUp fired');
    _canvasFocus.requestFocus(); // so Delete/Backspace target this canvas
    // Clicking empty canvas selects the edge there (if any) and clears node
    // selection.
    setState(() {
      _selectedEdge = _edgeAt(d.localPosition);
      _selectedNodeIds.clear();
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
  /// Delete. When [extend] is true (Shift-click) the node is toggled into/out of
  /// the selection; otherwise the set is replaced with just this node.
  void _selectNode(int id, {bool extend = false}) {
    // Do NOT call _canvasFocus.requestFocus() here.  Stealing keyboard focus on
    // every node click would freeze any TextField the user is editing inside a
    // node.  Canvas focus is established by autofocus:true at startup and by
    // _onCanvasTapUp when the user clicks the empty canvas.  _onKey already
    // ignores Delete/Backspace when focus is on anything other than _canvasFocus,
    // so node-deletion shortcuts still work correctly when the canvas is focused.
    setState(() {
      // Bring to front (inlined to avoid a second setState / canvas rebuild).
      final i = _nodes.indexWhere((n) => n.id == id);
      if (i >= 0 && i != _nodes.length - 1) {
        final n = _nodes.removeAt(i);
        _nodes.add(n);
      }
      if (extend) {
        if (_selectedNodeIds.contains(id)) {
          _selectedNodeIds.remove(id);
        } else {
          _selectedNodeIds.add(id);
        }
      } else {
        _selectedNodeIds
          ..clear()
          ..add(id);
      }
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
    // Unbind any downstream inputs this node was feeding, then drop its ports.
    for (final e in _edges.where((e) => e.from.nodeId == id)) {
      _unbindAaInput(e.to.nodeId, e.to.idx);
    }
    _unbindAaInput(id);
    setState(() {
      _nodes.removeWhere((n) => n.id == id);
      _edges.removeWhere((e) => e.from.nodeId == id || e.to.nodeId == id);
      _outputs.remove(id);
      _aaOutputPorts.remove(id);
      _aaMultiOutputPorts.remove(id);
      _aaInputPorts.remove(id);
      _locationOutputs.remove(id);
      _contentOutputs.remove(id);
      _sourceNames.remove(id);
      _nodeParams.remove(id);
      _focusContent.remove(id);
      _focusOrder.remove(id);
      _focusSelected = _focusSelected.clamp(
        0,
        _focusOrder.isEmpty ? 0 : _focusOrder.length - 1,
      );
      _selectedNodeIds.remove(id);
    });
  }

  void _deleteSelectedNodes() {
    final ids = Set<int>.from(_selectedNodeIds);
    if (ids.isEmpty) return;
    // Unbind all downstream inputs before the single setState to avoid repeated
    // rebuilds (calling _deleteNode in a loop triggers one setState each).
    for (final id in ids) {
      for (final e in _edges.where((e) => e.from.nodeId == id)) {
        _unbindAaInput(e.to.nodeId, e.to.idx);
      }
      _unbindAaInput(id);
    }
    setState(() {
      for (final id in ids) {
        _nodes.removeWhere((n) => n.id == id);
        _edges.removeWhere((e) => e.from.nodeId == id || e.to.nodeId == id);
        _outputs.remove(id);
        _aaOutputPorts.remove(id);
        _aaMultiOutputPorts.remove(id);
        _aaInputPorts.remove(id);
        _locationOutputs.remove(id);
        _contentOutputs.remove(id);
        _sourceNames.remove(id);
        _nodeParams.remove(id);
        _focusContent.remove(id);
        _focusOrder.remove(id);
      }
      _focusSelected = _focusSelected.clamp(
        0,
        _focusOrder.isEmpty ? 0 : _focusOrder.length - 1,
      );
      _selectedNodeIds.clear();
    });
  }

  void _copySelectedNodes() {
    final ids = _selectedNodeIds;
    if (ids.isEmpty) return;
    final selected = _nodes.where((n) => ids.contains(n.id)).toList();
    final payload = jsonEncode({
      'nodes': [
        for (final n in selected)
          {'id': n.id, 'type': n.type, 'x': n.x, 'y': n.y},
      ],
      'edges': [
        for (final e in _edges)
          if (ids.contains(e.from.nodeId) && ids.contains(e.to.nodeId))
            {
              'fromNodeId': e.from.nodeId,
              'fromIdx': e.from.idx,
              'toNodeId': e.to.nodeId,
              'toIdx': e.to.idx,
            },
      ],
    });
    Clipboard.setData(ClipboardData(text: payload)).ignore();
  }

  void _duplicateNode(int id) {
    final src = _nodes.firstWhere(
      (n) => n.id == id,
      orElse: () => _nodes.first,
    );
    setState(() {
      _nodes.add(
        WorkflowNode(
          id: _nextId++,
          type: src.type,
          x: src.x + 24,
          y: src.y + 24,
        ),
      );
    });
  }

  // --- Group / ungroup / regroup -------------------------------------------

  /// Container a child came out of, kept so [_regroupSelected] can rebuild the
  /// same group in the same place. Keyed by child node id; the value is the
  /// removed container itself, which carries its id, position and label.
  ///
  /// Entries are dropped as soon as they are used or the child is deleted, so a
  /// stale cache cannot resurrect a group whose members are long gone.
  final Map<int, WorkflowNode> _previousGroupOf = {};

  /// Collapse the current selection into a group node (⌘G).
  void _groupSelected({int? reuseId, double? atX, double? atY, String? label}) {
    final result = Grouping.group(
      nodes: _nodes,
      edges: _edges,
      selection: _selectedNodeIds,
      newId: _nextId,
      reuseId: reuseId,
      atX: atX,
      atY: atY,
      label: label,
    );
    if (result == null) return;

    // Members are leaving the canvas: their widgets unmount, so drop the port
    // registrations that pointed at them or the bus keeps dead ports.
    for (final id in _selectedNodeIds) {
      _forgetNodeWiring(id);
    }
    if (reuseId == null) _nextId++;

    setState(() {
      _nodes
        ..clear()
        ..addAll(result.nodes);
      _edges
        ..clear()
        ..addAll(result.edges);
      _selectedNodeIds
        ..clear()
        ..addAll(result.selection);
      _selectedEdge = null;
    });
  }

  /// Expand the selected group back onto the canvas (⌘⇧G).
  void _ungroupSelected() {
    final container = _nodes
        .where((n) =>
            _selectedNodeIds.contains(n.id) && NodeGroup.isGroup(n))
        .firstOrNull;
    if (container == null) return;

    final result = Grouping.ungroup(
      nodes: _nodes,
      edges: _edges,
      groupId: container.id,
    );
    if (result == null) return;

    _forgetNodeWiring(container.id);

    setState(() {
      _nodes
        ..clear()
        ..addAll(result.nodes);
      _edges
        ..clear()
        ..addAll(result.edges);
      _selectedNodeIds
        ..clear()
        ..addAll(result.selection);
      _selectedEdge = null;
      // Remember where these came from so ⌘⌥G can put them back.
      for (final id in result.selection) {
        _previousGroupOf[id] = container;
      }
    });

    // Children are mounting fresh, so their params must be restorable: seed the
    // per-node param store from what the subgraph carried.
    final sub = NodeGroup.subgraphOf(container);
    if (sub != null) {
      for (final child in sub.nodes) {
        if (child.params.isNotEmpty) _nodeParams[child.id] = child.params;
      }
    }
  }

  /// Rebuild the group the selection was last unpacked from (⌘⌥G).
  ///
  /// Boundaries are re-derived from the *current* edges rather than replayed from
  /// the cache, so a wire added or removed while the nodes were loose is honoured
  /// instead of silently reverted. Only the container's identity — id, position,
  /// label — is restored from the cache.
  void _regroupSelected() {
    final previous = _selectedNodeIds
        .map((id) => _previousGroupOf[id])
        .whereType<WorkflowNode>()
        .firstOrNull;
    if (previous == null) {
      // Nothing was unpacked: fall back to forming a fresh group, which is what
      // a user pressing "regroup" on an arbitrary selection means.
      _groupSelected();
      return;
    }

    final ids = _selectedNodeIds.toSet();
    _groupSelected(
      reuseId: _nodes.any((n) => n.id == previous.id) ? null : previous.id,
      atX: previous.x,
      atY: previous.y,
      label: NodeGroup.labelOf(previous),
    );
    for (final id in ids) {
      _previousGroupOf.remove(id);
    }
  }

  /// Drop every canvas-side registration for [id] — port bus entries, focus tab,
  /// cached streams. Called when a node's widget is about to unmount because it
  /// moved into or out of a group.
  void _forgetNodeWiring(int id) {
    _unbindAaInput(id);
    for (final e in _edges.where((e) => e.from.nodeId == id)) {
      _unbindAaInput(e.to.nodeId, e.to.idx);
    }
    _aaOutputPorts.remove(id);
    _aaMultiOutputPorts.remove(id);
    _aaInputPorts.remove(id);
    _outputs.remove(id);
    _locationOutputs.remove(id);
    _contentOutputs.remove(id);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final isDelete =
        event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace;
    final meta = HardwareKeyboard.instance.isMetaPressed; // Cmd on macOS
    final isCopy = event.logicalKey == LogicalKeyboardKey.keyC && meta;

    // ⌘G group · ⌘⇧G ungroup · ⌘⌥G regroup. Checked most-modified first, since
    // ⌘⇧G also satisfies the bare ⌘G test.
    final isG = event.logicalKey == LogicalKeyboardKey.keyG && meta;
    final isUngroup = isG && HardwareKeyboard.instance.isShiftPressed;
    final isRegroup = isG && HardwareKeyboard.instance.isAltPressed;
    final isGroup = isG && !isUngroup && !isRegroup;

    if (!isDelete && !isCopy && !isG) return KeyEventResult.ignored;

    // If a text field (not the canvas) is focused, let it handle the key.
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus != _canvasFocus) {
      return KeyEventResult.ignored;
    }

    if (isCopy) {
      _copySelectedNodes();
      return _selectedNodeIds.isNotEmpty
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (isG) {
      if (_selectedNodeIds.isEmpty) return KeyEventResult.ignored;
      if (isUngroup) {
        _ungroupSelected();
      } else if (isRegroup) {
        _regroupSelected();
      } else if (isGroup) {
        _groupSelected();
      }
      return KeyEventResult.handled;
    }

    if (_selectedNodeIds.isNotEmpty) {
      _deleteSelectedNodes();
      return KeyEventResult.handled;
    }
    if (_selectedEdge != null) {
      _deleteEdge(_selectedEdge!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showNodeMenu(Offset globalPos, int id) async {
    // A right-click on a node outside the current selection retargets to it;
    // clicking one *inside* a multi-selection keeps the selection, so Group can
    // act on all of it.
    final keepSelection =
        _selectedNodeIds.length > 1 && _selectedNodeIds.contains(id);
    if (!keepSelection) {
      setState(() {
        _selectedNodeIds
          ..clear()
          ..add(id);
        _selectedEdge = null;
      });
    }

    final node = _nodes.where((n) => n.id == id).firstOrNull;
    final isGroup = node != null && NodeGroup.isGroup(node);
    final canRegroup = _selectedNodeIds.any(_previousGroupOf.containsKey);

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx,
        globalPos.dy,
      ),
      items: [
        if (isGroup)
          const PopupMenuItem(value: 'ungroup', child: Text('Ungroup  ⌘⇧G'))
        else ...[
          if (_selectedNodeIds.length > 1)
            const PopupMenuItem(value: 'group', child: Text('Group  ⌘G')),
          PopupMenuItem(
            value: 'regroup',
            enabled: canRegroup,
            child: const Text('Regroup  ⌘⌥G'),
          ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'duplicate', child: Text('Duplicate Node')),
        const PopupMenuItem(value: 'delete', child: Text('Delete Node')),
      ],
    );
    switch (result) {
      case 'ungroup':
        _ungroupSelected();
      case 'group':
        _groupSelected();
      case 'regroup':
        _regroupSelected();
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
        globalPos.dx,
        globalPos.dy,
        globalPos.dx,
        globalPos.dy,
      ),
      items: [
        for (final t in nodeTypes)
          PopupMenuItem(value: t, child: Text('Add ${t.name}')),
      ],
    );
    if (type != null) _addNodeAt(type, canvasPos);
  }

  void _deleteEdge(WorkflowEdge e) {
    _unbindAaInput(e.to.nodeId);
    setState(() {
      _edges.remove(e);
      if (identical(_selectedEdge, e)) _selectedEdge = null;
    });
  }

  void _disconnectSource(WorkflowEdge e) {
    for (final x in _edges.where(
      (x) => x.from.nodeId == e.from.nodeId && x.from.idx == e.from.idx,
    )) {
      _unbindAaInput(x.to.nodeId);
    }
    setState(() {
      _edges.removeWhere(
        (x) => x.from.nodeId == e.from.nodeId && x.from.idx == e.from.idx,
      );
      _selectedEdge = null;
    });
  }

  void _disconnectTarget(WorkflowEdge e) {
    _unbindAaInput(e.to.nodeId);
    setState(() {
      _edges.removeWhere(
        (x) => x.to.nodeId == e.to.nodeId && x.to.idx == e.to.idx,
      );
      _selectedEdge = null;
    });
  }

  Future<void> _showEdgeMenu(Offset globalPos, WorkflowEdge edge) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx,
        globalPos.dy,
      ),
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
      // Grid placement: 3 columns × 280px rows. Column width (360px) exceeds
      // the widest node (320px); row height (280px) clears tall nodes. Nodes
      // never overlap on either axis regardless of how many are added.
      final col = _nodes.length % 3;
      final row = _nodes.length ~/ 3;
      _nodes.add(
        WorkflowNode(
          id: _nextId++,
          type: type.type,
          x: 32.0 + col * 360.0,
          y: 48.0 + row * 280.0,
        ),
      );
    });
  }

  /// Add a node with its top-left at a specific canvas position (from the
  /// right-click "Add" menu).
  void _addNodeAt(NodeType type, Offset canvasPos) {
    setState(() {
      _nodes.add(
        WorkflowNode(
          id: _nextId++,
          type: type.type,
          x: canvasPos.dx.clamp(0, 4000),
          y: canvasPos.dy.clamp(_kPortY, 4000),
        ),
      );
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
      s,
      0,
      0,
      0,
      0,
      s,
      0,
      0,
      0,
      0,
      1,
      0,
      focal.dx * (1 - s),
      focal.dy * (1 - s),
      0,
      1,
    );
    setState(() => _view = zoom..multiply(_view));
  }

  GlobalKey _nodeKeyFor(int id) => _nodeKeys.putIfAbsent(id, GlobalKey.new);

  /// Rendered size of a node's card, or null before its first layout.
  Size? _nodeSize(int id) {
    final box = _nodeKeys[id]?.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  /// A node's bounds in scene coordinates.
  ///
  /// Width comes from the type table; height is *measured*, because cards size
  /// themselves to their content and a nominal value would put the marquee tens
  /// of pixels wrong on the tall nodes. The fallback only applies to a node that
  /// has not laid out yet.
  Rect _nodeRect(WorkflowNode n) => Rect.fromLTWH(
        n.x,
        n.y,
        _nodeWidthFor(n.type),
        _nodeSize(n.id)?.height ?? 140,
      );

  /// The topmost node under a scene point, or null over empty canvas. Later
  /// entries in [_nodes] paint on top, so the search runs backwards.
  WorkflowNode? _nodeAt(Offset scene) {
    for (final n in _nodes.reversed) {
      if (_nodeRect(n).contains(scene)) return n;
    }
    return null;
  }

  Rect? get _marqueeRect {
    final a = _marqueeStart;
    final b = _marqueeEnd;
    return (a == null || b == null) ? null : Rect.fromPoints(a, b);
  }

  /// Begin a box-select — unless the drag started on a node, which belongs to
  /// that node rather than to the canvas.
  void _onCanvasPanStart(DragStartDetails d) {
    if (_nodeAt(d.localPosition) != null) return;
    _canvasFocus.requestFocus(); // so Delete / Cmd-G land here afterwards
    final extend = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      _marqueeStart = d.localPosition;
      _marqueeEnd = d.localPosition;
      _marqueeBase = extend ? {..._selectedNodeIds} : const {};
      _selectedEdge = null;
      // The old selection is left standing until the first move event replaces
      // it. Clearing here instead would drop the selection bar out of the page
      // column and then put it back, jolting the canvas twice mid-drag.
    });
  }

  void _onCanvasPanUpdate(DragUpdateDetails d) {
    if (_marqueeStart == null) return;
    setState(() {
      _marqueeEnd = d.localPosition;
      final rect = _marqueeRect!;
      _selectedNodeIds
        ..clear()
        ..addAll(_marqueeBase)
        // Touching is enough, as on every other canvas: a node need not be
        // wholly enclosed to be caught.
        ..addAll([
          for (final n in _nodes)
            if (_nodeRect(n).overlaps(rect)) n.id,
        ]);
    });
  }

  void _onCanvasPanEnd(DragEndDetails d) {
    if (_marqueeStart == null) return;
    setState(() {
      _marqueeStart = null;
      _marqueeEnd = null;
      _marqueeBase = const {};
    });
  }

  /// Pan the view by a viewport-space delta.
  void _panBy(Offset delta) {
    setState(
      () =>
          _view = Matrix4.translationValues(delta.dx, delta.dy, 0)
            ..multiply(_view),
    );
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
  /// Drag [id] by [delta] — and everything selected with it.
  ///
  /// Dragging a node that is part of a multi-selection moves the whole selection,
  /// which is what a user who just shift-clicked five nodes expects. Dragging a
  /// node that is *not* selected moves only that node (the pointer-down handler
  /// has already made it the selection by then).
  ///
  /// The delta is clamped **once against the whole set**, not per node: clamping
  /// each node independently would let one node stop at the canvas edge while its
  /// neighbours kept going, shearing the arrangement apart. Here the first node
  /// to reach a bound stops the entire selection, so relative positions survive
  /// any drag.
  void _moveNode(int id, Offset delta) {
    final moving = (_selectedNodeIds.length > 1 && _selectedNodeIds.contains(id))
        ? _selectedNodeIds
        : {id};

    var dx = delta.dx;
    var dy = delta.dy;
    for (final n in _nodes) {
      if (!moving.contains(n.id)) continue;
      dx = dx.clamp(-n.x, 4000 - n.x);
      dy = dy.clamp(_kPortY - n.y, 4000 - n.y);
    }
    if (dx == 0 && dy == 0) return;

    setState(() {
      for (var i = 0; i < _nodes.length; i++) {
        final n = _nodes[i];
        if (!moving.contains(n.id)) continue;
        _nodes[i] = n.copyWith(x: n.x + dx, y: n.y + dy);
      }
    });
  }

  /// Record an edge from [source] into [targetId]'s input port [targetIdx],
  /// replacing any existing edge feeding that same input.
  void _connectAt(PortRef source, int targetId, int targetIdx) {
    // Replacing any existing wire into this specific input: drop its binding.
    _unbindAaInput(targetId, targetIdx);
    setState(() {
      _edges.removeWhere(
        (e) => e.to.nodeId == targetId && e.to.idx == targetIdx,
      );
      _edges.add(
        WorkflowEdge(
          from: source,
          to: PortRef(nodeId: targetId, idx: targetIdx),
        ),
      );
    });
    // Bind the AA port bus (no-op unless this is the target's AA input).
    _bindAaPorts(source, targetId, targetIdx);
  }

  /// Single-input convenience: connect into input port 0.
  void _connect(PortRef source, int targetId) =>
      _connectAt(source, targetId, 0);

  /// Resolve the upstream byte stream wired into [nodeId]'s input port [idx].
  Stream<Uint8List>? _inputForAt(int nodeId, int idx) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId && e.to.idx == idx) {
        return _outputs[e.from.nodeId];
      }
    }
    return null;
  }

  /// Resolve the upstream byte stream wired into [nodeId]'s input port 0.
  Stream<Uint8List>? _inputFor(int nodeId) => _inputForAt(nodeId, 0);

  /// Whether an edge feeds [nodeId]'s input port 0 (drives the input highlight).
  bool _hasIncomingEdge(int nodeId) => _hasIncomingEdgeAt(nodeId, 0);

  /// Whether an edge feeds [nodeId]'s input port [idx].
  bool _hasIncomingEdgeAt(int nodeId, int idx) =>
      _edges.any((e) => e.to.nodeId == nodeId && e.to.idx == idx);

  /// Register an AA ingress port for [nodeId] at input-port index [idx]. Nodes
  /// call this from their `onInputPort`-style callbacks as they build; a node
  /// may register several (e.g. Model Classifier's `aaIn` at idx 0 and
  /// `categoryIn` at idx 2).
  void _registerAaInput(int nodeId, int idx, InputPort port) {
    (_aaInputPorts[nodeId] ??= <int, InputPort>{})[idx] = port;
  }

  /// Bind an AA edge on the port bus: the target's InputPort subscribes to the
  /// source's OutputPort. No-op unless the target exposes an AA input at exactly
  /// [targetIdx] and the source carries an AA output.
  void _bindAaPorts(PortRef source, int targetId, int targetIdx) {
    // Multi-output nodes (e.g. SplitNode) register per-port index; single-
    // output nodes fall back to the flat _aaOutputPorts map (always idx 0).
    final multiPorts = _aaMultiOutputPorts[source.nodeId];
    final out = multiPorts != null
        ? multiPorts[source.idx]
        : _aaOutputPorts[source.nodeId];
    final input = _aaInputPorts[targetId]?[targetIdx];
    if (out != null && input != null) input.connect(out);
  }

  /// Unbind [targetId]'s AA InputPort(s) on wire delete / replace / node
  /// removal. With [targetIdx] only that one input is severed (so a byte edge
  /// into Preview's idx 0 never touches its AA binding at idx 1); without it,
  /// every AA input on the node is disconnected.
  void _unbindAaInput(int targetId, [int? targetIdx]) {
    final ports = _aaInputPorts[targetId];
    if (ports == null) return;
    if (targetIdx != null) {
      ports[targetIdx]?.disconnect();
    } else {
      for (final p in ports.values) {
        p.disconnect();
      }
    }
  }

  /// Resolve the raw location stream wired into [nodeId]'s input port 0, if any.
  Stream<String>? _locationInputFor(int nodeId) =>
      _locationInputForAt(nodeId, 0);

  /// Resolve the raw location stream wired into [nodeId]'s input port [idx].
  Stream<String>? _locationInputForAt(int nodeId, int idx) {
    for (final e in _edges) {
      if (e.to.nodeId == nodeId && e.to.idx == idx) {
        return _locationOutputs[e.from.nodeId];
      }
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
  Set<int> _connectedOutputs(int nodeId) => {
    for (final e in _edges)
      if (e.from.nodeId == nodeId) e.from.idx,
  };

  // ---------------------------------------------------------------------------
  // D4M merge / adjacent-node helpers
  // ---------------------------------------------------------------------------

  /// Toggle [nodeId] in/out of the D4M merge selection set.
  void _toggleD4mMerge(int nodeId) {
    setState(() {
      if (_d4mMergeSet.contains(nodeId)) {
        _d4mMergeSet.remove(nodeId);
      } else {
        _d4mMergeSet.add(nodeId);
      }
    });
  }

  /// Merge all D4M nodes in [_d4mMergeSet]: combine their scripts left-to-right
  /// into the leftmost node (by canvas x), rewire all incoming edges to it,
  /// delete the rest, and clear the merge set.
  void _mergeD4mNodes() {
    if (_d4mMergeSet.length < 2) return;
    // Collect the nodes to merge, ordered left-to-right by canvas x position.
    final toMerge = _nodes
        .where((n) => _d4mMergeSet.contains(n.id))
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    final primary = toMerge.first;

    // Combine scripts: join with a newline, skipping empty scripts.
    final primaryParams =
        Map<String, String>.from(_nodeParams[primary.id] ?? {});
    final combinedScript = toMerge
        .map((n) => (_nodeParams[n.id]?['script'] ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
    primaryParams['script'] = combinedScript;

    // Combine port names: union of all port name lists (deduped, primary's first).
    final allPorts = <String>{};
    allPorts.addAll((primaryParams['portNames'] ?? 'A').split(','));
    for (final n in toMerge.skip(1)) {
      allPorts.addAll(
          (_nodeParams[n.id]?['portNames'] ?? '').split(','));
    }
    allPorts.removeWhere((s) => s.isEmpty);
    primaryParams['portNames'] = allPorts.join(',');

    setState(() {
      _nodeParams[primary.id] = primaryParams;

      // Rewire incoming edges from secondary nodes to primary.
      int nextIdx = (primaryParams['portNames'] ?? 'A').split(',').length;
      for (final n in toMerge.skip(1)) {
        for (final e in _edges.where((e) => e.to.nodeId == n.id).toList()) {
          _edges.remove(e);
          _edges.add(WorkflowEdge(
            from: e.from,
            to: PortRef(nodeId: primary.id, idx: nextIdx++),
          ));
        }
        // Redirect any outgoing edges from secondary nodes to primary.
        for (final e in _edges.where((e) => e.from.nodeId == n.id).toList()) {
          _edges.remove(e);
          _edges.add(WorkflowEdge(
            from: PortRef(nodeId: primary.id, idx: e.from.idx),
            to: e.to,
          ));
        }
        _aaOutputPorts.remove(n.id);
        _aaMultiOutputPorts.remove(n.id);
        _aaInputPorts.remove(n.id);
        _nodeParams.remove(n.id);
        _nodes.removeWhere((node) => node.id == n.id);
      }
      _d4mMergeSet.clear();
    });
  }

  /// Spawn a new D4M node immediately to the left or right of [node] on the
  /// canvas, pre-wired so the new node's output feeds into [node]'s next input
  /// port (onAddLeft) or [node]'s output connects to the new node's first input
  /// (onAddRight).
  void _addAdjacentD4mNode(WorkflowNode node, {required bool isLeft}) {
    const kAdjacentOffset = 360.0;
    final newNode = WorkflowNode(
      id: _nextId++,
      type: 'd4m',
      x: isLeft ? node.x - kAdjacentOffset : node.x + kAdjacentOffset,
      y: node.y,
    );
    setState(() {
      _nodes.add(newNode);
      if (isLeft) {
        // New node's output (idx 0) → existing node's next free input.
        final nextIdx = _edges
            .where((e) => e.to.nodeId == node.id)
            .map((e) => e.to.idx)
            .fold<int>(-1, (m, i) => i > m ? i : m) +
            1;
        _edges.add(WorkflowEdge(
          from: PortRef(nodeId: newNode.id, idx: 0),
          to: PortRef(nodeId: node.id, idx: nextIdx),
        ));
      } else {
        // Existing node's output (idx 0) → new node's first input (idx 0).
        _edges.add(WorkflowEdge(
          from: PortRef(nodeId: node.id, idx: 0),
          to: PortRef(nodeId: newNode.id, idx: 0),
        ));
      }
    });
    // _addAdjacentD4mNode builds the edge before the new node exists, so
    // _bindAaPorts (called from _connectAt) never ran.  Defer until after
    // the frame so the new node's initState has finished registering ports
    // and wiring its onDataArrived listener.
    if (!isLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _bindAaPorts(PortRef(nodeId: node.id, idx: 0), newNode.id, 0);
      });
    }
  }

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
        if (inDegree[n.id] == 0) n.id,
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Saved-workflow lifecycle (name modal, uniqueness, load, delete) ---

  Future<void> _refreshSavedWorkflows() async {
    try {
      final list = await _store.list();
      if (mounted) setState(() => _savedWorkflows = list);
    } catch (_) {
      // Listing is best-effort; a storage error just leaves the menu empty.
    }
  }

  /// Save button: silently overwrite the current named workflow, or prompt for
  /// a name the first time (an unnamed canvas).
  Future<void> _save() async {
    if (_currentWorkflowSlug == null) {
      await _saveAs();
    } else {
      await _writeWorkflow(_currentWorkflowSlug!, _currentWorkflowName!);
    }
  }

  /// Save As: always prompt for a (new) name, enforcing uniqueness with an
  /// overwrite confirm.
  Future<void> _saveAs() async {
    final name = await _promptWorkflowName(initial: _currentWorkflowName);
    if (name == null) return; // cancelled
    final slug = WorkflowStore.slugify(name);
    if (slug != _currentWorkflowSlug && await _store.exists(slug)) {
      final overwrite = await _confirm(
        title: 'Name in use',
        message: 'A workflow named "$name" already exists. Overwrite it?',
        confirmLabel: 'Overwrite',
      );
      if (!overwrite) return;
    }
    await _writeWorkflow(slug, name);
    if (!mounted) return;
    setState(() {
      _currentWorkflowSlug = slug;
      _currentWorkflowName = name;
    });
  }

  Future<void> _writeWorkflow(String slug, String name) async {
    setState(() => _saving = true);
    // Capture each node's current settings into its params at save time.
    final nodes = [
      for (final n in _nodes) n.copyWith(params: _nodeParams[n.id] ?? n.params),
    ];
    final workflow = Workflow(version: _version, nodes: nodes, edges: _edges);
    String message;
    try {
      await _store.write(slug, name, workflow);
      message =
          'Saved "$name" — ${_nodes.length} node(s), '
          '${_edges.length} edge(s)';
    } catch (e) {
      // WorkflowStore uses dart:io, which is unavailable on web.
      message = 'Save failed: $e';
    }
    await _refreshSavedWorkflows();
    if (!mounted) return;
    setState(() => _saving = false);
    _showMessage(message);
  }

  /// Load a saved workflow onto the canvas, replacing the current graph (with a
  /// confirm when the canvas has unsaved-looking content).
  Future<void> _openWorkflow(WorkflowMeta meta) async {
    if (_nodes.isNotEmpty && _currentWorkflowSlug != meta.slug) {
      final ok = await _confirm(
        title: 'Replace canvas',
        message: 'Load "${meta.name}"? This replaces the current canvas.',
        confirmLabel: 'Load',
      );
      if (!ok) return;
    }
    Workflow? loaded;
    try {
      loaded = await _store.read(meta.slug);
    } catch (e) {
      _showMessage('Could not open "${meta.name}": $e');
      return;
    }
    if (loaded == null) {
      _showMessage('Workflow "${meta.name}" could not be read.');
      return;
    }
    if (!mounted) return;
    final wf = loaded; // promoted non-null for capture in the setState closure
    setState(() {
      _resetCanvasState();
      _nodes.addAll(wf.nodes);
      _edges.addAll(migrateLoadFilePorts(wf.nodes, wf.edges));
      // Restore each node's saved settings so its widget can re-read them.
      for (final n in wf.nodes) {
        if (n.params.isNotEmpty) _nodeParams[n.id] = Map.of(n.params);
      }
      _nextId = _nodes.fold<int>(0, (m, n) => n.id > m ? n.id : m) + 1;
      // New generation → fresh node State → restored params are read in initState.
      _loadGeneration++;
      _currentWorkflowSlug = meta.slug;
      _currentWorkflowName = meta.name;
    });
    // Nodes register their ports as they build this frame; once that's done,
    // rebind the AA edges and force one more build so stream inputs resolve.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final e in _edges) {
        _bindAaPorts(e.from, e.to.nodeId, e.to.idx);
      }
      setState(() {});
    });
    _showMessage('Loaded "${meta.name}"');
  }

  /// Delete a saved workflow, after confirmation.
  ///
  /// The backend owns the delete (`DELETE /workflows/{id}`) so it can refuse while
  /// the workflow is executing. Two of its answers are **not** refusals and fall
  /// back to the local store:
  ///
  ///  * `unreachable` — workflows are local files and the app works without the
  ///    backend, so a dead server must not make them undeletable.
  ///  * `404` — the backend is not holding this file; the user still asked for it
  ///    to go.
  ///
  /// A `409` never falls back: deleting a workflow the server just said is running
  /// is precisely what that status exists to prevent.
  Future<void> _deleteWorkflow(WorkflowMeta meta) async {
    final ok = await _confirm(
      title: 'Delete Workflow',
      message: 'Are you sure you want to delete \'${meta.name}\'? '
          'This action cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;

    var deleted = false;
    try {
      deleted = await _workflowApi.deleteWorkflow(meta.slug);
    } on WorkflowDeleteException catch (e) {
      if (e.reason == WorkflowDeleteFailure.conflict) {
        _showMessage('Cannot delete "${meta.name}": ${e.message}');
        return;
      }
      if (e.reason != WorkflowDeleteFailure.unreachable &&
          e.reason != WorkflowDeleteFailure.notFound) {
        _showMessage('Delete failed: ${e.message}');
        return;
      }
      // Fall through to the local store.
    }

    if (!deleted) {
      try {
        await _store.delete(meta.slug);
      } catch (e) {
        _showMessage('Delete failed: $e');
        return;
      }
    }

    // The open workflow just went: reset the canvas rather than leaving an
    // orphaned graph that Save would recreate under the deleted name.
    if (_currentWorkflowSlug == meta.slug) _clear();

    await _refreshSavedWorkflows();
    _showMessage('Deleted "${meta.name}"');
  }

  /// Modal prompt for a workflow name; returns null if cancelled or left empty.
  Future<String?> _promptWorkflowName({String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            void submit() {
              final value = controller.text.trim();
              if (value.isEmpty) {
                setLocal(() => error = 'Enter a name');
                return;
              }
              Navigator.of(ctx).pop(value);
            }

            return AlertDialog(
              title: const Text('Save workflow as'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Workflow name',
                  errorText: error,
                ),
                onChanged: (_) {
                  if (error != null) setLocal(() => error = null);
                },
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(onPressed: submit, child: const Text('Save')),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    bool destructive = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Tear down all canvas state — nodes, edges, port registries, focus tabs —
  /// WITHOUT wrapping in setState (callers do). Disconnects AA ports first.
  void _resetCanvasState() {
    for (final ports in _aaInputPorts.values) {
      for (final port in ports.values) {
        port.disconnect();
      }
    }
    _nodes.clear();
    _edges.clear();
    _outputs.clear();
    _aaOutputPorts.clear();
    _aaMultiOutputPorts.clear();
    _aaInputPorts.clear();
    _locationOutputs.clear();
    _contentOutputs.clear();
    _sourceNames.clear();
    _nodeParams.clear();
    _focusContent.clear();
    _focusOrder.clear();
    _focusSelected = 0;
    _selectedNodeIds.clear();
    _selectedEdge = null;
  }

  /// Remove all nodes and edges from the canvas, resetting to a fresh unnamed
  /// workflow (the next Save will prompt for a name).
  void _clear() {
    setState(() {
      _resetCanvasState();
      _currentWorkflowSlug = null;
      _currentWorkflowName = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _LogoBanner(),
          _Header(
            onAdd: _addNode,
            onCatalogClosed: () => _canvasFocus.requestFocus(),
            onRun: _nodes.isEmpty ? null : _runWorkflow,
            running: _isRunning,
            onSave: _save,
            onSaveAs: _saveAs,
            saving: _saving,
            onClear: _nodes.isEmpty ? null : _clear,
            savedWorkflows: _savedWorkflows,
            currentWorkflowName: _currentWorkflowName,
            onOpenWorkflow: _openWorkflow,
            onDeleteWorkflow: _deleteWorkflow,
          ),
          if (_selectedNodeIds.isNotEmpty)
            _SelectionBar(
              count: _selectedNodeIds.length,
              onDelete: _deleteSelectedNodes,
              onCopy: _copySelectedNodes,
            ),
          Expanded(
            child: Row(
              children: [
                // Node workspace.
                Expanded(child: _canvas(context)),
                // Draggable splitter: resizes the canvas vs. Focus Panel split.
                // Only meaningful while the panel is open.
                if (_isFocusOpen)
                  _Splitter(
                    onDragDx: (dx) => setState(() {
                      _focusPanelWidth = (_focusPanelWidth - dx).clamp(
                        _minFocusWidth,
                        _maxFocusWidth,
                      );
                    }),
                  ),
                // Focus Panel: the right-margin slideout that renders heavy
                // content, so canvas nodes stay compact routing boxes. Its open
                // width is the user-draggable [_focusPanelWidth].
                FocusPanel(
                  isOpen: _isFocusOpen,
                  onToggle: () => setState(() => _isFocusOpen = !_isFocusOpen),
                  tabs: _focusTabs(),
                  selectedIndex: _focusSelected,
                  onSelectTab: (i) => setState(() => _focusSelected = i),
                  // Clamp so a wide panel can never starve the canvas below a
                  // usable minimum (which would overflow the Row).
                  openWidth: _focusPanelWidth.clamp(
                    _minFocusWidth,
                    (MediaQuery.sizeOf(context).width - 120).clamp(
                      _minFocusWidth,
                      _maxFocusWidth,
                    ),
                  ),
                  // AA edit: re-push the updated content and re-emit on the
                  // originating node's AA output port so downstream nodes
                  // (e.g. a wired AA consumer) see the edited payload.
                  onAaEdited: (nodeId, edited) {
                    final existing = _focusContent[nodeId];
                    _pushFocusContent(
                      nodeId,
                      FocusContent.aa(
                        edited,
                        subtitle: existing?.subtitle,
                      ),
                    );
                    _aaOutputPorts[nodeId]?.emit(edited);
                  },
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
        child: Text(
          'Use the Node Catalog menu to add a node.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
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
                        // Box select. Left-drag on empty canvas was unused —
                        // the view pans on middle-drag and trackpad two-finger
                        // — so the marquee needs no modifier and steals nothing.
                        //
                        // `down` rather than the default `start`: the default
                        // reports where the pan was *recognised*, which places
                        // the anchor corner a slop-distance into the drag and
                        // tests the wrong point for "did this start on a node?".
                        dragStartBehavior: DragStartBehavior.down,
                        onPanStart: _onCanvasPanStart,
                        onPanUpdate: _onCanvasPanUpdate,
                        onPanEnd: _onCanvasPanEnd,
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

                  // Box-select rectangle, above everything and inert to
                  // pointers so it cannot interrupt the drag drawing it.
                  if (_marqueeRect case final rect?)
                    Positioned.fromRect(
                      key: marqueeKey,
                      rect: rect,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.08),
                            border: Border.all(color: scheme.primary, width: 1),
                            borderRadius: BorderRadius.circular(2),
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
      // Shift-click extends the selection (toggle); plain click replaces it.
      // Secondary (right) button shows the node context menu immediately on
      // press — Listener never participates in the gesture arena, so it cannot
      // compete with or delay the TextFields' TapGestureRecognizers inside the
      // node body (unlike the former GestureDetector wrapper).
      onPointerDown: (event) {
        final secondary = event.buttons & kSecondaryMouseButton != 0;
        _pressedNodeId = node.id;
        _draggedSincePress = false;

        // Pressing a node that is already part of a multi-selection must not
        // collapse it: a left-press starts a drag of the whole selection, and a
        // right-press opens a menu whose actions (Group, Delete) mean the
        // selection. Anything else selects immediately, as before.
        final inMultiSelection =
            _selectedNodeIds.length > 1 && _selectedNodeIds.contains(node.id);
        // A right-press never narrows, so nothing is deferred for it.
        _pressDeferredSelect = inMultiSelection && !secondary;
        if (!inMultiSelection) {
          _selectNode(node.id,
              extend: HardwareKeyboard.instance.isShiftPressed);
        }
        if (secondary) {
          _showNodeMenu(event.position, node.id);
        }
      },
      onPointerUp: (event) {
        final wasPress = _pressedNodeId == node.id;
        _pressedNodeId = null;
        // A left *click* (no movement) on a member of a multi-selection narrows
        // to that node — the deferred half of the rule above. A drag leaves the
        // selection alone, and a press that already selected is not redone.
        final deferred = _pressDeferredSelect;
        _pressDeferredSelect = false;
        if (wasPress && deferred && !_draggedSincePress) {
          _selectNode(node.id,
              extend: HardwareKeyboard.instance.isShiftPressed);
        }
      },
      child: Stack(
          // Keyed so a box-select can measure this card's real height.
          key: _nodeKeyFor(node.id),
          clipBehavior: Clip.none,
          children: [
            KeyedSubtree(
              // Load bumps [_loadGeneration], changing the key so the node gets
              // a fresh State that re-reads its restored `initialParams`.
              key: ValueKey('${node.id}#$_loadGeneration'),
              child: _buildNode(node),
            ),

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
                  onPanUpdate: (d) {
                    _draggedSincePress = true;
                    _moveNode(node.id, d.delta);
                  },
                ),
              ),
            ),

            // Selected outline: a 2px accent border only — the node's card fill
            // is left untouched (no background tint, no glow).
            if (_selectedNodeIds.contains(node.id))
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(kNodeRadius),
                      border: Border.all(color: scheme.tertiary, width: 2),
                    ),
                  ),
                ),
              ),
          ],
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
      case NodeGroup.type:
        return GroupNodeWidget(
          node: node,
          // Boundary ports proxy child ports; the canvas tracks their edges the
          // same way it tracks any other node's.
          connectedInputs: {
            for (final e in _edges)
              if (e.to.nodeId == node.id) e.to.idx,
          },
          onInputConnectAt: (source, idx) => _connectAt(source, node.id, idx),
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'start':
        return StartNode(
          node: node,
          // `trigger` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
          // The inline Go also runs the canvas evaluation/report.
          onRun: _runWorkflow,
        );
      case 'load_model':
        return LoadModelNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `trigger` AA input (idx 0) — e.g. from Start.
          triggerConnected: _hasIncomingEdgeAt(node.id, 0),
          onTriggerConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `urlIn` String input (idx 1) — e.g. from URL Source.
          urlConnected: _hasIncomingEdgeAt(node.id, 1),
          onUrlConnect: (source) => _connectAt(source, node.id, 1),
          locationInput: _locationInputForAt(node.id, 1),
          // `model` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'categories':
        return CategoriesNode(
          node: node,
          // `categoriesOut` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'model_classifier':
        return ModelClassifierNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `aaIn` AA input (idx 0) — e.g. from Chunk or Inventory `content`.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onTextConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `modelIn` String input (idx 1) — e.g. from URL Source / Load Model.
          modelConnected: _hasIncomingEdgeAt(node.id, 1),
          onModelConnect: (source) => _connectAt(source, node.id, 1),
          modelInput: _locationInputForAt(node.id, 1),
          // `categoryIn` AA input (idx 2) — e.g. from a Categories node.
          categoryConnected: _hasIncomingEdgeAt(node.id, 2),
          onCategoryConnect: (source) => _connectAt(source, node.id, 2),
          onCategoryPort: (port) => _registerAaInput(node.id, 2, port),
          // `classifiedAaOut` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'load_file':
      case 'file_source': // backward-compat alias
        return LoadFileNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // One output, `aa`, at idx 0. Registered both flat (the headline output
          // the Focus Panel re-emits on) and by index, so an edge drawn from the
          // port resolves the same way multi-output nodes do.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          onAaOutputPort: (port) =>
              (_aaMultiOutputPorts[node.id] ??= {})[0] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'image_display':
        return ImageDisplayNode(
          node: node,
          // `urlInput` — AA location from an upstream node, over the port bus.
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          // The lower-right indicator opens the Focus Panel for this instance.
          onViewImageAssets: _openImageAssets,
          // The three interactive outputs, published for downstream nodes.
          onPromptConnect: (stream) => _promptOutputs[node.id] = stream,
          onBoxSelectConnect: (stream) => _boxSelectOutputs[node.id] = stream,
          onPointClickConnect: (stream) => _pointClickOutputs[node.id] = stream,
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
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `urlInput` — a raw location from an upstream URL Source node.
          locationInput: _locationInputFor(node.id),
          onInputConnect: (source) => _connect(source, node.id),
          // `entry` AA on the port bus; content asset stays a stream.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          onContentConnect: (stream) {
            _contentOutputs[node.id] = stream;
            // Also expose the fetched content as a raw byte stream, so a
            // downstream Preview (which consumes Uint8List) can display it.
            // Stored once (stable identity) so Preview doesn't re-subscribe.
            _outputs[node.id] = stream.map((c) => c.bytes);
          },
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'fetch':
        return FetchNode(
          node: node,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'chunk':
        return ChunkNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'model_builder':
        return ModelBuilderNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
        );
      case 'tokenizer':
        return TokenizerNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'd4m':
        return D4mNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          onPort: (idx, port) => _registerAaInput(node.id, idx, port),
          connectedAt: (idx) => _hasIncomingEdgeAt(node.id, idx),
          onConnect: (source, idx) => _connectAt(source, node.id, idx),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
          onAddLeft: () => _addAdjacentD4mNode(node, isLeft: true),
          onAddRight: () => _addAdjacentD4mNode(node, isLeft: false),
          inMergeSet: _d4mMergeSet.contains(node.id),
          onToggleMerge: () => _toggleD4mMerge(node.id),
          canMerge: _d4mMergeSet.length >= 2,
          onMerge: _d4mMergeSet.length >= 2 ? _mergeD4mNodes : null,
        );
      case 'review':
        return ReviewNode(
          node: node,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      // DEPRECATED — not in the Node Catalog. Kept so a workflow saved before the
      // JSONL consolidation still opens; use `jsonlFormatterNode` for new work.
      case 'aa2jsonl':
        return Aa2JsonlNode(
          node: node,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'preview':
        return PreviewNode(
          node: node,
          // `bytes` input (idx 0) — image/text byte stream.
          input: _inputForAt(node.id, 0),
          fileName: _fileNameFor(node.id),
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onConnect: (source) => _connectAt(source, node.id, 0),
          // `aa` input (idx 1) — an associative array over the port bus.
          aaConnected: _hasIncomingEdgeAt(node.id, 1),
          onAaConnect: (source) => _connectAt(source, node.id, 1),
          onAaInputPort: (port) => _registerAaInput(node.id, 1, port),
          // Route decoded content to the Focus Panel tab for this node, and
          // retract that tab once the node's inputs go dead.
          onContent: _pushFocusContent,
          onContentCleared: _clearFocusContent,
          onView: _openFocusTab,
        );
      case 'promptNode':
      case 'prompt_node': // tolerate a snake_case spelling in saved workflows
        return PromptNodeWidget(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `fileInput` (AA, idx 0) — text/code to merge into the prompt.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onInputConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `promptOutput` (AA, idx 0).
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
          // The expanded editor is this node's Focus Panel tab; "Expand Editor"
          // pushes it and brings the panel forward.
          onContent: _pushFocusContent,
          onView: _openFocusTab,
        );
      case 'remoteServiceNode':
      case 'remote_service': // tolerate a snake_case spelling in saved workflows
        return RemoteServiceNodeWidget(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `dataInput` (AA, idx 0) — the payload to dispatch.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onInputConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `authInput` (AA, idx 1) — profiles from a Secure Settings node.
          authConnected: _hasIncomingEdgeAt(node.id, 1),
          onAuthConnect: (source) => _connectAt(source, node.id, 1),
          onAuthInputPort: (port) => _registerAaInput(node.id, 1, port),
          // `dataOutput` (AA, idx 0) — the result matrix.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'astExtractNode':
      case 'ast_extract': // tolerate a snake_case spelling in saved workflows
        return AstExtractNodeWidget(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `in_aa` (AA, idx 0) — carries the path to parse.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onInputConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `out_aa` (AA, idx 0) — the 7-column definition index.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'jsonlFormatterNode':
      case 'jsonl_formatter': // tolerate a snake_case spelling in saved workflows
        return JsonlFormatterNodeWidget(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `in_aa` (AA, idx 0) — the documented 7-column index.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onInputConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `out_aa` (AA, idx 0) — json_line / symbol_name.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'polyglotExecNode':
      case 'polyglot_exec': // tolerate a snake_case spelling in saved workflows
        return PolyglotExecNodeWidget(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `in_aa` (AA, idx 0) — the code to run.
          inputConnected: _hasIncomingEdgeAt(node.id, 0),
          onInputConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `out_aa` (AA, idx 0) — the 1x8 result matrix.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'secureSettingsNode':
      case 'secure_settings': // tolerate a snake_case spelling in saved workflows
        return SecureSettingsNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `authOutput` (AA, idx 0) — profile metadata only, never the key.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
          // The Key Vault drawer is this node's Focus Panel tab.
          onContent: _pushFocusContent,
          onView: _openFocusTab,
        );
      case 'save_file':
        return SaveFileNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `aaIn` input (idx 0) — associative array over the port bus.
          aaConnected: _hasIncomingEdgeAt(node.id, 0),
          onAaConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `textIn` input (idx 1) — text stream from upstream.
          textConnected: _hasIncomingEdgeAt(node.id, 1),
          onTextConnect: (source) => _connectAt(source, node.id, 1),
          textInput: _locationInputForAt(node.id, 1),
          // `imageIn` input (idx 2) — image bytes stream from upstream.
          imageConnected: _hasIncomingEdgeAt(node.id, 2),
          onImageConnect: (source) => _connectAt(source, node.id, 2),
          imageInput: _inputForAt(node.id, 2),
        );
      case 'text_model_loader':
        return TextModelLoaderNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `trigger` AA input (idx 0) — optional; drives reactive re-load.
          triggerConnected: _hasIncomingEdgeAt(node.id, 0),
          onTriggerConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // `modelHandle` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'text_prompt':
        return TextPromptNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `promptOut` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'text_inference':
        return TextInferenceNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          // `modelHandle` AA input (idx 0) — from TextModelLoaderNode.
          modelHandleConnected: _hasIncomingEdgeAt(node.id, 0),
          onModelHandleConnect: (source) => _connectAt(source, node.id, 0),
          onModelHandlePort: (port) => _registerAaInput(node.id, 0, port),
          // `promptIn` AA input (idx 1) — from TextPromptNode.
          promptConnected: _hasIncomingEdgeAt(node.id, 1),
          onPromptConnect: (source) => _connectAt(source, node.id, 1),
          onPromptPort: (port) => _registerAaInput(node.id, 1, port),
          // `resultOut` AA egress on the port bus.
          onOutputPort: (port) => _aaOutputPorts[node.id] = port,
          connectedOutputs: _connectedOutputs(node.id),
        );
      case 'text_preview':
        return TextPreviewNode(
          node: node,
          // `resultIn` AA input (idx 0) — from TextInferenceNode.
          resultConnected: _hasIncomingEdgeAt(node.id, 0),
          onConnect: (source) => _connectAt(source, node.id, 0),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          // Route decoded text content to the Focus Panel tab.
          onContent: _pushFocusContent,
          onView: _openFocusTab,
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
          onPreviewImage: (bytes, name) => _pushFocusContent(
            node.id,
            FocusContent.image(
              bytes: bytes,
              subtitle: [
                if (name != null && name.isNotEmpty) name,
                _humanSize(bytes.length),
              ].join(' · '),
            ),
          ),
        );
      case 'split':
        return SplitNode(
          node: node,
          initialParams: _nodeParams[node.id],
          onParams: (p) => _nodeParams[node.id] = p,
          inputConnected: _hasIncomingEdge(node.id),
          onInputPort: (port) => _registerAaInput(node.id, 0, port),
          onInputConnect: (source) => _connect(source, node.id),
          // Two output ports — stored in _aaMultiOutputPorts so _bindAaPorts
          // can select the right one by PortRef.idx.
          onTrainOutputPort: (port) =>
              (_aaMultiOutputPorts[node.id] ??= {})[0] = port,
          onValOutputPort: (port) =>
              (_aaMultiOutputPorts[node.id] ??= {})[1] = port,
          connectedOutputs: _connectedOutputs(node.id),
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
      // the wrapper uses to position the ports (lane top + idx * spacing), with
      // the source's true width so wide nodes (Inventory/Review) anchor right.
      final start = Offset(
        from.x + _nodeWidthFor(from.type),
        from.y + kPortLaneTop + e.from.idx * kPortSpacing,
      );
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
        end,
        3,
        Paint()..color = isSelected ? selectColor : color,
      );
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
  }) : phase = repaint,
       super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final src = source;
    final end = endpoint;
    if (src == null || end == null) return;
    final from = byId[src.nodeId];
    if (from == null) return;

    final start = Offset(
      from.x + _nodeWidthFor(from.type),
      from.y + kPortLaneTop + src.idx * kPortSpacing,
    );
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

/// A thin bar that appears below the main header when one or more nodes are
/// selected. Shows the count and offers Copy/Delete batch actions without
/// competing for space with the always-visible header buttons.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

  const _SelectionBar({
    required this.count,
    required this.onDelete,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const deleteColor = Color(0xFFE5534B);
    const copyColor = Color(0xFF5B8DEF);

    ButtonStyle compact(Color c) => OutlinedButton.styleFrom(
          foregroundColor: c,
          iconColor: c,
          side: BorderSide(color: c, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.check_box_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            '$count node${count == 1 ? '' : 's'} selected',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onCopy,
            style: compact(copyColor),
            icon: const Icon(Icons.copy_outlined, size: 16),
            label: const Text('Copy'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: onDelete,
            style: compact(deleteColor),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Delete'),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// The thin top header: the **Node Catalog** dropdown (node primitives to add),
/// the **Workflows** dropdown (saved graphs to open / delete / Save As), the
/// primary "Go" run trigger, and Save / Clear.
class _LogoBanner extends StatelessWidget {
  const _LogoBanner();

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Image.asset(
            'assets/png/GreatSealofDN.png',
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const white = Colors.white;
    final aboutStyle = OutlinedButton.styleFrom(
      foregroundColor: white,
      iconColor: white,
      side: const BorderSide(color: white, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Image.asset(
            'assets/png/logo-title-wb-crop.png',
            height: 36,
            fit: BoxFit.contain,
          ),
          const Spacer(),
          OutlinedButton(
            style: aboutStyle,
            onPressed: () => _showAbout(context),
            child: const Text('About'),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final ValueChanged<NodeType> onAdd;

  /// Evaluate the graph on the canvas; null disables it (nothing to run).
  final VoidCallback? onRun;

  /// True while a run is in flight — shows the active state and blocks reclicks.
  final bool running;

  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final bool saving;

  /// Clear the workflow; null disables the button (nothing to clear).
  final VoidCallback? onClear;

  /// Called after the Node Catalog closes, selection or not — the page uses it to
  /// pull keyboard focus back to the canvas.
  final VoidCallback? onCatalogClosed;

  /// Saved workflows for the Workflows dropdown, and the active one's name.
  final List<WorkflowMeta> savedWorkflows;
  final String? currentWorkflowName;
  final ValueChanged<WorkflowMeta> onOpenWorkflow;
  final ValueChanged<WorkflowMeta> onDeleteWorkflow;

  const _Header({
    required this.onAdd,
    required this.onSave,
    required this.onSaveAs,
    required this.saving,
    required this.savedWorkflows,
    required this.onOpenWorkflow,
    required this.onDeleteWorkflow,
    this.currentWorkflowName,
    this.onRun,
    this.running = false,
    this.onClear,
    this.onCatalogClosed,
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
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          // Node Catalog — the searchable palette of node primitives. A panel
          // rather than a menu: it carries a search field and filter chips, and a
          // menu route would close on the first tap inside it.
          InkWell(
            onTap: () async {
              final chosen = await showNodeCatalog(context);
              if (chosen != null) onAdd(chosen);
              // Hand focus back to the canvas either way, so Delete and Cmd-G
              // keep working after the palette closes.
              onCatalogClosed?.call();
            },
            child: Tooltip(
              message: 'Add a node from the catalog',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.widgets_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text('Node Catalog', style: theme.textTheme.titleSmall),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Workflows — saved graphs to open, delete, or Save As.
          _buildWorkflowsMenu(theme),
          const Spacer(),
          // Primary execution trigger — first in the action bar, before Save.
          OutlinedButton.icon(
            onPressed: running ? null : onRun,
            style: _outlined(_runColor),
            icon: running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
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
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
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

  /// The Workflows dropdown: saved graphs to open (with an inline delete), plus
  /// a "Save As…" entry. The button label reflects the active workflow name.
  Widget _buildWorkflowsMenu(ThemeData theme) {
    final scheme = theme.colorScheme;
    return PopupMenuButton<_WfMenu>(
      tooltip: 'Open a saved workflow',
      onSelected: (v) {
        switch (v) {
          case _WfOpen(:final meta):
            onOpenWorkflow(meta);
          case _WfSaveAs():
            onSaveAs();
        }
      },
      itemBuilder: (context) => [
        if (savedWorkflows.isEmpty)
          const PopupMenuItem<_WfMenu>(
            enabled: false,
            child: Text('No saved workflows'),
          ),
        for (final w in savedWorkflows)
          PopupMenuItem<_WfMenu>(
            value: _WfOpen(w),
            child: Row(
              children: [
                if (w.name == currentWorkflowName)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.check, size: 16),
                  ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${w.nodeCount} node(s) · ${w.edgeCount} edge(s)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  // Close the menu first, then delete, so the item's own select
                  // (open) never races the delete.
                  onPressed: () {
                    Navigator.of(context).pop();
                    onDeleteWorkflow(w);
                  },
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<_WfMenu>(
          value: _WfSaveAs(),
          child: Row(
            children: [
              Icon(Icons.save_as_outlined, size: 18),
              SizedBox(width: 8),
              Text('Save As…'),
            ],
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open_outlined, size: 18),
          const SizedBox(width: 6),
          Text(
            currentWorkflowName ?? 'Workflows',
            style: theme.textTheme.titleSmall,
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// Menu actions for the Workflows dropdown.
sealed class _WfMenu {
  const _WfMenu();
}

class _WfOpen extends _WfMenu {
  final WorkflowMeta meta;
  const _WfOpen(this.meta);
}

class _WfSaveAs extends _WfMenu {
  const _WfSaveAs();
}

/// A draggable vertical bar that resizes the canvas / Focus Panel split.
/// Reports the horizontal drag delta; the page turns it into a panel-width
/// change (drag left → panel grows).
class _Splitter extends StatelessWidget {
  final ValueChanged<double> onDragDx;

  const _Splitter({required this.onDragDx});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDragDx(d.delta.dx),
        child: Container(
          width: 8,
          color: scheme.surfaceContainerHigh,
          child: Center(
            child: Container(
              width: 2,
              height: 28,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
