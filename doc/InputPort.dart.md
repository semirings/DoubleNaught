/// A robust Input Port wrapper for N&N Canvas Nodes
class InputPort {
  final String id;
  final bool isRequired;

  // The active wire subscription from an upstream OutputPort
  StreamSubscription<AaPayload>? _subscription;
  OutputPort? _connectedOutputPort;

  // Internal queue to buffer incoming payloads
  final List<AaPayload> _buffer = [];

  // Stream controller to notify the parent AgentNode when new data arrives
  final _arrivalController = StreamController<AaPayload>.broadcast();
  Stream<AaPayload> get onDataArrived => _arrivalController.stream;

  InputPort(this.id, {this.isRequired = true});

  /// Check if this port has data ready to consume
  bool get hasData => _buffer.isNotEmpty || _connectedOutputPort?.lastPayload != null;

  /// Inspect the current or latest payload without removing it from the queue
  AaPayload? peek() {
    if (_buffer.isNotEmpty) return _buffer.first;
    return _connectedOutputPort?.lastPayload;
  }

  /// Consume and pop the next payload from the queue
  AaPayload? pop() {
    if (_buffer.isNotEmpty) {
      return _buffer.removeAt(0);
    }
    return _connectedOutputPort?.lastPayload;
  }

  /// Connect this InputPort to an upstream OutputPort (when a wire is drawn)
  void connect(OutputPort outputPort, {bool pullInitialState = true}) {
    disconnect(); // Clear any existing connection first

    _connectedOutputPort = outputPort;

    _subscription = outputPort.connect(
      (payload) {
        _buffer.add(payload);
        _arrivalController.add(payload);
      },
      emitCurrentState: pullInitialState,
    );
  }

  /// Disconnect the wire (when user deletes a connection)
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _connectedOutputPort = null;
    _buffer.clear();
  }

  void dispose() {
    disconnect();
    _arrivalController.close();
  }
}