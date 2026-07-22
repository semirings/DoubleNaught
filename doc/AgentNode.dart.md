class AgentNode {
  // 1. Ingress Ports
  final triggerPort = InputPort('trigger', isRequired: true);
  final taskPort = InputPort('taskIn', isRequired: true);
  final contextPort = InputPort('contextIn', isRequired: false);

  // 2. Egress Ports
  final resultPort = OutputPort('resultOut');
  final statusPort = OutputPort('statusOut');

  AgentNode() {
    // Listen for trigger events
    triggerPort.onDataArrived.listen((_) => _tryExecute());
  }

  void _tryExecute() async {
    // Check if required ports are satisfied
    if (!taskPort.hasData) return;

    final task = taskPort.pop();
    final context = contextPort.pop();

    statusPort.emit(AaPayload.status('thinking'));

    // Call Python MLX engine ...
    final result = await callMlxBackend(task, context);

    // Emit result downstream
    resultPort.emit(result);
    statusPort.emit(AaPayload.status('idle'));
  }
}