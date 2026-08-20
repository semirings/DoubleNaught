import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import 'base_node.dart'
    show
        kNodeWidth,
        kPortLaneTop,
        kPortSpacing,
        kTitleBarHeight,
        kPortDotRadius,
        kStatusIdleColor,
        kStatusRunningColor,
        kStatusSuccessColor,
        kStatusErrorColor;
import 'double_naught_node_wrapper.dart';
import 'input_connector.dart';
import 'output_connector.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NodeStatus
// ─────────────────────────────────────────────────────────────────────────────

/// Four-value execution lifecycle shared by every node that does async work.
///
/// The label shown while [working] is supplied per-node via
/// [BaseNodeState.workingLabel] so each node keeps its domain verb
/// ('chunking', 'executing', 'fetching', …) without repeating the
/// color-mapping and dot-row widget across every implementation.
enum NodeStatus { idle, working, complete, error }

// ─────────────────────────────────────────────────────────────────────────────
// BaseNodeWidget
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract base for every workflow-canvas node widget.
///
/// Carries the constructor props that every node shares so concrete widgets
/// only declare what is genuinely unique to them.  The matching
/// [BaseNodeState] supplies the behavioural helpers (status management,
/// port helpers, error cleaning, params persistence, chrome assembly).
///
/// ## Extending
///
/// ```dart
/// class MyNode extends BaseNodeWidget {
///   final MyApi api;
///
///   const MyNode({
///     super.key,
///     required super.node,
///     super.initialParams,
///     super.onParams,
///     super.onInputPort,
///     super.onOutputPort,
///     super.connectedOutputs,
///     super.inputConnected,
///     super.onInputConnect,
///     this.api = const MyApi(),
///   });
///
///   @override
///   State<MyNode> createState() => _MyNodeState();
/// }
/// ```
///
/// Nodes with additional input ports (e.g. a second `onCategoryPort`
/// callback) or named per-port output callbacks add those as extra
/// constructor params alongside the base ones.
abstract class BaseNodeWidget extends StatefulWidget {
  /// Required by every node — carried to build [PortRef] values.
  final WorkflowNode node;

  /// Persisted configuration map restored across sessions.
  /// Null for nodes that have no persistent configuration.
  final Map<String, String>? initialParams;

  /// Called whenever the node wants to save its current configuration.
  final void Function(Map<String, String>)? onParams;

  /// Canonical single input-port registration callback.
  ///
  /// The canvas calls this to receive the node's [InputPort] so it can wire
  /// upstream connections.  Nodes with more than one input port (or with
  /// non-standard port naming) declare additional port callbacks in their
  /// own constructors.
  final void Function(InputPort)? onInputPort;

  /// Canonical single output-port registration callback.
  ///
  /// Nodes that expose multiple output ports, or that use named per-port
  /// callbacks (e.g. [SplitNode]'s onTrainOutputPort), declare those in
  /// their own constructors and may leave this null.
  final void Function(OutputPort)? onOutputPort;

  /// Which output-port indices currently have a live downstream connection.
  ///
  /// Passed to [OutputConnector.active] so the dot stays lit even before
  /// the first payload has been emitted.
  final Set<int> connectedOutputs;

  /// Whether the canonical single input port is currently wired.
  ///
  /// Passed to [InputConnector.active] by [BaseNodeState.singleInputConnector].
  /// Nodes with multiple input ports track additional connected-booleans in
  /// their own constructors.
  final bool inputConnected;

  /// Called by [InputConnector] when the canvas completes a connection drag
  /// onto this node's canonical input port.
  final void Function(PortRef)? onInputConnect;

  const BaseNodeWidget({
    super.key,
    required this.node,
    this.initialParams,
    this.onParams,
    this.onInputPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.inputConnected = false,
    this.onInputConnect,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// BaseNodeState
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract state for [BaseNodeWidget] subclasses.
///
/// Subclasses must override [nodeTitle], [nodeIcon], and [buildNodeBody].
/// Every other member is either optional (with a sensible default) or a
/// protected helper that subclasses call rather than re-implement.
///
/// ## Lifecycle contract
///
/// 1. In `initState`, call [initInputPort] / [initOutputPort] for each port.
/// 2. Own the port fields as state fields.
/// 3. Dispose ports in the subclass `dispose()` override before `super.dispose()`.
/// 4. Do **not** override `build()` — express all UI via the three `build*`
///    methods and call [statusRow] from inside [buildNodeBody].
///
/// ## Minimal concrete example
///
/// ```dart
/// class _MyNodeState extends BaseNodeState<MyNode> {
///   final _in  = InputPort('aa');
///   final _out = OutputPort('result');
///
///   @override String   get nodeTitle   => 'myNode';
///   @override IconData get nodeIcon    => Icons.hub_outlined;
///   @override String   get workingLabel => 'processing';
///
///   @override
///   void initState() {
///     super.initState();
///     initInputPort(_in, _onData);
///     initOutputPort(_out);
///   }
///
///   @override
///   void dispose() {
///     _in.dispose();
///     _out.dispose();
///     super.dispose();
///   }
///
///   void _onData(AaPayload p) async {
///     setWorking();
///     try {
///       final result = await widget.api.process(p);
///       _out.emit(result.aa);
///       setComplete(detail: '${result.count} rows');
///     } catch (e) {
///       setError(e);
///     }
///   }
///
///   @override
///   List<Widget> buildInputConnectors(BuildContext context) => [
///     singleInputConnector(label: 'aa'),
///   ];
///
///   @override
///   List<Widget> buildOutputConnectors(BuildContext context) => [
///     singleOutputConnector(label: 'result', idx: 0,
///         hasData: status == NodeStatus.complete),
///   ];
///
///   @override
///   Widget buildNodeBody(BuildContext context) => Column(
///     mainAxisSize: MainAxisSize.min,
///     crossAxisAlignment: CrossAxisAlignment.start,
///     children: [
///       SizedBox(height: portLaneClearance(1)),
///       ElevatedButton(onPressed: ..., child: const Text('Run')),
///       const SizedBox(height: 8),
///       statusRow(),
///     ],
///   );
/// }
/// ```
abstract class BaseNodeState<T extends BaseNodeWidget> extends State<T> {
  // ── Required overrides ──────────────────────────────────────────────────

  /// camelCase title shown in the node header (e.g. `'chunkNode'`).
  String get nodeTitle;

  /// Icon shown beside [nodeTitle].
  IconData get nodeIcon;

  /// The node-specific interior content rendered inside the card body.
  ///
  /// Call [statusRow] anywhere in the returned widget tree to place the
  /// execution-state dot+label row.  Nodes that never show status simply
  /// omit the call.
  Widget buildNodeBody(BuildContext context);

  // ── Optional overrides ──────────────────────────────────────────────────

  /// Verb shown in the status row while [NodeStatus.working].
  ///
  /// Default: `'running'` — the fixed generic label from
  /// `UX_UI/GLOBAL_UX_CONTRACT.md` §5 for a node with no more specific verb
  /// of its own.  Override with a domain verb where one reads better:
  /// `'chunking'`, `'fetching'`, `'tokenizing'`, etc.
  String get workingLabel => 'running';

  /// Card width.  Default: [kNodeWidth] (240).
  ///
  /// Override to return a wider value for nodes that need more space.
  double get nodeWidth => kNodeWidth;

  /// Left-edge [InputConnector] widgets rendered by [DoubleNaughtNodeWrapper].
  ///
  /// Default: empty (source-only nodes).  Override and return the desired
  /// connectors.  Use [singleInputConnector] for the canonical single-port case.
  List<Widget> buildInputConnectors(BuildContext context) => const [];

  /// Right-edge [OutputConnector] widgets rendered by [DoubleNaughtNodeWrapper].
  ///
  /// Default: empty (sink-only nodes).  Use [singleOutputConnector] for the
  /// canonical single-port case.
  List<Widget> buildOutputConnectors(BuildContext context) => const [];

  // ── Status management ───────────────────────────────────────────────────

  NodeStatus _status = NodeStatus.idle;
  String? _statusDetail;

  /// The current execution state.  Read-only; mutate via the `set*` methods.
  NodeStatus get status => _status;

  /// Set the node to idle and clear any status detail.
  void setIdle() {
    if (!mounted) return;
    setState(() {
      _status = NodeStatus.idle;
      _statusDetail = null;
    });
  }

  /// Set the node to the working state and clear any prior detail.
  void setWorking() {
    if (!mounted) return;
    setState(() {
      _status = NodeStatus.working;
      _statusDetail = null;
    });
  }

  /// Set the node to complete.  Pass [detail] to append extra info after
  /// the label (e.g. `'42 rows'`).
  void setComplete({String? detail}) {
    if (!mounted) return;
    setState(() {
      _status = NodeStatus.complete;
      _statusDetail = detail;
    });
  }

  /// Set the node to error, cleaning the exception message via [cleanError].
  void setError(Object e) {
    if (!mounted) return;
    setState(() {
      _status = NodeStatus.error;
      _statusDetail = cleanError(e);
    });
  }

  /// Pre-built status dot + label row.
  ///
  /// Renders the current [_status] with the canonical dimensions:
  /// 8×8 dot, `margin: EdgeInsets.only(top: 4)`, `SizedBox(width: 8)`. Colors
  /// are the fixed literal palette from `UX_UI/GLOBAL_UX_CONTRACT.md` §5, not
  /// theme-derived — identical across every node.
  ///
  ///   idle     → grey dot    `'idle'`
  ///   working  → violet dot  [workingLabel] (domain verb, e.g. `'parsing'`)
  ///   complete → green dot   `'done'` [` · detail`]
  ///   error    → red dot     `'error'` [` · detail`]
  ///
  /// Call this inside [buildNodeBody] wherever the status row belongs.
  /// Nodes that have no execution state simply do not call it.
  Widget statusRow() {
    final theme = Theme.of(context);

    final (color, label) = switch (_status) {
      NodeStatus.idle => (kStatusIdleColor, 'idle'),
      NodeStatus.working => (kStatusRunningColor, workingLabel),
      NodeStatus.complete => (kStatusSuccessColor, 'done'),
      NodeStatus.error => (kStatusErrorColor, 'error'),
    };

    final detail = _statusDetail;
    final text = detail != null ? '$label · $detail' : label;

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
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  // ── Params ──────────────────────────────────────────────────────────────

  /// Write the node's current configuration back to the canvas store.
  void saveParams(Map<String, String> params) =>
      widget.onParams?.call(params);

  // ── Port lifecycle helpers ───────────────────────────────────────────────

  /// Register [port] with the canvas and attach [onData] as the arrival
  /// listener.
  ///
  /// Call once per input port in `initState`.  The port field is owned by
  /// the subclass; dispose it in the subclass `dispose()` — [InputPort.dispose]
  /// also cancels the stream subscription.
  void initInputPort(InputPort port, void Function(AaPayload) onData) {
    debugPrint('[PORT-DEBUG] initInputPort registered');
    widget.onInputPort?.call(port);
    port.onDataArrived.listen((payload) {
      debugPrint('[PORT-DEBUG] InputPort received data: ${payload.cols}');
      onData(payload);
    });
  }

  /// Register [port] with the canvas.
  ///
  /// Call once per output port in `initState`.  For nodes with multiple output
  /// ports, or with non-standard port callbacks, call the relevant callback
  /// directly; this helper covers the canonical single-output case only.
  void initOutputPort(OutputPort port) =>
      widget.onOutputPort?.call(port);

  // ── Error handling ───────────────────────────────────────────────────────

  /// Strip the leading exception class prefix from `e.toString()`.
  ///
  /// `'FormatException: bad value'` → `'bad value'`
  ///
  /// If there is no `': '` separator the full string is returned unchanged.
  String cleanError(Object e) {
    final msg = '$e';
    return msg.contains(': ') ? msg.split(': ').skip(1).join(': ') : msg;
  }

  // ── Connector convenience builders ───────────────────────────────────────

  /// Build the canonical single [InputConnector] using the base widget's
  /// [BaseNodeWidget.inputConnected] / [BaseNodeWidget.onInputConnect] props.
  ///
  /// For nodes with multiple input ports, build additional [InputConnector]
  /// widgets directly using the extra props declared in the concrete widget.
  Widget singleInputConnector({required String label}) => InputConnector(
        label: label,
        active: widget.inputConnected,
        onConnect: widget.onInputConnect,
      );

  /// Build an [OutputConnector] for output port [idx].
  ///
  /// [hasData] should be true when the node has a result ready to flow
  /// downstream (e.g. `status == NodeStatus.complete` or `_result != null`).
  /// `active` is the logical OR of [hasData] and the canvas knowing a
  /// downstream wire is present.
  Widget singleOutputConnector({
    required String label,
    required int idx,
    bool hasData = false,
  }) =>
      OutputConnector(
        label: label,
        idx: idx,
        active: hasData || widget.connectedOutputs.contains(idx),
        dragData: PortRef(nodeId: widget.node.id, idx: idx),
      );

  // ── Utility ─────────────────────────────────────────────────────────────

  /// A 16×16 [CircularProgressIndicator] for use as a button icon while
  /// the node is busy.
  Widget busyIcon() => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );

  /// Minimum top padding height (in logical pixels) for the node body
  /// [Column] when [portCount] stacked left-edge input ports would otherwise
  /// overlap the body content.
  ///
  /// Place `SizedBox(height: portLaneClearance(n))` as the first child in
  /// the [buildNodeBody] column whenever [portCount] ≥ 1.
  ///
  /// Values produced: n=1 → 28, n=2 → 52, n=3 → 76 (matches all existing
  /// per-node `_kPortLaneInset` constants).
  static double portLaneClearance(int portCount) =>
      kPortLaneTop +
      (portCount - 1) * kPortSpacing -
      kTitleBarHeight +
      kPortDotRadius +
      15;

  // ── build — do not override in subclasses ────────────────────────────────

  /// Assembles [DoubleNaughtNodeWrapper] from the node's declared parts.
  ///
  /// Do not override this method.  Express all UI customisation through
  /// [buildNodeBody], [buildInputConnectors], and [buildOutputConnectors].
  @override
  Widget build(BuildContext context) => DoubleNaughtNodeWrapper(
        title: nodeTitle,
        icon: nodeIcon,
        width: nodeWidth,
        // Every node's border follows its own status automatically — see
        // `UX_UI/GLOBAL_UX_CONTRACT.md` §1. Subclasses never set this
        // themselves; it falls out of the same NodeStatus that drives
        // [statusRow].
        borderState: switch (_status) {
          NodeStatus.working => CardBorderState.executing,
          NodeStatus.error => CardBorderState.error,
          NodeStatus.idle || NodeStatus.complete => CardBorderState.normal,
        },
        inputPorts: buildInputConnectors(context),
        outputPorts: buildOutputConnectors(context),
        child: buildNodeBody(context),
      );
}
