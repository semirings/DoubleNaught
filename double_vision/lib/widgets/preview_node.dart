import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/workflow.dart';
import 'double_naught_node_wrapper.dart';
import 'input_connector.dart';

/// A workflow sink node: an input connector that consumes a byte stream wired
/// from an upstream output (e.g. [FileSourceNode]) and shows a short preview.
///
/// [input] is the stream resolved by the canvas from the edge attached to this
/// node's input port; it is `null` until an edge is created. [onConnect] is
/// called when an output endpoint is dropped on the input connector.
class PreviewNode extends StatefulWidget {
  final WorkflowNode node;

  /// Upstream byte stream, or null when nothing is wired in.
  final Stream<Uint8List>? input;

  /// Called with the source endpoint when an edge is dropped on the input.
  final void Function(PortRef source)? onConnect;

  const PreviewNode({
    super.key,
    required this.node,
    this.input,
    this.onConnect,
  });

  @override
  State<PreviewNode> createState() => _PreviewNodeState();
}

class _PreviewNodeState extends State<PreviewNode> {
  /// Max characters held for the on-card preview. The full byte count is still
  /// tracked separately in [_bytes].
  static const int _previewLimit = 600;

  StreamSubscription<Uint8List>? _sub;
  int _bytes = 0;
  String _preview = '';

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(PreviewNode old) {
    super.didUpdateWidget(old);
    if (old.input != widget.input) _subscribe();
  }

  void _subscribe() {
    _sub?.cancel();
    _bytes = 0;
    _preview = '';
    _sub = widget.input?.listen((chunk) {
      if (!mounted) return;
      setState(() {
        _bytes += chunk.length;
        if (_preview.length < _previewLimit) {
          // Decode only the slice we still have room for. A whole-file chunk
          // (common on desktop) would otherwise build a huge string and freeze
          // the UI when rendered.
          final remaining = _previewLimit - _preview.length;
          final slice = chunk.length > remaining
              ? Uint8List.sublistView(chunk, 0, remaining)
              : chunk;
          _preview += utf8.decode(slice, allowMalformed: true);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wired = widget.input != null;

    // Container chrome comes from the universal wrapper; the input port is
    // edge-anchored on the left per the Edge-Anchor pattern.
    return DoubleNaughtNodeWrapper(
      title: 'Preview',
      icon: Icons.preview_outlined,
      inputPorts: [
        InputConnector(
          label: 'in',
          idx: 0,
          active: wired,
          onConnect: widget.onConnect,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Received $_bytes bytes', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            height: 84,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: Text(
                _preview.isEmpty
                    ? (wired ? 'Waiting for data…' : 'Not connected.')
                    : _preview,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
