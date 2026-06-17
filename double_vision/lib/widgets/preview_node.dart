import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/workflow.dart';
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
        if (_preview.length < 600) {
          _preview += utf8.decode(chunk, allowMalformed: true);
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

    return SizedBox(
      width: 240,
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.preview_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(widget.node.type,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
              const Divider(height: 16),

              // Input connector (left edge) — drop an output here to wire it.
              Align(
                alignment: Alignment.centerLeft,
                child: InputConnector(
                  label: 'in',
                  idx: 0,
                  active: wired,
                  onConnect: widget.onConnect,
                ),
              ),
              const SizedBox(height: 8),

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
        ),
      ),
    );
  }
}
