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
class FileSourceNode extends StatefulWidget {
  /// Graph metadata for this node (id/type/position).
  final WorkflowNode node;

  /// Called once with the node's output stream — the "connector". Downstream
  /// nodes subscribe to this to receive file content chunks.
  final void Function(Stream<Uint8List> contents)? onConnect;

  /// Called with the chosen file's name (out-of-band metadata; the byte stream
  /// carries no filename). Lets a downstream Preview label the content.
  final void Function(String fileName)? onFileName;

  /// Registers this node's AA egress OutputPort (`aa`, idx 1) with the canvas
  /// bridge, so a wired AA edge binds to it.
  final void Function(OutputPort port)? onOutputPort;

  /// Output port indices with an outgoing edge — drives the connected-port
  /// highlight, matching every other node.
  final Set<int> connectedOutputs;

  const FileSourceNode({
    super.key,
    required this.node,
    this.onConnect,
    this.onFileName,
    this.onOutputPort,
    this.connectedOutputs = const {},
  });

  /// If [bytes] is a `.json` file (by [fileName]) that parses as an rcvs
  /// associative array, returns it normalised to canonical sparse triples;
  /// otherwise null. A dense (`rows × cols` matrix) file is expanded via
  /// [AaPayload.toSparse]. Pure + static so it is unit-testable.
  static AaPayload? detectAa(Uint8List bytes, String? fileName) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.json')) {
      return null;
    }
    try {
      final aa = AaFile.decode(jsonDecode(utf8.decode(bytes))).toSparse();
      return aa.cols.isNotEmpty ? aa : null;
    } catch (_) {
      return null; // not JSON / not an AA — stays a plain byte source
    }
  }

  @override
  State<FileSourceNode> createState() => _FileSourceNodeState();
}

class _FileSourceNodeState extends State<FileSourceNode> {
  /// Every chunk streamed so far. Broadcast streams don't retain past events,
  /// so this buffer lets a downstream node that connects *after* the file has
  /// loaded still receive the full contents (replayed by [_output]'s onListen).
  final List<Uint8List> _buffer = [];

  /// Broadcast output port. Created in [initState] so [onConnect] can hand it
  /// to downstream nodes before any file is chosen; its onListen replays
  /// [_buffer] to late subscribers.
  late final StreamController<Uint8List> _output;

  /// AA egress port (`aa`, idx 1). Retains the last payload, so a Preview wired
  /// up after the file loaded still receives it (see [OutputPort]).
  final OutputPort _aaOut = OutputPort('aa');

  /// The AA parsed from the chosen file when it is rcvs JSON, else null.
  AaPayload? _aa;

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
    _output = StreamController<Uint8List>.broadcast(onListen: _replayBuffer);
    // Publish the output connectors immediately, before any file is chosen.
    widget.onConnect?.call(_output.stream);
    widget.onOutputPort?.call(_aaOut);
  }

  /// When a downstream node subscribes, replay whatever has already been loaded.
  /// Without this, a Preview connected after the file finished streaming would
  /// receive 0 bytes (broadcast streams don't retain past events).
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

  /// Clickpoint handler: open the native local-storage dialog, then stream the
  /// chosen file's raw bytes out of the output port, advancing
  /// [_loadingProgress] until the read finishes and [_allDone] is set.
  Future<void> _pickAndStream() async {
    final XFile? picked = await openFile();
    if (picked == null) return; // user cancelled

    widget.onFileName?.call(picked.name);
    setState(() {
      _selectedFile = picked;
      _bytesStreamed = 0;
      _totalBytes = 0;
      _isStreaming = true;
      _allDone = false;
      _errorMessage = null;
      _aa = null; // a prior file's AA no longer applies
    });
    _buffer.clear(); // dropping a prior file's bytes from the replay buffer

    try {
      _totalBytes = await picked.length();
      await for (final chunk in picked.openRead()) {
        if (!mounted) return;
        _buffer.add(chunk); // retain for replay to late subscribers
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

  /// After the full file has buffered, parse it as an rcvs AA (when it's JSON)
  /// and emit it on the `aa` port so AA consumers can display it as a table.
  void _detectAndEmitAa() {
    final all = Uint8List.fromList(_buffer.expand((c) => c).toList());
    final aa = FileSourceNode.detectAa(all, _selectedFile?.name);
    if (aa == null) return;
    setState(() => _aa = aa);
    _aaOut.emit(aa);
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
        OutputConnector(
          label: 'aa',
          idx: 1,
          // Live only when the chosen file parsed as an rcvs AA.
          active: _aa != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Clear the two edge-anchored output labels (`contents` idx 0,
          // `aa` idx 1) before the body controls begin.
          const SizedBox(height: 28),
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

          // rcvs-AA detection: surface that the `aa` port is live.
          if (_aa != null) ...[
            const SizedBox(height: 6),
            _buildAaIndicator(theme),
          ],
        ],
      ),
    );
  }

  /// One-line note that the chosen file parsed as an AA and is being emitted on
  /// the `aa` port (rows × cols).
  Widget _buildAaIndicator(ThemeData theme) {
    final aa = _aa!;
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
