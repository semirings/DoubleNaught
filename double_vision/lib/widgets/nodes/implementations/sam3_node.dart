import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../models/workflow.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';
import 'sam3_control_panel.dart';

/// A workflow node that hosts a [Sam3ControlPanel] inside the universal
/// node shell — the canonical demonstration of the compositional pattern:
/// the wrapper owns chrome + edge-anchored ports, the injected panel owns
/// behaviour.
///
/// Ports (per the DESIGN.md contract): a `preview` **input** on the left and
/// two **outputs** on the right (`segmentStream`, `imageArray`). When an image
/// is wired into `preview`, the node accumulates the bytes and reports them via
/// [onPreviewImage] for the canvas's image sidebar.
class Sam3Node extends BaseNodeWidget {
  /// Backend session id for the loaded image; null until one is wired in.
  final String? sessionId;

  /// Publishes the per-prompt result stream — the `segmentStream` output port.
  final void Function(Stream<Sam3Payload> segments)? onConnect;

  /// Publishes the segmentation image-array stream — the `imageArray` output.
  final void Function(Stream<List<Uint8List>> images)? onImageArrayConnect;

  /// Incoming bytes wired into `preview`, or null when nothing is connected.
  final Stream<Uint8List>? previewInput;

  /// Filename of the source feeding `preview`, when known.
  final String? previewFileName;

  /// Reports the image accumulated on `preview` (for the canvas sidebar).
  final void Function(Uint8List bytes, String? fileName)? onPreviewImage;

  const Sam3Node({
    super.key,
    required super.node,
    this.sessionId,
    this.onConnect,
    this.onImageArrayConnect,
    void Function(PortRef source)? onPreviewConnect,
    this.previewInput,
    this.previewFileName,
    this.onPreviewImage,
    super.connectedOutputs,
  }) : super(onInputConnect: onPreviewConnect);

  @override
  State<Sam3Node> createState() => _Sam3NodeState();
}

class _Sam3NodeState extends BaseNodeState<Sam3Node> {
  @override String   get nodeTitle => 'SAM3';
  @override IconData get nodeIcon  => Icons.auto_awesome_mosaic_outlined;

  final StreamController<Sam3Payload>      _segments   = StreamController.broadcast();
  final StreamController<List<Uint8List>>  _imageArray = StreamController.broadcast();

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
      widget.onPreviewImage?.call(_previewBuilder.toBytes(), widget.previewFileName);
    });
  }

  void _onResult(Sam3Payload payload) {
    _segments.add(payload);
    if (!_hasSegments) setState(() => _hasSegments = true);
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'preview',
          idx: 0,
          active: widget.previewInput != null,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
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
      ];

  @override
  Widget buildNodeBody(BuildContext context) => Sam3ControlPanel(
        sessionId: widget.sessionId,
        onResult: _onResult,
      );
}
