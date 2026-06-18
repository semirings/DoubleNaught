import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/workflow.dart';
import 'double_naught_node_wrapper.dart';
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

  /// The file chosen from local storage, or null before any selection.
  XFile? _selectedFile;
  int _bytesStreamed = 0;
  int _totalBytes = 0;
  bool _isStreaming = false;
  bool _allDone = false;
  String? _errorMessage;

  /// Determinate 0..1 value for the loading bar, or null (indeterminate) while
  /// the total file size isn't known yet.
  double? get _loadingProgress =>
      _totalBytes > 0 ? (_bytesStreamed / _totalBytes).clamp(0.0, 1.0) : null;

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

  /// Clickpoint handler: open the native local-storage dialog, then stream the
  /// chosen file's raw bytes out of the output port, advancing
  /// [_loadingProgress] until the read finishes and [_allDone] is set.
  Future<void> _pickAndStream() async {
    final XFile? picked = await openFile();
    if (picked == null) return; // user cancelled

    setState(() {
      _selectedFile = picked;
      _bytesStreamed = 0;
      _totalBytes = 0;
      _isStreaming = true;
      _allDone = false;
      _errorMessage = null;
    });

    try {
      _totalBytes = await picked.length();
      await for (final chunk in picked.openRead()) {
        if (!mounted) return;
        _output.add(chunk);
        setState(() => _bytesStreamed += chunk.length);
      }
      if (mounted) setState(() => _allDone = true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '$e');
    } finally {
      if (mounted) setState(() => _isStreaming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFile = _selectedFile != null;

    // Container chrome comes from the universal wrapper; the output port is
    // edge-anchored on the right per the Edge-Anchor pattern.
    return DoubleNaughtNodeWrapper(
      title: 'File Source',
      icon: Icons.insert_drive_file_outlined,
      outputPorts: [
        OutputConnector(
          label: 'contents',
          idx: 0,
          active: hasFile,
          onTap: _isStreaming ? null : _pickAndStream,
          // Drag this dot onto a node's input to wire an edge.
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Clickpoint: opens the native local-storage dialog.
          InkWell(
            onTap: _isStreaming ? null : _pickAndStream,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
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
                      hasFile ? _selectedFile!.name : 'Choose file…',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // loadingProgress bar / allDone indicator / error.
          _buildStatus(theme),
        ],
      ),
    );
  }

  /// The streaming status area: an error, the active green loadingProgress bar,
  /// or the green "allDone" checkmark once the file has fully streamed.
  Widget _buildStatus(ThemeData theme) {
    if (_errorMessage != null) {
      return Text(_errorMessage!,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12));
    }
    if (_isStreaming) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _loadingProgress,
              minHeight: 6,
              color: Colors.green,
              backgroundColor: theme.colorScheme.outlineVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Loading… $_bytesStreamed'
            '${_totalBytes > 0 ? ' / $_totalBytes' : ''} bytes',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    if (_allDone) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Text('allDone',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.green, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('$_bytesStreamed bytes', style: theme.textTheme.bodySmall),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}
