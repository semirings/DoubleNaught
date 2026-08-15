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
/// The dialog applies **no type filter**, because an `XTypeGroup` becomes UTI
/// filtering on macOS and greys out extensions the system has no registered type
/// for — `.jl` among them. [allowedExtensions] is the filter instead, checked
/// after selection, and a rejected pick shows an inline badge on the card.
///
/// Emits two output ports:
/// - `contents` (idx 0): the raw file data as an AA-shaped table
/// - `aa` (idx 1): the loaded AA if detected, else nothing
class LoadFileNode extends BaseNodeWidget {
  final void Function(AaPayload aa)? onAaLoaded;

  /// Per-port registration. The canvas keys these by output index so a wire off
  /// `contents` binds to `contents` and not to whichever port registered last
  /// (see `_aaMultiOutputPorts` in `workflow_page.dart`).
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
    this.onAaOutputPort,
    this.pickFile,
    super.onOutputPort,
    super.connectedOutputs,
  });

  /// Extensions the node will accept from the file dialog.
  ///
  /// This is the *whole* filter: the dialog itself no longer restricts anything
  /// (see `_openNativeDialog` for why), so a pick that is not on this list is
  /// reported on the card.
  ///
  /// `.csv` is here because the backend reconstructs an AA from one; `.jl` and
  /// `.md` are here because they are plain text a user may legitimately want to
  /// load — note the backend does not yet route those two anywhere and answers
  /// "Unsupported file format", so they pass selection and fail at Load.
  static const List<String> allowedExtensions = [
    '.jl',
    '.md',
    '.txt',
    '.json',
    '.parquet',
    '.arrow',
    '.csv',
  ];

  /// The lowercase extension of [path] including the dot, or empty when it has
  /// none.
  ///
  /// Only looks at the last segment, so a dot in a *directory* name
  /// (`/tmp/v1.2/model`) is not mistaken for an extension, and a dotfile with no
  /// extension (`.gitignore`) reports empty rather than claiming to be one.
  static String extensionOf(String path) {
    // Both separators by hand rather than `Platform.pathSeparator`: this widget
    // also compiles for web, where `dart:io` does not exist.
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    final name = cut < 0 ? path : path.substring(cut + 1);

    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot).toLowerCase();
  }

  /// Whether [path] is a file type this node will hand to the backend.
  static bool isAllowedPath(String path) =>
      allowedExtensions.contains(extensionOf(path));

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

  final OutputPort _aaOut = OutputPort('parsedPayload');
  final LoadFileApi _api = const LoadFileApi();

  late TextEditingController _filePathController;
  _SchemaMode _schemaMode = _SchemaMode.auto;
  AaPayload? _aa;
  bool _isLoading = false;
  String? _errorMessage;
  String? _statusMessage;

  /// File name of a pick rejected by [LoadFileNode.isAllowedPath] — drives the
  /// inline badge. Non-null only between a bad pick and the next good one.
  String? _rejectedFile;

  @override
  void initState() {
    super.initState();
    // The canonical callback keeps `aa` as the node's headline output (that is
    // the port the Focus Panel re-emits an edited AA on); the indexed callbacks
    // below are what wires actually bind to.
    initOutputPort(_aaOut);
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
    _aaOut.dispose();
    super.dispose();
  }

  /// Open the native dialog to fill in the path field. The picked path is
  /// absolute; the backend accepts that as readily as a `storage/…` relative
  /// path, but only because it is reading its own filesystem — a remote backend
  /// would not see the file, which is why this is hidden on web.
  Future<void> _onBrowseFilePressed() async {
    final picked = await (widget.pickFile ?? _openNativeDialog)();
    if (picked == null || !mounted) return;

    // Validate here, because the dialog no longer can — see [_openNativeDialog].
    if (!LoadFileNode.isAllowedPath(picked.path)) {
      setState(() {
        _rejectedFile = picked.name;
        _statusMessage = null;
        _errorMessage = null;
      });
      return;
    }

    final String pathWithUri;
    if (picked.path.startsWith('file://')) {
      pathWithUri = picked.path;
    } else {
      pathWithUri = Uri.file(picked.path).toString();
    }

    setState(() {
      _filePathController.text = pathWithUri;
      _rejectedFile = null;
      _errorMessage = null;
      _statusMessage = null;
    });
    saveParams({
      'filePath': pathWithUri,
      'schemaMode': _schemaMode.name,
    });
  }

  Future<void> _onBrowseDirectoryPressed() async {
    try {
      final String? selectedDirectory = await getDirectoryPath();
      if (selectedDirectory == null || !mounted) return;

      final String uri;
      if (selectedDirectory.startsWith('file://')) {
        uri = selectedDirectory;
      } else {
        uri = Uri.file(selectedDirectory).toString();
      }

      setState(() {
        _filePathController.text = uri;
        _rejectedFile = null;
        _errorMessage = null;
        _statusMessage = null;
      });
      saveParams({
        'filePath': uri,
        'schemaMode': _schemaMode.name,
      });
    } catch (e) {
      debugPrint("Warning: Directory picking failed: $e");
    }
  }

  /// Open the dialog with **no type filter**.
  ///
  /// An `XTypeGroup(extensions: …)` becomes UTI filtering on macOS, and the panel
  /// greys out any extension the system has no UTI registered for. `.jl` is
  /// exactly that case: a Julia source file is unselectable even when named in
  /// the list, because macOS cannot map the extension to a type it knows.
  ///
  /// So the filter moves into Dart: accept anything from the panel, then check
  /// the extension ourselves against [LoadFileNode.allowedExtensions]. The user
  /// can reach every file they own, and an unsupported pick is reported on the
  /// card rather than silently unselectable.
  static Future<XFile?> _openNativeDialog() => openFile();

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

      // Two ports, two payloads:
      //
      //  * `contents` — the raw file. A text file's own string when the backend
      //    sends one, else the unparsed table view.
      //  * `aa` — the AA data contract. The backend's reconstructed AA for a
      //    tabular file, and for a source file the single-cell `text` AA it now
      //    builds. The `?? contents` fallback keeps this port populated against an
      //    older backend that returns no AA for text.
      //
      // Both are AaPayloads because the info bus carries nothing else; "raw text"
      // on the bus means a 1x1 AA whose one cell is the file.
      // One output: the AA. The backend sends it for tabular files and for source
      // files alike (a single `text` cell); `contentsToAa` is the fallback for an
      // older backend that returns none, so the port cannot go silent.
      final parsed = response.aa ??
          (response.contents != null
              ? LoadFileNode.contentsToAa({'text': response.contents})
              : LoadFileNode.contentsToAa(response.data));
      setState(() {
        _aa = parsed;
        _statusMessage = parsed == null
            ? '${response.message} · nothing to emit'
            : '${response.message} · emitted on aa';
        _errorMessage = null;
      });

      if (parsed != null) {
        _aaOut.emit(parsed);
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
        // Single output at idx 0. `contents` was removed: it duplicated this
        // payload for text files and had no consumer. Workflows saved while it
        // existed wired idx 1, and are migrated on load — see
        // `_migrateLoadFilePorts`.
        OutputConnector(
          label: 'parsedPayload',
          idx: 0,
          active: _aa != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
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
              PopupMenuButton<String>(
                enabled: !_isLoading,
                icon: const Icon(Icons.folder_open, size: 18),
                tooltip: 'Browse…',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onSelected: (mode) {
                  if (mode == 'file') {
                    _onBrowseFilePressed();
                  } else {
                    _onBrowseDirectoryPressed();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'file',
                    child: ListTile(
                      leading: Icon(Icons.insert_drive_file_outlined),
                      title: Text('Select File'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'dir',
                    child: ListTile(
                      leading: Icon(Icons.folder_outlined),
                      title: Text('Select Directory'),
                      dense: true,
                    ),
                  ),
                ],
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
        if (_rejectedFile != null) ...[
          const SizedBox(height: 8),
          _buildRejectedBadge(theme),
        ],
        const SizedBox(height: 8),
        _buildStatus(theme),
        if (_aa != null) ...[
          const SizedBox(height: 6),
          _buildAaIndicator(theme),
        ],
      ],
    );
  }

  /// Inline badge for a file type this node will not send to the backend.
  ///
  /// Deliberately not an exception and not the status line: the pick failed a
  /// local rule, no request was attempted, and the previously chosen path is
  /// untouched — so it reads as a rejected *selection*, not a failed load.
  Widget _buildRejectedBadge(ThemeData theme) {
    final scheme = theme.colorScheme;
    final ext = LoadFileNode.extensionOf(_rejectedFile!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block, size: 14, color: scheme.onErrorContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ext.isEmpty
                      ? 'Unsupported file: $_rejectedFile'
                      : 'Unsupported file type: $ext',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Allowed: ${LoadFileNode.allowedExtensions.join(' ')}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _rejectedFile = null),
            icon: Icon(Icons.close, size: 14, color: scheme.onErrorContainer),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
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
