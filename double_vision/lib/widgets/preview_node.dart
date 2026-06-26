import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/workflow.dart';
import 'double_naught_node_wrapper.dart';
import 'input_connector.dart';

/// Detected kind of the incoming bytes.
enum _Media { png, jpeg, gif, webp, other }

/// A workflow sink node that consumes a byte stream wired from an upstream
/// output (e.g. [FileSourceNode]). It detects image data and renders it as an
/// actual image (via [Image.memory]); anything else falls back to a text
/// preview. The node shows file metadata in the upper-left, is user-resizable
/// from the lower-right, and has a full-size toggle in the lower-right.
class PreviewNode extends StatefulWidget {
  final WorkflowNode node;

  /// Upstream byte stream, or null when nothing is wired in.
  final Stream<Uint8List>? input;

  /// Called with the source endpoint when an edge is dropped on the input.
  final void Function(PortRef source)? onConnect;

  /// Filename of the upstream source, when known. Carried out-of-band by the
  /// canvas (the byte stream itself has no metadata).
  final String? fileName;

  const PreviewNode({
    super.key,
    required this.node,
    this.input,
    this.onConnect,
    this.fileName,
  });

  @override
  State<PreviewNode> createState() => _PreviewNodeState();
}

class _PreviewNodeState extends State<PreviewNode> {
  /// Minimum image-viewport size; the node never shrinks below this.
  static const Size _minViewport = Size(220, 150);

  /// Clamp full-size/resize so a huge image can't make an unusable node.
  static const double _maxViewport = 4096;

  /// Horizontal chrome (== kNodePadding.horizontal) added around the viewport
  /// to get the wrapper width.
  static const double _nodePaddingH = 24;

  StreamSubscription<Uint8List>? _sub;
  BytesBuilder _builder = BytesBuilder();
  Uint8List? _data;
  int _bytes = 0;

  _Media _media = _Media.other;
  int? _imageWidth;
  int? _imageHeight;
  bool _decoding = false;

  Size _viewport = _minViewport;
  bool _fullSize = false;
  Size? _sizeBeforeFullSize;

  bool get _isImage => _media != _Media.other;
  bool get _wired => widget.input != null;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(PreviewNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input) _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _sub?.cancel();
    _builder = BytesBuilder();
    _data = null;
    _bytes = 0;
    _media = _Media.other;
    _imageWidth = null;
    _imageHeight = null;
    _sub = widget.input?.listen(_onChunk);
  }

  void _onChunk(Uint8List chunk) {
    if (!mounted) return;
    _builder.add(chunk);
    final data = _builder.toBytes();
    setState(() {
      _bytes += chunk.length;
      _data = data;
      _media = _detectMedia(data);
    });
    // Resolve real pixel dimensions once the bytes decode as a full image.
    if (_isImage && _imageWidth == null) _decodeDimensions(data);
  }

  Future<void> _decodeDimensions(Uint8List data) async {
    if (_decoding) return;
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (mounted) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
        });
      }
    } catch (_) {
      // Not yet a complete/decodable image — retry on the next chunk.
    } finally {
      _decoding = false;
    }
  }

  /// Magic-byte sniff for the supported image formats.
  _Media _detectMedia(Uint8List b) {
    if (b.length >= 4 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return _Media.png;
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return _Media.jpeg;
    }
    if (b.length >= 4 &&
        b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      return _Media.gif; // GIF87a / GIF89a
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return _Media.webp; // RIFF....WEBP
    }
    return _Media.other;
  }

  String get _mediaLabel => switch (_media) {
        _Media.png => 'PNG',
        _Media.jpeg => 'JPEG',
        _Media.gif => 'GIF',
        _Media.webp => 'WebP',
        _Media.other => 'Binary',
      };

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double size = bytes / 1024;
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${units[i]}';
  }

  void _toggleFullSize() {
    setState(() {
      if (_fullSize) {
        _viewport = _sizeBeforeFullSize ?? _minViewport;
        _fullSize = false;
      } else {
        _sizeBeforeFullSize = _viewport;
        final w = (_imageWidth?.toDouble() ?? _viewport.width)
            .clamp(_minViewport.width, _maxViewport);
        final h = (_imageHeight?.toDouble() ?? _viewport.height)
            .clamp(_minViewport.height, _maxViewport);
        _viewport = Size(w, h);
        _fullSize = true;
      }
    });
  }

  void _resizeBy(Offset delta) {
    setState(() {
      _fullSize = false;
      _viewport = Size(
        (_viewport.width + delta.dx).clamp(_minViewport.width, _maxViewport),
        (_viewport.height + delta.dy).clamp(_minViewport.height, _maxViewport),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Preserve the input port and data flow; only the body changes.
    return DoubleNaughtNodeWrapper(
      title: 'Preview',
      icon: Icons.preview_outlined,
      width: _viewport.width + _nodePaddingH,
      inputPorts: [
        InputConnector(
          label: 'in',
          idx: 0,
          active: _wired,
          onConnect: widget.onConnect,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metadata(theme),
          const SizedBox(height: 6),
          _viewportArea(theme),
        ],
      ),
    );
  }

  /// Upper-left metadata: filename, then format • size • dimensions.
  Widget _metadata(ThemeData theme) {
    final dims = (_imageWidth != null && _imageHeight != null)
        ? '$_imageWidth × $_imageHeight'
        : null;
    final facts = <String>[
      if (_isImage) _mediaLabel,
      if (_bytes > 0) _humanSize(_bytes),
      if (dims != null) dims,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.fileName ?? (_wired ? '(unnamed source)' : 'Not connected'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (facts.isNotEmpty)
          Text(
            facts.join('  •  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _viewportArea(ThemeData theme) {
    return SizedBox(
      width: _viewport.width,
      height: _viewport.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _content(theme),
              ),
            ),
          ),
          // Full-size toggle (lower-right), above the resize grip.
          Positioned(right: 4, bottom: 22, child: _toggleButton(theme)),
          // Resize handle (lower-right corner).
          Positioned(right: 0, bottom: 0, child: _resizeHandle(theme)),
        ],
      ),
    );
  }

  Widget _content(ThemeData theme) {
    if (_data == null || _bytes == 0) {
      return Center(
        child: Text(_wired ? 'Waiting for data…' : 'Not connected.',
            style: theme.textTheme.bodySmall),
      );
    }
    if (_isImage) {
      // Render the raw bytes directly — the Flutter equivalent of an <img> with
      // a base64 data URL, without the base64 round-trip. At full size the
      // viewport equals the native pixel size, so `contain` shows it 1:1.
      return Image.memory(
        _data!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Center(
          child: Text('Cannot decode image', style: theme.textTheme.bodySmall),
        ),
      );
    }
    // Non-image fallback: a short monospace text preview.
    final limit = _data!.length > 600 ? 600 : _data!.length;
    final text = utf8.decode(
      Uint8List.sublistView(_data!, 0, limit),
      allowMalformed: true,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Text(text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
    );
  }

  Widget _toggleButton(ThemeData theme) {
    final enabled = _isImage;
    return Tooltip(
      message: _fullSize ? 'Restore size' : 'Full size (native resolution)',
      child: InkWell(
        onTap: enabled ? _toggleFullSize : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          // ⤢ expand / ⤡ collapse.
          child: Icon(
            _fullSize ? Icons.close_fullscreen : Icons.open_in_full,
            size: 14,
            color: enabled ? theme.colorScheme.primary : theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _resizeHandle(ThemeData theme) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _resizeBy(d.delta),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(Icons.south_east, size: 14, color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}
