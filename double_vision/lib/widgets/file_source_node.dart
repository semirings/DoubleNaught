import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/workflow.dart';
import 'output_connector.dart';

/// A workflow source node that opens the local file dialog and streams the
/// chosen file's bytes out of a single output connector ("contents").
///
/// The clickpoint (the node body / "Choose file…" area) calls [openFile] from
/// `file_selector`, which presents the native dialog (and the browser picker on
/// web). The selected [XFile] is read with `openRead()`, producing a
/// `Stream<Uint8List>` that is re-broadcast on the output port so any number of
/// downstream listeners can consume it.
///
/// [onConnect] is invoked once with the broadcast output stream, modelling the
/// edge attached to this node's output port (`PortRef{nodeId: node.id, idx: 0}`).
class FileSourceNode extends StatefulWidget {
  /// Graph metadata for this node (id/type/position).
  final WorkflowNode node;

  /// Called once with the node's output stream — the "connector". Downstream
  /// nodes subscribe to this to receive file content chunks.
  final void Function(Stream<Uint8List> contents)? onConnect;

  const FileSourceNode({super.key, required this.node, this.onConnect});

  @override
  State<FileSourceNode> createState() => _FileSourceNodeState();
}

class _FileSourceNodeState extends State<FileSourceNode> {
  /// Broadcast output port. Created up front so [onConnect] can hand it to
  /// downstream nodes before any file is chosen.
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();

  XFile? _file;
  int _bytesStreamed = 0;
  bool _streaming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Publish the output connector immediately.
    widget.onConnect?.call(_output.stream);
  }

  @override
  void dispose() {
    _output.close();
    super.dispose();
  }

  /// Clickpoint handler: open the local file dialog, then pump the file's bytes
  /// through the output port.
  Future<void> _pickAndStream() async {
    final XFile? picked = await openFile();
    if (picked == null) return; // user cancelled

    setState(() {
      _file = picked;
      _bytesStreamed = 0;
      _streaming = true;
      _error = null;
    });

    try {
      await for (final chunk in picked.openRead()) {
        if (!mounted) return;
        _output.add(chunk);
        setState(() => _bytesStreamed += chunk.length);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _streaming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFile = _file != null;

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
            // Header: node type.
            Row(
              children: [
                Icon(Icons.insert_drive_file_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(widget.node.type,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const Divider(height: 16),

            // Clickpoint: opens the local file dialog.
            InkWell(
              onTap: _streaming ? null : _pickAndStream,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 220,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        hasFile ? _file!.name : 'Choose file…',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Stream status.
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12))
            else if (hasFile)
              Text(
                _streaming
                    ? 'Streaming… $_bytesStreamed bytes'
                    : 'Sent $_bytesStreamed bytes',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),

            // Output connector, aligned to the right edge.
            Align(
              alignment: Alignment.centerRight,
              child: OutputConnector(
                label: 'contents',
                idx: 0,
                active: hasFile,
                onTap: _streaming ? null : _pickAndStream,
                // Drag this dot onto a node's input to wire an edge.
                dragData: PortRef(nodeId: widget.node.id, idx: 0),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
