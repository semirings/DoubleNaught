import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/aa_file.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// A workflow source node that opens the local file dialog and streams the
/// chosen file's bytes out of a `contents` connector (idx 0).
///
/// The clickpoint (the node body / "Choose file…" area) calls [openFile] from
/// `file_selector`, which presents the native dialog (and the browser picker on
/// web). The selected [XFile] is read with `openRead()`, producing a
/// `Stream<Uint8List>` that is re-broadcast on the output port so any number of
/// downstream listeners can consume it.
///
/// When the chosen file is a `.json` file that conforms to the rcvs AA schema
/// (`{rows, cols, vals}`), it is *also* parsed and emitted as an [AaPayload] on
/// a second `aa` connector (idx 1), so a downstream Preview (or any AA
/// consumer) can display it as a table rather than raw text. Non-AA files leave
/// that port inert.
///
/// [onConnect] is invoked once with the broadcast byte stream; [onOutputPort]
/// registers the AA egress port with the canvas bus.
class FileSourceNode extends BaseNodeWidget {
  final void Function(Stream<Uint8List> contents)? onConnect;
  final void Function(String fileName)? onFileName;

  const FileSourceNode({
    super.key,
    required super.node,
    this.onConnect,
    this.onFileName,
    super.onOutputPort,
    super.connectedOutputs,
  });

  /// If [bytes] is a `.json` file (by [fileName]) that parses as an rcvs
  /// associative array, returns it normalised to canonical sparse triples;
  /// otherwise null.
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
  State<FileSourceNode> createState() => _FileSourceNodeState();
}

class _FileSourceNodeState extends BaseNodeState<FileSourceNode> {
  @override String   get nodeTitle => 'File Source';
  @override IconData get nodeIcon  => Icons.insert_drive_file_outlined;

  final List<Uint8List> _buffer = [];
  late final StreamController<Uint8List> _output;
  final OutputPort _aaOut = OutputPort('aa');

  AaPayload? _aa;
  XFile?     _selectedFile;
  int        _bytesStreamed = 0;
  int        _totalBytes   = 0;
  bool       _isStreaming  = false;
  bool       _allDone      = false;
  String?    _errorMessage;

  double? get _loadingProgress =>
      _totalBytes > 0 ? (_bytesStreamed / _totalBytes).clamp(0.0, 1.0) : null;

  @override
  void initState() {
    super.initState();
    _output = StreamController<Uint8List>.broadcast(onListen: _replayBuffer);
    widget.onConnect?.call(_output.stream);
    initOutputPort(_aaOut);
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

    widget.onFileName?.call(picked.name);
    setState(() {
      _selectedFile  = picked;
      _bytesStreamed = 0;
      _totalBytes    = 0;
      _isStreaming   = true;
      _allDone       = false;
      _errorMessage  = null;
      _aa            = null;
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
    final aa  = FileSourceNode.detectAa(all, _selectedFile?.name);
    if (aa == null) return;
    setState(() => _aa = aa);
    _aaOut.emit(aa);
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'contents',
          idx: 0,
          active: _selectedFile != null,
          onTap: _isStreaming ? null : _pickAndStream,
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'aa',
          idx: 1,
          active: _aa != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme   = Theme.of(context);
    final hasFile = _selectedFile != null;

    return Column(
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
    );
  }

  Widget _buildAaIndicator(ThemeData theme) {
    final aa   = _aa!;
    final rows = aa.distinctRows().length;
    final cols = <String>{...aa.cols}.length;
    return Row(
      children: [
        Icon(Icons.table_chart_outlined, size: 14, color: theme.colorScheme.primary),
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
