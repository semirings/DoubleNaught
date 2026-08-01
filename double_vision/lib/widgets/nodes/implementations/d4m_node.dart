import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/d4m_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Vertical space reserved so the four edge-anchored input labels (A at idx 0,
/// B at idx 1, C at idx 2, D at idx 3) clear the body controls.
/// Clearance = 4 + max_port_idx × 24 = 4 + 3 × 24 = 76 px.
const double _kPortLaneInset = 76;

/// Slot names assigned to each of D4MNode's four input ports.
const List<String> _kSlotNames = ['A', 'B', 'C', 'D'];

/// Lifecycle of a D4M evaluation operation.
enum _D4mStatus { idle, evaluating, complete, error }

/// A **functional node** (AA-in → AA-out) that evaluates a user-supplied
/// D4M expression over up to four named input AAs.
///
/// Inputs (all AA, idx 0–3):
///  * `A` (idx 0), `B` (idx 1), `C` (idx 2), `D` (idx 3) — each accepts any
///    upstream AA.  Connected slots whose AA has arrived are available by their
///    single-letter name in the expression.
///
/// Configuration:
///  * **D4M Expression** — a multi-line monospaced text field.  Valid examples:
///    `A + B`, `A("chunk: ", "score: ")`, `(A + B) >= 0.75`, `A & B`.
///
/// Output (AA, idx 0):
///  * `aaOut` — the result of the expression, emitted on the port bus.
///
/// Execution fires automatically (debounced 400 ms) whenever a new AA arrives
/// on any input and the expression is non-empty.  The Evaluate button re-fires
/// manually without debounce.
class D4mNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  // Input port connection flags and callbacks — one per slot A..D.
  final bool aConnected;
  final void Function(PortRef source)? onAConnect;
  final void Function(InputPort port)? onAPort;

  final bool bConnected;
  final void Function(PortRef source)? onBConnect;
  final void Function(InputPort port)? onBPort;

  final bool cConnected;
  final void Function(PortRef source)? onCConnect;
  final void Function(InputPort port)? onCPort;

  final bool dConnected;
  final void Function(PortRef source)? onDConnect;
  final void Function(InputPort port)? onDPort;

  // Output port.
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final D4mApi api;

  /// Saved settings (expression text) and persistence callback.
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  const D4mNode({
    super.key,
    required this.node,
    this.aConnected = false,
    this.onAConnect,
    this.onAPort,
    this.bConnected = false,
    this.onBConnect,
    this.onBPort,
    this.cConnected = false,
    this.onCConnect,
    this.onCPort,
    this.dConnected = false,
    this.onDConnect,
    this.onDPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.api = const D4mApi(),
    this.initialParams,
    this.onParams,
  });

  @override
  State<D4mNode> createState() => _D4mNodeState();
}

class _D4mNodeState extends State<D4mNode> {
  // --- Input ports (one per slot) ---
  final InputPort _portA = InputPort('A');
  final InputPort _portB = InputPort('B');
  final InputPort _portC = InputPort('C');
  final InputPort _portD = InputPort('D');

  // --- Incoming AAs (null until data arrives on the port) ---
  AaPayload? _aaA;
  AaPayload? _aaB;
  AaPayload? _aaC;
  AaPayload? _aaD;

  // --- Output ---
  final OutputPort _out = OutputPort('aaOut');
  AaPayload? _lastOutput;

  // --- UI ---
  late final TextEditingController _expr;
  _D4mStatus _status = _D4mStatus.idle;
  String? _error;

  // --- Auto-execution debounce ---
  Timer? _autoTimer;
  String? _lastRunSig;

  bool get _hasAnyInput =>
      _aaA != null || _aaB != null || _aaC != null || _aaD != null;

  bool get _canEval =>
      _hasAnyInput &&
      _expr.text.trim().isNotEmpty &&
      _status != _D4mStatus.evaluating;

  /// Stable content hash for an [AaPayload] — independent of object identity.
  /// Uses length + boundary values so the hash changes whenever the data does,
  /// without hashing every element.
  static int _aaHash(AaPayload aa) => Object.hash(
        aa.rows.length,
        aa.cols.length,
        aa.vals.length,
        aa.rows.isEmpty ? null : aa.rows.first,
        aa.rows.isEmpty ? null : aa.rows.last,
        aa.cols.isEmpty ? null : aa.cols.first,
        aa.vals.isEmpty ? null : aa.vals.first,
      );

  /// Build a run signature for dedup: prevents re-evaluation when input data
  /// has not changed since the last successful run.
  String? _runSig() {
    final e = _expr.text.trim();
    if (!_hasAnyInput || e.isEmpty) return null;
    final parts = <String>[];
    if (_aaA != null) parts.add('A:${_aaHash(_aaA!)}');
    if (_aaB != null) parts.add('B:${_aaHash(_aaB!)}');
    if (_aaC != null) parts.add('C:${_aaHash(_aaC!)}');
    if (_aaD != null) parts.add('D:${_aaHash(_aaD!)}');
    return '${parts.join('|')}|expr:${e.hashCode}';
  }

  @override
  void initState() {
    super.initState();
    _expr = TextEditingController(
      text: widget.initialParams?['expression'] ?? '',
    );
    widget.onAPort?.call(_portA);
    widget.onBPort?.call(_portB);
    widget.onCPort?.call(_portC);
    widget.onDPort?.call(_portD);
    widget.onOutputPort?.call(_out);
    _portA.onDataArrived.listen((p) => _onIncoming('A', p));
    _portB.onDataArrived.listen((p) => _onIncoming('B', p));
    _portC.onDataArrived.listen((p) => _onIncoming('C', p));
    _portD.onDataArrived.listen((p) => _onIncoming('D', p));
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _portA.dispose();
    _portB.dispose();
    _portC.dispose();
    _portD.dispose();
    _out.dispose();
    _expr.dispose();
    super.dispose();
  }

  void _onIncoming(String slot, AaPayload payload) {
    if (!mounted) return;
    // Identical-reference guard: OutputPort replays _lastPayload to late
    // subscribers and on parent rebuilds. If we already hold this exact object,
    // the data hasn't changed — skip setState and don't restart the timer.
    final current = switch (slot) {
      'A' => _aaA, 'B' => _aaB, 'C' => _aaC, 'D' => _aaD, _ => null,
    };
    if (identical(current, payload)) return;
    setState(() {
      switch (slot) {
        case 'A': _aaA = payload;
        case 'B': _aaB = payload;
        case 'C': _aaC = payload;
        case 'D': _aaD = payload;
      }
    });
    _maybeAutoEval();
  }

  void _maybeAutoEval() {
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || !_canEval) return;
      final sig = _runSig();
      if (sig == null || sig == _lastRunSig) return;
      _evaluate();
    });
  }

  Future<void> _evaluate() async {
    if (!_canEval) return;
    final expression = _expr.text.trim();
    // Collect only the slots that have data.
    final inputs = <String, AaPayload>{
      if (_aaA != null) 'A': _aaA!,
      if (_aaB != null) 'B': _aaB!,
      if (_aaC != null) 'C': _aaC!,
      if (_aaD != null) 'D': _aaD!,
    };
    setState(() {
      _status = _D4mStatus.evaluating;
      _error = null;
    });
    try {
      final result = await widget.api.eval(
        inputs: inputs,
        expression: expression,
      );
      if (!mounted) return;
      _lastOutput = result;
      _lastRunSig = _runSig();
      _out.emit(result);
      setState(() => _status = _D4mStatus.complete);
      widget.onParams?.call({'expression': expression});
    } catch (e) {
      if (!mounted) return;
      // Extract the backend detail message from HTTP 422 responses.
      final msg = '$e';
      final friendly = msg.contains(': ') ? msg.split(': ').skip(1).join(': ') : msg;
      setState(() {
        _status = _D4mStatus.error;
        _error = friendly;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasOutput = _lastOutput != null;

    return DoubleNaughtNodeWrapper(
      title: 'D4M',
      icon: Icons.functions,
      width: D4mNode._width,
      inputPorts: [
        for (var i = 0; i < _kSlotNames.length; i++)
          InputConnector(
            label: _kSlotNames[i],
            idx: i,
            active: _slotConnected(i),
            onConnect: _slotOnConnect(i),
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
          // Clear the deepest port label (D at idx 3, slot bottom Y=122;
          // body start Y=46; clearance = 76 px).
          const SizedBox(height: _kPortLaneInset),
          _inputsList(theme),
          const SizedBox(height: 12),
          TextField(
            controller: _expr,
            enabled: _status != _D4mStatus.evaluating,
            minLines: 3,
            maxLines: 6,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
            decoration: const InputDecoration(
              labelText: 'D4M Expression',
              hintText: "A + B\nA[startswith('chunk:'), ':']",
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canEval ? _evaluate : null,
              icon: _status == _D4mStatus.evaluating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Evaluate'),
            ),
          ),
          const SizedBox(height: 8),
          _statusIndicator(theme),
        ],
      ),
    );
  }

  bool _slotConnected(int idx) => switch (idx) {
    0 => widget.aConnected,
    1 => widget.bConnected,
    2 => widget.cConnected,
    3 => widget.dConnected,
    _ => false,
  };

  void Function(PortRef)? _slotOnConnect(int idx) => switch (idx) {
    0 => widget.onAConnect,
    1 => widget.onBConnect,
    2 => widget.onCConnect,
    3 => widget.onDConnect,
    _ => null,
  };

  /// A read-only list of the slot names that are connected and have data.
  Widget _inputsList(ThemeData theme) {
    final connected = [
      if (widget.aConnected) 'A',
      if (widget.bConnected) 'B',
      if (widget.cConnected) 'C',
      if (widget.dConnected) 'D',
    ];
    if (connected.isEmpty) {
      return Text(
        'No inputs connected.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connected inputs',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        for (final name in connected)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 6, top: 1),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _slotHasData(name)
                        ? Colors.green
                        : theme.colorScheme.outline,
                  ),
                ),
                Text(
                  name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  bool _slotHasData(String name) => switch (name) {
    'A' => _aaA != null,
    'B' => _aaB != null,
    'C' => _aaC != null,
    'D' => _aaD != null,
    _ => false,
  };

  Widget _statusIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      _D4mStatus.idle => (scheme.outline, 'idle'),
      _D4mStatus.evaluating => (scheme.primary, 'evaluating'),
      _D4mStatus.complete => (Colors.green, 'complete'),
      _D4mStatus.error => (scheme.error, 'error'),
    };
    final detail =
        (_status == _D4mStatus.error && _error != null) ? ' · $_error' : '';

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
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
