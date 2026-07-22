/// A robust Output Port wrapper for N&N Canvas Nodes
class OutputPort {
  final String id;
  
  // 1. Maintain a synchronous cache of the latest D4M payload
  AaPayload? _lastPayload;
  AaPayload? get lastPayload => _lastPayload;

  // 2. Internal event bus for live streaming updates
  final _controller = StreamController<AaPayload>.broadcast();

  OutputPort(this.id);

  /// Emit a new payload downstream
  void emit(AaPayload payload) {
    _lastPayload = payload;
    _controller.add(payload);
  }

  /// Connect a subscriber (InputPort) safely
  StreamSubscription<AaPayload> connect(
    void onData(AaPayload payload), {
    bool emitCurrentState = true,
  }) {
    // Replay latest state immediately if requested and present
    if (emitCurrentState && _lastPayload != null) {
      onData(_lastPayload!);
    }
    return _controller.stream.listen(onData);
  }

  void dispose() {
    _controller.close();
  }
}