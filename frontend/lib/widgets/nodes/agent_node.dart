import 'dart:async';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../models/aa_status.dart';
import '../../services/infobus/input_port.dart';
import '../../services/infobus/output_port.dart';

class AgentNode {
  // 1. Ingress Ports
  final triggerPort = InputPort('trigger', isRequired: true);
  final taskPort = InputPort('taskIn', isRequired: true);
  final contextPort = InputPort('contextIn', isRequired: false);

  // 2. Egress Ports
  final resultPort = OutputPort('resultOut');
  final statusPort = OutputPort('statusOut');

  final List<StreamSubscription<AaPayload>> _subs = [];

  /// Re-entrancy guard — never runs two executions concurrently.
  bool _isExecuting = false;

  /// Set when a trigger arrives; cleared once an execution consumes it. Lets a
  /// task that arrives *after* the trigger still fire the run (late-data case).
  bool _triggerPending = false;

  AgentNode() {
    _subs.add(triggerPort.onDataArrived.listen((_) {
      _triggerPending = true;
      _tryExecute();
    }));
    // A task landing after the trigger should also (re)attempt execution.
    _subs.add(taskPort.onDataArrived.listen((_) => _tryExecute()));
  }

  Future<void> _tryExecute() async {
    // Busy + armed + data guards.
    if (_isExecuting || !_triggerPending || !taskPort.hasData) return;

    final task = taskPort.pop();
    // Schema guardrail: only run on a valid, non-empty AA.
    if (task == null || task.cols.isEmpty) return;

    // Commit: consume the trigger and optional context.
    triggerPort.pop();
    _triggerPending = false;
    final context = contextPort.hasData ? contextPort.pop() : null;

    _isExecuting = true;
    statusPort.emit(aaStatusPayload('thinking'));
    try {
      final result = await callMlxBackend(task, context);
      resultPort.emit(result);
      statusPort.emit(aaStatusPayload('idle'));
    } catch (_) {
      statusPort.emit(aaStatusPayload('error'));
    } finally {
      _isExecuting = false;
      // Drain: if another trigger + task queued up while we were busy, run again.
      if (_triggerPending && taskPort.hasData) scheduleMicrotask(_tryExecute);
    }
  }

  /// Placeholder for the Python MLX engine call. Not yet wired to the backend
  /// (double_touch); returns a stub payload so the primitive compiles and runs
  /// end-to-end. Replace with the real call during integration.
  // TODO: dispatch to the MLX/double_touch backend and return its AA result.
  Future<AaPayload> callMlxBackend(AaPayload task, AaPayload? context) async {
    return aaStatusPayload('result');
  }

  /// Cancel listeners and dispose every port. Call when the node is removed
  /// from the canvas — otherwise its five controllers + subscriptions leak.
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    triggerPort.dispose();
    taskPort.dispose();
    contextPort.dispose();
    resultPort.dispose();
    statusPort.dispose();
  }
}