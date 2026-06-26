import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/workflow.dart';
import 'double_naught_node_wrapper.dart';
import 'input_connector.dart';
import 'output_connector.dart';
import 'sam3_control_panel.dart';

/// A workflow node that hosts a [Sam3ControlPanel] inside the universal
/// [DoubleNaughtNodeWrapper] — the canonical demonstration of the compositional
/// pattern: the wrapper owns chrome + edge-anchored ports, the injected panel
/// owns behaviour.
///
/// Ports (per the DESIGN.md contract): a `preview` **input** on the left and
/// two **outputs** on the right (`segmentStream`, `imageArray`). When an image
/// is wired into `preview`, the node accumulates the bytes and reports them via
/// [onPreviewImage] for the canvas's image sidebar.
class Sam3Node extends StatefulWidget {
  final WorkflowNode node;

  /// Backend session id for the loaded image; null until one is wired in.
  final String? sessionId;

  /// Publishes the per-prompt result stream — the `segmentStream` output port.
  final void Function(Stream<Sam3Payload> segments)? onConnect;

  /// Publishes the segmentation image-array stream — the `imageArray` output.
  final void Function(Stream<List<Uint8List>> images)? onImageArrayConnect;

  /// Records an edge dropped on the `preview` input port.
  final void Function(PortRef source)? onPreviewConnect;

  /// Incoming bytes wired into `preview`, or null when nothing is connected.
  final Stream<Uint8List>? previewInput;

  /// Filename of the source feeding `preview`, when known.
  final String? previewFileName;

  /// Reports the image accumulated on `preview` (for the canvas sidebar).
  final void Function(Uint8List bytes, String? fileName)? onPreviewImage;

  /// Output port indices with an outgoing edge — drives the connected
  /// highlight, matching how input ports highlight when wired.
  final Set<int> connectedOutputs;

  const Sam3Node({
    super.key,
    required this.node,
    this.sessionId,
    this.onConnect,
    this.onImageArrayConnect,
    this.onPreviewConnect,
    this.previewInput,
    this.previewFileName,
    this.onPreviewImage,
    this.connectedOutputs = const {},
  });

  @override
  State<Sam3Node> createState() => _Sam3NodeState();
}

class _Sam3NodeState extends State<Sam3Node> {
  final StreamController<Sam3Payload> _segments =
      StreamController<Sam3Payload>.broadcast();

  /// Carries segmentation result images downstream. Fed once the backend
  /// returns real image arrays (the stub emits only mask metadata today).
  final StreamController<List<Uint8List>> _imageArray =
      StreamController<List<Uint8List>>.broadcast();

  StreamSubscription<Uint8List>? _previewSub;
  BytesBuilder _previewBuilder = BytesBuilder();

  bool _hasSegments = false;

  @override
  void initState() {
    super.initState();
    widget.onConnect?.call(_segments.stream);
    widget.onImageArrayConnect?.call(_imageArray.stream);
    _subscribePreview();
  }

  @override
  void didUpdateWidget(Sam3Node oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewInput != widget.previewInput) _subscribePreview();
  }

  @override
  void dispose() {
    _previewSub?.cancel();
    _segments.close();
    _imageArray.close();
    super.dispose();
  }

  /// Accumulate the `preview` byte stream and surface the image to the sidebar.
  void _subscribePreview() {
    _previewSub?.cancel();
    _previewBuilder = BytesBuilder();
    _previewSub = widget.previewInput?.listen((chunk) {
      if (!mounted) return;
      _previewBuilder.add(chunk);
      widget.onPreviewImage
          ?.call(_previewBuilder.toBytes(), widget.previewFileName);
    });
  }

  void _onResult(Sam3Payload payload) {
    _segments.add(payload);
    if (!_hasSegments) setState(() => _hasSegments = true);
  }

  @override
  Widget build(BuildContext context) {
    final previewConnected = widget.previewInput != null;
    return DoubleNaughtNodeWrapper(
      title: 'Segmentation',
      icon: Icons.auto_awesome_mosaic_outlined,
      inputPorts: [
        InputConnector(
          label: 'preview',
          idx: 0,
          active: previewConnected, // highlight when wired, like Preview's input
          onConnect: widget.onPreviewConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'segmentStream',
          idx: 0,
          active: _hasSegments || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'imageArray',
          idx: 1,
          active: widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ],
      child: Sam3ControlPanel(
        sessionId: widget.sessionId,
        onResult: _onResult,
      ),
    );
  }
}
