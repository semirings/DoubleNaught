import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'output_port.dart';

/// A robust Input Port wrapper for N&N Canvas Nodes
class InputPort {
  final String id;
  final bool isRequired;

  // The active wire subscription from an upstream OutputPort
  StreamSubscription<AaPayload>? _subscription;
  OutputPort? _connectedOutputPort;

  // Internal FIFO queue buffering incoming payloads. Bounded to shed
  // backpressure: once full, the oldest payload is dropped.
  final List<AaPayload> _buffer = [];
  final int maxBufferSize;

  // Stream controller to notify the parent AgentNode when new data arrives
  final _arrivalController = StreamController<AaPayload>.broadcast();
  Stream<AaPayload> get onDataArrived => _arrivalController.stream;

  // Fires when a live wire is severed — the other half of [connect]'s replay
  // contract. Without it a consumer keeps rendering the payload of an upstream
  // it is no longer wired to.
  final _departureController = StreamController<void>.broadcast();
  Stream<void> get onDisconnected => _departureController.stream;

  InputPort(this.id, {this.isRequired = true, this.maxBufferSize = 64});

  bool get isConnected => _subscription != null;

  /// The upstream port this input is wired to, or null when unconnected.
  OutputPort? get connectedOutputPort => _connectedOutputPort;

  /// True when there is a buffered payload ready to consume. The buffer is the
  /// single source of truth — an upstream's retained state is replayed *into*
  /// the buffer on [connect], so it is counted here too.
  bool get hasData => _buffer.isNotEmpty;

  /// Inspect the head of the queue without consuming it.
  AaPayload? peek() => _buffer.isNotEmpty ? _buffer.first : null;

  /// Consume and remove the head of the queue, or null when empty.
  AaPayload? pop() => _buffer.isEmpty ? null : _buffer.removeAt(0);

  /// Basic ingress guard: accept only a non-empty associative array. Malformed
  /// or empty payloads are dropped before they reach the queue.
  bool _acceptIngress(AaPayload payload) => payload.cols.isNotEmpty;

  /// Connect this InputPort to an upstream OutputPort (when a wire is drawn).
  void connect(OutputPort outputPort, {bool pullInitialState = true}) {
    debugPrint('[PORT-DEBUG] InputPort($id).connect() to OutputPort(${outputPort.id})');
    disconnect(); // Clear any existing connection first

    _connectedOutputPort = outputPort;

    _subscription = outputPort.connect(
      (payload) {
        debugPrint('[PORT-DEBUG] InputPort($id) ingress: cols=${payload.cols.length}');
        if (!_acceptIngress(payload)) {
          debugPrint('[PORT-DEBUG] InputPort($id) dropped payload: empty cols');
          return; // schema guard on ingress
        }
        _buffer.add(payload);
        if (_buffer.length > maxBufferSize) _buffer.removeAt(0);
        debugPrint('[PORT-DEBUG] InputPort($id) firing onDataArrived, buffer size=${_buffer.length}');
        _arrivalController.add(payload);
      },
      emitCurrentState: pullInitialState,
    );
  }

  /// Disconnect the wire (when user deletes a connection).
  ///
  /// Fires [onDisconnected] when a live wire was actually severed, unless
  /// [notify] is false (used by [dispose], where nobody is left to tell).
  /// [connect] calls this first, so re-pointing an input emits a departure and
  /// then immediately replays the new upstream's retained payload.
  void disconnect({bool notify = true}) {
    final wasConnected = _subscription != null;
    _subscription?.cancel();
    _subscription = null;
    _connectedOutputPort = null;
    _buffer.clear();
    if (wasConnected && notify) _departureController.add(null);
  }

  void dispose() {
    disconnect(notify: false);
    _arrivalController.close();
    _departureController.close();
  }
}