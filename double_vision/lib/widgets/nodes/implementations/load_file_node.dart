import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/aa_file.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/output_connector.dart';

/// A workflow source node that opens the local file dialog and streams the
/// chosen file's bytes out of a `contents` connector (idx 0).
///
/// When the chosen file is a `.json` file that conforms to the rcvs AA schema
/// (`{rows, cols, vals}`), it is *also* parsed and emitted as an [AaPayload] on
/// a second `aa` connector (idx 1), so a downstream Preview (or any AA
/// consumer) can display it as a table rather than raw text. Non-AA files leave
/// that port inert.
///
/// Renamed from `FileSourceNode` (type `file_source`). The `file_source` type
/// is handled as a backward-compat alias in the workflow page's `_buildNode`.
class LoadFileNode extends StatefulWidget {
  final WorkflowNode node;
  final Map<String, String>? initialParams;
  final void Function(Map<String, String>)? onParams;

  final void Function(Stream<Uint8List> contents)? onConnect;
  final void Function(String fileName)? onFileName;
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  const LoadFileNode({
    super.key,
    required this.node,
    this.initialParams,
    this.onParams,
    this.onConnect,
    this.onFileName,
    this.onOutputPort,
    this.connectedOutputs = const {},
  });

  static AaPayload? detectAa(Uint8List bytes, String? fileName) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.json')) {
      return null;
    }
    try {
      final aa = AaFile.decode(jsonDecode(utf8.decode(bytes))).toSparse();
      return aa.cols.isNotEmpty ? aa : null;
    } catch (_) {
      return null;
    }
  }

  @override
  State<LoadFileNode> createState() => _LoadFileNodeState();
}

class _LoadFileNodeState extends State<LoadFileNode> {
  final List<Uint8List> _buffer = [];
  late final StreamController<Uint8List> _output;
  final OutputPort _aaOut = OutputPort('aa');

  AaPayload? _aa;
  XFile? _selectedFile;
  int _bytesStreamed = 0;
  int _totalBytes = 0;
  bool _isStreaming = false;
  bool _allDone = false;
  String? _errorMessage;

  double? get _loadingProgress =>
      _totalBytes > 0 ? (_bytesStreamed / _totalBytes).clamp(0.0, 1.0) : null;

  @override
  void initState() {
    super.initState();
    _output = StreamController<Uint8List>.broadcast(onListen: _replayBuffer);
    widget.onConnect?.call(_output.stream);
    widget.onOutputPort?.call(_aaOut);
    final savedPath = widget.initialParams?['filePath'];
    if (savedPath != null && savedPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _streamFile(XFile(savedPath));
      });
    }
  }

  void _replayBuffer() {
    if (_buffer.isEmpty) return;
    final pending = List<Uint8List>.of(_buffer);
    scheduleMicrotask(() {
      if (_output.isClosed) return;
      for (final chunk in pending) {
        _output.add(chunk);
      }
    });
  }

  @override
  void dispose() {
    _output.close();
    _aaOut.dispose();
    super.dispose();
  }

  Future<void> _pickAndStream() async {
    final XFile? picked = await openFile();
    if (picked == null) return;
    widget.onParams?.call({'filePath': picked.path});
    widget.onFileName?.call(picked.name);
    await _streamFile(picked);
  }

  Future<void> _streamFile(XFile picked) async {
    setState(() {
      _selectedFile = picked;
      _bytesStreamed = 0;
      _totalBytes = 0;
      _isStreaming = true;
      _allDone = false;
      _errorMessage = null;
      _aa = null;
    });
    _buffer.clear();

    try {
      _totalBytes = await picked.length();
      await for (final chunk in picked.openRead()) {
        if (!mounted) return;
        _buffer.add(chunk);
        _output.add(chunk);
        setState(() => _bytesStreamed += chunk.length);
      }
      if (mounted) {
        setState(() => _allDone = true);
        _detectAndEmitAa();
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '$e');
    } finally {
      if (mounted) setState(() => _isStreaming = false);
    }
  }

  void _detectAndEmitAa() {
    final all = Uint8List.fromList(_buffer.expand((c) => c).toList());
    final aa = LoadFileNode.detectAa(all, _selectedFile?.name);
    if (aa == null) return;
    setState(() => _aa = aa);
    _aaOut.emit(aa);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFile = _selectedFile != null;

    return DoubleNaughtNodeWrapper(
      title: 'Load File',
      icon: Icons.upload_file_outlined,
      outputPorts: [
        OutputConnector(
          label: 'contents',
          idx: 0,
          active: hasFile,
          onTap: _isStreaming ? null : _pickAndStream,
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'aa',
          idx: 1,
          active: _aa != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 28),
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
          _buildStatus(theme),
          if (_aa != null) ...[
            const SizedBox(height: 6),
            _buildAaIndicator(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildAaIndicator(ThemeData theme) {
    final aa = _aa!;
    final rows = aa.distinctRows().length;
    final cols = <String>{...aa.cols}.length;
    return Row(
      children: [
        Icon(Icons.table_chart_outlined,
            size: 14, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'AA · $rows rows × $cols cols on aa',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
      ],
    );
  }

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
          const Icon(Icons.check_circle_outline,
              size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Text('Done',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.green, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('$_bytesStreamed bytes', style: theme.textTheme.bodySmall),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}
