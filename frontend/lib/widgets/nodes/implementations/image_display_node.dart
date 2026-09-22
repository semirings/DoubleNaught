import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../focus_panel.dart' show resolveImageProvider;
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// The emit sinks for an [ImageDisplayNode]'s three interactive outputs, handed
/// to the host so the Focus Panel can route overlay interactions (a typed
/// prompt, a dragged box, a clicked point) back out of the node that owns the
/// image.
class ImageDisplayOutputs {
  final void Function(String prompt) emitPrompt;

  /// Normalized `[left, top, right, bottom]`, 0..1.
  final void Function(List<double> boxLtrb) emitBox;

  /// Normalized `[x, y]`, 0..1.
  final void Function(List<double> pointXy) emitPoint;

  const ImageDisplayOutputs({
    required this.emitPrompt,
    required this.emitBox,
    required this.emitPoint,
  });
}

/// The image processing and display hub.
///
/// It owns no location string of its own — the source location arrives on its
/// single `urlInput` port from an upstream URL Source node, which handles
/// filesystem/network URI generation. This node resolves that location, loads
/// the asset into memory, and routes interactive selections downstream.
///
/// The node stays a compact routing box: the image never renders here. Once the
/// asset is fully loaded, a small indicator appears in the node's lower-right
/// corner; clicking it slides open the right-side Focus Panel for the rich
/// display and future SAM3 overlays.
///
///  * Input:  `urlInput`
///  * Outputs: `promptOutput`, `boxSelectOutput`, `pointClickOutput`
class ImageDisplayNode extends BaseNodeWidget {
  /// Opens the Focus Panel for this node instance with the loaded location.
  final void Function(int nodeId, String targetUrl)? onViewImageAssets;

  /// Publishes the `promptOutput` stream to the canvas.
  final void Function(Stream<String> promptOutput)? onPromptConnect;

  /// Publishes the `boxSelectOutput` stream to the canvas.
  final void Function(Stream<List<double>> boxSelectOutput)? onBoxSelectConnect;

  /// Publishes the `pointClickOutput` stream to the canvas.
  final void Function(Stream<List<double>> pointClickOutput)? onPointClickConnect;

  /// Hands this node's emit sinks to the host, keyed by node id.
  final void Function(int nodeId, ImageDisplayOutputs outputs)? onOutputsReady;

  const ImageDisplayNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputPort,
    super.onInputConnect,
    this.onViewImageAssets,
    this.onPromptConnect,
    this.onBoxSelectConnect,
    this.onPointClickConnect,
    this.onOutputsReady,
    super.connectedOutputs,
  });

  @override
  State<ImageDisplayNode> createState() => _ImageDisplayNodeState();
}

class _ImageDisplayNodeState extends BaseNodeState<ImageDisplayNode> {
  @override String   get nodeTitle => 'Image Display';
  @override IconData get nodeIcon  => Icons.image_outlined;

  final InputPort _in = InputPort('urlInput');

  final StreamController<String>       _promptOutput     = StreamController.broadcast();
  final StreamController<List<double>> _boxSelectOutput  = StreamController.broadcast();
  final StreamController<List<double>> _pointClickOutput = StreamController.broadcast();

  String targetUrl  = '';
  bool   isImageLoaded = false;
  String? loadError;
  int? imageWidth;
  int? imageHeight;

  ImageStream?         _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState() {
    super.initState();

    // Publish the three output streams up front so downstream nodes can attach
    // before any interaction has happened.
    widget.onPromptConnect?.call(_promptOutput.stream);
    widget.onBoxSelectConnect?.call(_boxSelectOutput.stream);
    widget.onPointClickConnect?.call(_pointClickOutput.stream);

    widget.onOutputsReady?.call(
      widget.node.id,
      ImageDisplayOutputs(
        emitPrompt: (prompt) {
          if (!_promptOutput.isClosed) _promptOutput.add(prompt);
        },
        emitBox: (box) {
          if (!_boxSelectOutput.isClosed) _boxSelectOutput.add(box);
        },
        emitPoint: (point) {
          if (!_pointClickOutput.isClosed) _pointClickOutput.add(point);
        },
      ),
    );

    initInputPort(_in, _onIncoming);
  }

  @override
  void dispose() {
    _in.dispose();
    _detachImageStream();
    _promptOutput.close();
    _boxSelectOutput.close();
    _pointClickOutput.close();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    final url = payload.value('url') ?? '';
    if (url.isEmpty) return;
    setState(() {
      targetUrl    = url;
      isImageLoaded = false;
      loadError     = null;
      imageWidth    = null;
      imageHeight   = null;
    });
    _loadImage(url);
  }

  void _detachImageStream() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream   = null;
    _imageListener = null;
  }

  /// Resolve and decode the asset into memory without rendering it here. Only
  /// when the first frame arrives is the node considered loaded, which reveals
  /// the lower-right indicator.
  void _loadImage(String url) {
    _detachImageStream();
    final provider = resolveImageProvider(url);
    if (provider == null) return;

    _imageStream   = provider.resolve(ImageConfiguration.empty);
    _imageListener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          isImageLoaded = true;
          loadError     = null;
          imageWidth    = info.image.width;
          imageHeight   = info.image.height;
        });
      },
      onError: (error, _) {
        if (!mounted) return;
        setState(() {
          isImageLoaded = false;
          loadError     = 'That image could not be loaded.';
        });
      },
    );
    _imageStream!.addListener(_imageListener!);
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'urlInput')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'promptOutput',
          idx: 0,
          active: widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'boxSelectOutput',
          idx: 1,
          active: widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
        OutputConnector(
          label: 'pointClickOutput',
          idx: 2,
          active: widget.connectedOutputs.contains(2),
          dragData: PortRef(nodeId: widget.node.id, idx: 2),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        _status(theme),
        if (isImageLoaded)
          Positioned(right: 0, bottom: 0, child: _assetsIndicator(theme)),
      ],
    );
  }

  Widget _status(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (!widget.inputConnected) {
      return SizedBox(
        width: double.infinity,
        child: Text('Connect a URL Source node', style: muted),
      );
    }
    if (targetUrl.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: Text('Waiting for a source location', style: muted),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            targetUrl,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 6),
          if (loadError != null)
            Text(loadError!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12))
          else if (!isImageLoaded)
            Row(
              children: [
                const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('Loading image', style: muted),
              ],
            )
          else
            Text(
              imageWidth != null && imageHeight != null
                  ? 'Image ready · $imageWidth × $imageHeight'
                  : 'Image ready',
              style: muted,
            ),
          if (isImageLoaded) const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _assetsIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Show image assets',
      child: InkWell(
        onTap: () => widget.onViewImageAssets?.call(widget.node.id, targetUrl),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_library_outlined, size: 12, color: scheme.onPrimary),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 12, color: scheme.onPrimary),
            ],
          ),
        ),
      ),
    );
  }
}
