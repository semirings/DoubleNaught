import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../focus_panel.dart' show FocusContent;
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';

/// Detected kind of the incoming bytes.
enum _Media { png, jpeg, gif, webp, other }

/// A universal **display** sink. It has two inputs — a `bytes` port (images or
/// text) and an `aa` port (a D4M associative array) — and renders whatever
/// arrives in the right-hand **Focus Panel** (as a tab), *not* inside the node.
/// The node itself stays a compact routing box showing a one-line summary and a
/// "View in panel" button.
class PreviewNode extends StatefulWidget {
  final WorkflowNode node;

  /// Upstream byte stream (image/text), or null when nothing is wired.
  final Stream<Uint8List>? input;

  /// True when the `bytes` port has an incoming edge (drives its highlight).
  final bool inputConnected;

  /// True when the `aa` port has an incoming edge (drives its highlight).
  final bool aaConnected;

  /// Called when an edge is dropped on the `bytes` input.
  final void Function(PortRef source)? onConnect;

  /// Called when an edge is dropped on the `aa` input.
  final void Function(PortRef source)? onAaConnect;

  /// Registers the node's AA ingress InputPort with the canvas bridge.
  final void Function(InputPort port)? onAaInputPort;

  /// Filename of the byte source, when known (carried out-of-band).
  final String? fileName;

  /// Pushes decoded content to the Focus Panel as this node's tab.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Opens the Focus Panel and selects this node's tab.
  final void Function(int nodeId)? onView;

  const PreviewNode({
    super.key,
    required this.node,
    this.input,
    this.inputConnected = false,
    this.aaConnected = false,
    this.onConnect,
    this.onAaConnect,
    this.onAaInputPort,
    this.fileName,
    this.onContent,
    this.onView,
  });

  @override
  State<PreviewNode> createState() => _PreviewNodeState();
}

class _PreviewNodeState extends State<PreviewNode> {
  // --- byte input ---
  StreamSubscription<Uint8List>? _sub;
  BytesBuilder _builder = BytesBuilder();
  Uint8List? _data;
  int _bytes = 0;
  _Media _media = _Media.other;
  int? _imageWidth;
  int? _imageHeight;
  bool _decoding = false;

  // --- AA input (owned port, wired by the canvas bridge) ---
  final InputPort _aaIn = InputPort('aa');
  AaPayload? _aa;

  bool get _isImage => _media != _Media.other;
  bool get _hasContent => _aa != null || (_data != null && _bytes > 0);

  @override
  void initState() {
    super.initState();
    widget.onAaInputPort?.call(_aaIn);
    _aaIn.onDataArrived.listen(_onAa);
    _subscribeBytes();
  }

  @override
  void didUpdateWidget(PreviewNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input) _subscribeBytes();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _aaIn.dispose();
    super.dispose();
  }

  void _subscribeBytes() {
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
    if (_isImage && _imageWidth == null) {
      _decodeDimensions(data);
    } else {
      _report();
    }
  }

  void _onAa(AaPayload payload) {
    if (!mounted) return;
    setState(() => _aa = payload);
    _report();
  }

  /// Push the current content to the Focus Panel tab for this node.
  void _report() {
    final content = _buildContent();
    if (content != null) widget.onContent?.call(widget.node.id, content);
  }

  FocusContent? _buildContent() {
    if (_aa != null) {
      final rows = _aa!.distinctRows().length;
      final cols = _distinctColCount(_aa!);
      return FocusContent.aa(_aa!, subtitle: '$rows rows × $cols cols');
    }
    if (_data == null || _bytes == 0) return null;
    if (_isImage) {
      final dims = (_imageWidth != null && _imageHeight != null)
          ? '$_imageWidth × $_imageHeight'
          : null;
      return FocusContent.image(
        bytes: _data,
        subtitle: [
          _mediaLabel,
          _humanSize(_bytes),
          if (dims != null) dims,
        ].join(' · '),
      );
    }
    final text = utf8.decode(_data!, allowMalformed: true);
    return FocusContent.text(text, subtitle: _humanSize(_bytes));
  }

  int _distinctColCount(AaPayload aa) {
    final seen = <String>{};
    for (final c in aa.cols) {
      seen.add(c);
    }
    return seen.length;
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
      _report();
    }
  }

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
      return _Media.gif;
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return _Media.webp;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DoubleNaughtNodeWrapper(
      title: 'Preview',
      icon: Icons.preview_outlined,
      inputPorts: [
        InputConnector(
          label: 'bytes',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onConnect,
        ),
        InputConnector(
          label: 'aa',
          idx: 1,
          active: widget.aaConnected,
          onConnect: widget.onAaConnect,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(theme),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  _hasContent ? () => widget.onView?.call(widget.node.id) : null,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('View in panel'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (!widget.inputConnected && !widget.aaConnected) {
      return Text('Connect a source (bytes or AA)', style: muted);
    }

    final String kind;
    if (_aa != null) {
      kind = 'AA · ${_aa!.distinctRows().length} rows × '
          '${_distinctColCount(_aa!)} cols';
    } else if (_isImage) {
      final dims = (_imageWidth != null && _imageHeight != null)
          ? ' · $_imageWidth × $_imageHeight'
          : '';
      kind = '$_mediaLabel · ${_humanSize(_bytes)}$dims';
    } else if (_bytes > 0) {
      kind = 'Text · ${_humanSize(_bytes)}';
    } else {
      kind = 'Waiting for data…';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.fileName ?? 'Received content',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(kind,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
      ],
    );
  }
}
