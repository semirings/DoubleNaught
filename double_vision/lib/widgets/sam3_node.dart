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
/// Per the DESIGN.md port contract the node exposes a `preview` **input** on the
/// left and two **outputs** on the right:
///  * `segmentStream` — the per-prompt [Sam3Payload] results, and
///  * `imageArray` — the segmentation result images as a `List<Uint8List>`.
///
/// The panel is a pure controller, so this node only re-broadcasts what the
/// panel emits; a downstream viewport renders the images and captures clicks.
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

  const Sam3Node({
    super.key,
    required this.node,
    this.sessionId,
    this.onConnect,
    this.onImageArrayConnect,
    this.onPreviewConnect,
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

  bool _hasSegments = false;

  @override
  void initState() {
    super.initState();
    widget.onConnect?.call(_segments.stream);
    widget.onImageArrayConnect?.call(_imageArray.stream);
  }

  @override
  void dispose() {
    _segments.close();
    _imageArray.close();
    super.dispose();
  }

  void _onResult(Sam3Payload payload) {
    _segments.add(payload);
    if (!_hasSegments) setState(() => _hasSegments = true);
  }

  @override
  Widget build(BuildContext context) {
    return DoubleNaughtNodeWrapper(
      title: 'sam3Work',
      icon: Icons.auto_awesome_mosaic_outlined,
      inputPorts: [
        InputConnector(label: 'preview', idx: 0, onConnect: widget.onPreviewConnect),
      ],
      outputPorts: [
        OutputConnector(
          label: 'segmentStream',
          idx: 0,
          active: _hasSegments,
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'imageArray',
          idx: 1,
          // Inactive until the backend returns real segmentation images.
          active: false,
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
