import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/load_file_api.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/io_support.dart';
import '../base/output_connector.dart';

/// A workflow source node that loads files from the backend storage directory
/// and auto-detects Associative Arrays based on schema metadata or column patterns.
///
/// Supports `.parquet`, `.arrow`, `.json`, `.csv` (tabular); `.txt`, `.jl`, `.md`
/// (plain text including source code); and image files (`.png`, `.jpg`, `.jpeg`,
/// `.webp`, `.bmp`, `.gif`, `.tif`, `.tiff`). AA detection is handled by the
/// backend `/load` endpoint, which checks for metadata tags, reconstructs native AA
/// objects for structured files, and preserves image bytes as base64 with metadata.
///
/// This is the canonical **root node**: no input ports at all (see
/// `UX_UI/EXECUTION_MODEL.md` §1), so it is always manually triggered via
/// **Execute** rather than reacting to upstream data — there is no Wait
/// checkbox here (see `UX_UI/prompts/load_file_implementation_prompt.md`).
///
/// The URL is typed (or filled in with the **Browse…** button, which opens the
/// native dialog purely to capture a path — the *backend* still does the
/// reading, so this only helps when the backend is local).
///
/// The dialog applies **no type filter**, because an `XTypeGroup` becomes UTI
/// filtering on macOS and greys out extensions the system has no registered type
/// for — `.jl` among them. [allowedExtensions] is the filter instead, checked
/// after selection, and a rejected pick shows an inline badge on the card.
///
/// Emits one output port, `parsedPayload` (idx 0): the AA the backend
/// reconstructed for a tabular file, or the single-cell `text` AA for a
/// source/prose file.
class LoadFileNode extends BaseNodeWidget {
  final void Function(AaPayload aa)? onAaLoaded;

  /// Per-port registration. The canvas keys these by output index so a wire off
  /// `parsedPayload` binds to it and not to whichever port registered last
  /// (see `_aaMultiOutputPorts` in `workflow_page.dart`).
  final void Function(OutputPort port)? onAaOutputPort;

  /// File-dialog seam. Defaults to `file_selector`'s [openFile]; overridden by
  /// tests, which cannot drive a platform dialog.
  final Future<XFile?> Function()? pickFile;

  /// Backend seam; defaults to the local `/load` endpoint. Overridden by tests
  /// with a [LoadFileApi] built from a `MockClient`.
  final LoadFileApi? api;

  const LoadFileNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    this.onAaLoaded,
    this.onAaOutputPort,
    this.pickFile,
    this.api,
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
  /// load. Images (`.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp`, `.gif`, `.tif`,
  /// `.tiff`) are preserved as binary base64 in AA metadata for downstream nodes
  /// like SegForge.
  static const List<String> allowedExtensions = [
    '.jl',
    '.md',
    '.txt',
    '.json',
    '.parquet',
    '.arrow',
    '.csv',
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
    '.gif',
    '.tif',
    '.tiff',
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

class _LoadFileNodeState extends BaseNodeState<LoadFileNode> {
  @override String   get nodeTitle => 'Load File';
  @override IconData get nodeIcon  => Icons.upload_file_outlined;

  final OutputPort _aaOut = OutputPort('parsedPayload');
  late final LoadFileApi _api;

  late TextEditingController _urlController;
  AaPayload? _aa;

  /// File name of a pick rejected by [LoadFileNode.isAllowedPath] — drives the
  /// inline badge. Non-null only between a bad pick and the next good one.
  String? _rejectedFile;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely stop
  /// watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state — this is what makes a stale
  /// result harmless even though the abort itself is synchronous, not
  /// dependent on this check.
  int _execGen = 0;

  bool get _isUrlValid => IOSupport.isValidUrl(_urlController.text);

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const LoadFileApi();
    // The canonical callback keeps `aa` as the node's headline output (that is
    // the port the Focus Panel re-emits an edited AA on); the indexed callbacks
    // below are what wires actually bind to.
    initOutputPort(_aaOut);
    widget.onAaOutputPort?.call(_aaOut);

    // Starts EMPTY per spec — no placeholder/default value baked into a new
    // node (UX_UI/GLOBAL_UX_CONTRACT.md §6). A previously saved node restores
    // its own value, same as any other persisted field.
    _urlController = TextEditingController(
      text: widget.initialParams?['filePath'] ?? '',
    );
    _urlController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _aaOut.dispose();
    _execClient?.close();
    super.dispose();
  }

  /// Open the native dialog to fill in the URL field. The picked path is
  /// absolute; the backend accepts that as readily as a `storage/…` relative
  /// path, but only because it is reading its own filesystem — a remote backend
  /// would not see the file, which is why this is hidden on web.
  Future<void> _onBrowseFilePressed() async {
    final picked = await (widget.pickFile ?? _openNativeDialog)();
    if (picked == null || !mounted) return;

    // Validate here, because the dialog no longer can — see [_openNativeDialog].
    if (!LoadFileNode.isAllowedPath(picked.path)) {
      setState(() => _rejectedFile = picked.name);
      return;
    }

    final pathWithUri = IOSupport.pathToFileUri(picked.path);

    setState(() {
      _urlController.text = pathWithUri;
      _rejectedFile = null;
    });
    setIdle();
    saveParams({'filePath': pathWithUri});
  }

  Future<void> _onBrowseDirectoryPressed() async {
    try {
      final String? selectedDirectory = await getDirectoryPath();
      if (selectedDirectory == null || !mounted) return;

      final uri = IOSupport.pathToFileUri(selectedDirectory);

      setState(() {
        _urlController.text = uri;
        _rejectedFile = null;
      });
      setIdle();
      saveParams({'filePath': uri});
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

  Future<void> _onExecutePressed() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || !_isUrlValid) return;

    final gen = ++_execGen;
    setWorking();

    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api = owns ? LoadFileApi(baseUrl: _api.baseUrl, client: client) : _api;

    try {
      // Schema Mode is gone (removed per the finalized UX spec) — the API
      // client's own default ('auto') is what the backend already treats as
      // its default too, so there is nothing to pass here.
      final response = await api.load(filePath: url);

      if (gen != _execGen || !mounted) return; // cancelled — state is already idle

      // The backend sends an AA for tabular files and for source files alike
      // (a single `text` cell); `contentsToAa` is the fallback for an older
      // backend that returns none, so the port cannot go silent.
      final parsed = response.aa ??
          (response.contents != null
              ? LoadFileNode.contentsToAa({'text': response.contents})
              : LoadFileNode.contentsToAa(response.data));

      setState(() => _aa = parsed);

      if (parsed != null) {
        _aaOut.emit(parsed);
        setComplete(detail: '${response.message} · emitted on aa');
      } else {
        setComplete(detail: '${response.message} · nothing to emit');
      }

      saveParams({'filePath': url});
    } catch (e) {
      if (gen != _execGen || !mounted) return; // discard a cancelled run's error
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard abort:
  /// state flips to idle synchronously, right here, not after any awaited
  /// step notices a flag. `_execGen` guards the in-flight run's own awaits
  /// against then clobbering that idle state if the request still resolves
  /// in the background.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
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
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        IOSupport.field(
          controller: _urlController,
          enabled: !busy,
          // Web has no real paths to hand the backend — the picker there
          // yields a blob URL, so the field is the only way in.
          trailing: kIsWeb
              ? null
              : PopupMenuButton<String>(
                  enabled: !busy,
                  icon: const Icon(Icons.folder_open, size: 18),
                  tooltip: 'Browse…',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
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
        ),
        const SizedBox(height: 12),
        ExecuteButton(
          enabled: _isUrlValid && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : _onExecutePressed,
        ),
        if (_rejectedFile != null) ...[
          const SizedBox(height: 8),
          _buildRejectedBadge(theme),
        ],
        const SizedBox(height: 8),
        statusRow(),
        if (_aa != null) ...[
          const SizedBox(height: 6),
          _buildAaIndicator(theme),
        ],
      ],
    );
  }

  /// Inline badge for a file type this node will not send to the backend.
  ///
  /// Deliberately not an exception and not the status row: the pick failed a
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
}
