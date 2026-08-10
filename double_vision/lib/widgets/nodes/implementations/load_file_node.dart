import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/load_file_api.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// A workflow source node that loads files from the backend storage directory
/// and auto-detects Associative Arrays based on schema metadata or column patterns.
///
/// Supports .parquet, .arrow, .json, .csv, .txt files. AA detection is handled
/// by the backend /load endpoint, which checks for metadata tags and reconstructs
/// native AA objects. Non-AA files are returned as raw tables/text.
///
/// The path is typed (or filled in with the **Browse…** button, which opens the
/// native dialog purely to capture a path — the *backend* still does the
/// reading, so this only helps when the backend is local).
///
/// Emits two output ports:
/// - `contents` (idx 0): the raw file data as an AA-shaped table
/// - `aa` (idx 1): the loaded AA if detected, else nothing
class LoadFileNode extends BaseNodeWidget {
  final void Function(AaPayload aa)? onAaLoaded;

  /// Per-port registration. The canvas keys these by output index so a wire off
  /// `contents` binds to `contents` and not to whichever port registered last
  /// (see `_aaMultiOutputPorts` in `workflow_page.dart`).
  final void Function(OutputPort port)? onContentsOutputPort;
  final void Function(OutputPort port)? onAaOutputPort;

  /// File-dialog seam. Defaults to `file_selector`'s [openFile]; overridden by
  /// tests, which cannot drive a platform dialog.
  final Future<XFile?> Function()? pickFile;

  const LoadFileNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    this.onAaLoaded,
    this.onContentsOutputPort,
    this.onAaOutputPort,
    this.pickFile,
    super.onOutputPort,
    super.connectedOutputs,
  });

  /// The backend's raw `data` blob as an [AaPayload], so it can travel on the
  /// info bus — [OutputPort] carries [AaPayload] and nothing else.
  ///
  /// `/load` returns three shapes:
  /// * column-major `{col: [v0, v1, …], …}` — `table.to_pydict()` for
  ///   `.parquet` / `.arrow`, and any list-valued JSON → row index × column name
  /// * `{"rows": [{col: val}, …]}` — `csv.DictReader` → row index × dict keys
  /// * a flat object of scalars (`{"text": "…"}` for `.txt`) → single row `0`
  ///
  /// Non-scalar cells are JSON-encoded, since [AaPayload] values are strings or
  /// numbers. Returns null when there is nothing to emit; an empty payload
  /// would be dropped by `InputPort`'s ingress guard anyway.
  static AaPayload? contentsToAa(Map<String, dynamic> data) {
    if (data.isEmpty) return null;

    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];

    void add(String row, String col, Object? val) {
      if (val == null) return;
      rows.add(row);
      cols.add(col);
      vals.add(val is String || val is num ? val : jsonEncode(val));
    }

    final dictRows = data['rows'];
    if (dictRows is List && dictRows.isNotEmpty && dictRows.first is Map) {
      for (var i = 0; i < dictRows.length; i++) {
        (dictRows[i] as Map).forEach((k, v) => add('$i', '$k', v));
      }
    } else if (data.values.any((v) => v is List)) {
      data.forEach((col, v) {
        if (v is List) {
          for (var i = 0; i < v.length; i++) {
            add('$i', col, v[i]);
          }
        } else {
          add('0', col, v);
        }
      });
    } else {
      data.forEach((k, v) => add('0', k, v));
    }

    return cols.isEmpty ? null : AaPayload(rows: rows, cols: cols, vals: vals);
  }

  @override
  State<LoadFileNode> createState() => _LoadFileNodeState();
}

enum _SchemaMode {
  auto('auto'),
  forceAa('force_aa'),
  rawTable('raw_table');

  const _SchemaMode(this.wire);

  /// What `/load` expects for `schemaMode`. Distinct from [name], which is the
  /// Dart identifier and is what gets persisted in the node's params.
  final String wire;
}

class _LoadFileNodeState extends BaseNodeState<LoadFileNode> {
  @override String   get nodeTitle => 'Load File';
  @override IconData get nodeIcon  => Icons.upload_file_outlined;

  final OutputPort _contentsOut = OutputPort('contents');
  final OutputPort _aaOut = OutputPort('aa');
  final LoadFileApi _api = const LoadFileApi();

  late TextEditingController _filePathController;
  _SchemaMode _schemaMode = _SchemaMode.auto;
  AaPayload? _aa;
  AaPayload? _contents;
  bool _isLoading = false;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    // The canonical callback keeps `aa` as the node's headline output (that is
    // the port the Focus Panel re-emits an edited AA on); the indexed callbacks
    // below are what wires actually bind to.
    initOutputPort(_aaOut);
    widget.onContentsOutputPort?.call(_contentsOut);
    widget.onAaOutputPort?.call(_aaOut);

    _filePathController = TextEditingController(
      text: widget.initialParams?['filePath'] ?? 'storage/out/export.parquet',
    );

    final schemaMode = widget.initialParams?['schemaMode'];
    if (schemaMode != null) {
      try {
        _schemaMode = _SchemaMode.values.byName(schemaMode);
      } catch (_) {
        _schemaMode = _SchemaMode.auto;
      }
    }
  }

  @override
  void dispose() {
    _filePathController.dispose();
    _contentsOut.dispose();
    _aaOut.dispose();
    super.dispose();
  }

  /// Open the native dialog to fill in the path field. The picked path is
  /// absolute; the backend accepts that as readily as a `storage/…` relative
  /// path, but only because it is reading its own filesystem — a remote backend
  /// would not see the file, which is why this is hidden on web.
  Future<void> _onBrowsePressed() async {
    final picked = await (widget.pickFile ?? _openNativeDialog)();
    if (picked == null || !mounted) return;

    setState(() {
      _filePathController.text = picked.path;
      _errorMessage = null;
      _statusMessage = null;
    });
    saveParams({
      'filePath': picked.path,
      'schemaMode': _schemaMode.name,
    });
  }

  static Future<XFile?> _openNativeDialog() => openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Data',
            extensions: ['parquet', 'arrow', 'json', 'csv', 'txt'],
          ),
        ],
      );

  Future<void> _onLoadPressed() async {
    final filePath = _filePathController.text.trim();
    if (filePath.isEmpty) {
      setState(() {
        _errorMessage = 'Error: Enter a file path';
        _statusMessage = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = 'Loading...';
    });

    try {
      final response = await _api.load(
        filePath: filePath,
        schemaMode: _schemaMode.wire,
      );

      if (!mounted) return;

      final contents = LoadFileNode.contentsToAa(response.data);
      setState(() {
        _aa = response.aa;
        _contents = contents;
        _statusMessage = response.message;
        _errorMessage = null;
      });

      // Raw file view on `contents`, plus the reconstructed AA on `aa` when the
      // backend detected one.
      if (contents != null) {
        _contentsOut.emit(contents);
      }
      if (response.aa != null) {
        _aaOut.emit(response.aa!);
      }

      // Save params for persistence.
      saveParams({
        'filePath': filePath,
        'schemaMode': _schemaMode.name,
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: ${e.toString()}';
          _statusMessage = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'contents',
          idx: 0,
          active: _contents != null || widget.connectedOutputs.contains(0),
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
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _filePathController,
                enabled: !_isLoading,
                decoration: const InputDecoration(
                  labelText: 'File Path (backend storage)',
                  hintText: 'storage/out/export.parquet',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
              ),
            ),
            // Web has no real paths to hand the backend — the picker there
            // yields a blob URL, so the field is the only way in.
            if (!kIsWeb) ...[
              const SizedBox(width: 4),
              IconButton(
                onPressed: _isLoading ? null : _onBrowsePressed,
                icon: const Icon(Icons.folder_open, size: 18),
                tooltip: 'Browse…',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        DropdownMenu<_SchemaMode>(
          enableSearch: false,
          label: const Text('Schema Mode'),
          initialSelection: _schemaMode,
          onSelected: (mode) {
            if (mode != null) setState(() => _schemaMode = mode);
          },
          dropdownMenuEntries: const [
            DropdownMenuEntry(
              value: _SchemaMode.auto,
              label: 'Auto-Detect',
            ),
            DropdownMenuEntry(
              value: _SchemaMode.forceAa,
              label: 'Force AA',
            ),
            DropdownMenuEntry(
              value: _SchemaMode.rawTable,
              label: 'Raw Table',
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _onLoadPressed,
            icon: _isLoading
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 16),
            label: Text(_isLoading ? 'Loading...' : 'Load'),
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

  Widget _buildStatus(ThemeData theme) {
    if (_errorMessage != null) {
      return Text(_errorMessage!,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12));
    }
    if (_statusMessage != null) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_statusMessage!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.green),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}
