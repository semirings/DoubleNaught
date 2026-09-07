import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Process, ProcessStartMode;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../services/image_crop.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/seg_forge_api.dart';
import '../../../services/seg_forge_mapping.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// A launched SegForge process, reduced to what the node needs to await it.
///
/// Exists so tests can stand in for a real GUI launch: the node never calls
/// `Process.start` directly, it calls a [SegForgeLauncher].
abstract class SegForgeProcess {
  /// Completes with the process's exit code once its window closes.
  Future<int> get exitCode;

  /// Terminate the app because the user pressed Cancel.
  void kill();
}

/// Launches the SegForge app with per-launch inputs in its environment.
///
/// The environment is the mechanism rather than `--dart-define`, because
/// dart-defines are compile-time constants baked into the bundle and cannot
/// vary per launch. SegForge's `LaunchConfig` reads the environment first for
/// exactly this reason.
typedef SegForgeLauncher = Future<SegForgeProcess> Function({
  required String executable,
  required Map<String, String> environment,
});

/// Default launcher: a real OS process.
Future<SegForgeProcess> launchSegForgeProcess({
  required String executable,
  required Map<String, String> environment,
}) async {
  // argv list, never a shell string — same convention as the only other
  // process launch in this app (`encrypted_file_vault_store._restrictPermissions`).
  final process = await Process.start(
    executable,
    const <String>[],
    environment: environment,
  );
  return _RealSegForgeProcess(process);
}

class _RealSegForgeProcess implements SegForgeProcess {
  final Process _process;
  _RealSegForgeProcess(this._process);

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// An image resolved to whichever form SegForge can actually consume.
///
/// Exactly one of [url] and [bytes] is set. [url] means SegForge can fetch it
/// unaided; [bytes] means the node has to upload them first to give the image
/// an address.
class _ImageSource {
  final String? url;
  final Uint8List? bytes;
  final String filename;

  const _ImageSource.url(String this.url, {required String? filename})
      : bytes = null,
        filename = filename ?? 'image.png';

  const _ImageSource.bytes(Uint8List this.bytes, {required this.filename})
      : url = null;
}

/// **Seg Forge** — hands an image to the SegForge segmentation app, waits for
/// the user to finish in it, and turns what they produced into two AAs.
///
/// ## Ports
///
/// * `image` (input, idx 0) — the image to segment. Accepts a `bytes` column
///   holding base64, or a `path`/`url` column; an optional `filename` column
///   sets the `image_id` used in row keys.
/// * `session` (input, idx 1, optional) — a `session_id` to work in. When
///   absent, SegForge's backend allocates one on upload.
/// * `segment` (output, idx 0) — one row per segment,
///   `session_id:image_id:segment_id`, columns `crop_bytes`, `mask_bytes`,
///   `bbox`.
/// * `linkage` (output, idx 1) — prompts and confidences against their target,
///   `session_id:target_id`.
///
/// ## Two buttons, two jobs
///
/// **Open Forge** uploads the image to SegForge's backend, launches the app
/// pointed at that session, waits for the window to close, then reads the
/// results back over HTTP and holds them. **Execute** is the ordinary node
/// Execute: it forwards whatever is currently held on the two outputs. So a
/// forge run can be reviewed before it is released downstream, and the same
/// results can be re-emitted without reopening the app.
///
/// With Wait unchecked the node is reactive in the usual way — results landing
/// after the app closes fire it immediately.
class SegForgeNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to SegForge's own service on 8401.
  final SegForgeApi? api;

  /// Process seam; defaults to [launchSegForgeProcess].
  final SegForgeLauncher? launcher;

  /// App-path seam; defaults to the canonical SegForge build path.
  /// Injectable for tests so they don't depend on a real on-disk bundle.
  final String? appPathOverride;

  /// Crop seam; defaults to [cropPng].
  ///
  /// Injectable because rasterizing through `dart:ui` inside `testWidgets`
  /// does not complete — the test zone never produces a frame for it — so
  /// widget tests substitute a synchronous stand-in.
  final Future<Uint8List?> Function(Uint8List bytes, ui.Rect rect)? cropper;

  /// Registers an output port by index (0 = `segment`, 1 = `linkage`).
  final void Function(int idx, OutputPort port)? onIndexedOutputPort;

  const SegForgeNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.api,
    this.launcher,
    this.appPathOverride,
    this.cropper,
    this.onIndexedOutputPort,
  });

  @override
  State<SegForgeNodeWidget> createState() => _SegForgeNodeWidgetState();
}

class _SegForgeNodeWidgetState extends BaseNodeState<SegForgeNodeWidget>
    with WaitGatedExecution<SegForgeNodeWidget> {
  @override
  String get nodeTitle => 'Seg Forge';
  @override
  IconData get nodeIcon => Icons.auto_awesome_mosaic_outlined;
  @override
  double get nodeWidth => 320;
  @override
  String get workingLabel => 'forging';

  /// Path to SegForge frontend app. Located at sibling SegForge repo.
  static const String _segForgeAppPath =
      '/Users/gcr/populi.Wk/SegForge/frontend/build/macos/Build/Products/Debug/frontend.app/Contents/MacOS/frontend';

  late final SegForgeApi _api;
  late final SegForgeLauncher _launcher;
  late final Future<Uint8List?> Function(Uint8List, ui.Rect) _cropper;

  late final InputPort _imageIn;
  final OutputPort _segmentOut = OutputPort('segment');
  final OutputPort _linkageOut = OutputPort('linkage');

  /// Set from the `image` port. When null the port is the only way to provide
  /// an image — there is no manual field anymore.
  _ImageSource? _portImage;

  /// All available SegForge sessions (from backend, plus any created this session).
  List<Map<String, dynamic>> _sessionsList = [];

  /// Currently selected session ID from the picklist.
  String? _selectedSessionId;

  AaPayload? _segmentAa;
  AaPayload? _linkageAa;
  String? _summaryText;

  /// Non-null only while the app is open, so Cancel can terminate it.
  SegForgeProcess? _running;

  /// Bumped on cancel so a late continuation abandons itself, matching the
  /// hard-abort convention the other async nodes use.
  int _execGen = 0;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const SegForgeApi();
    _launcher = widget.launcher ?? launchSegForgeProcess;
    _cropper = widget.cropper ?? cropPng;

    // Only the canonical port goes through initInputPort — it always calls the
    // single widget.onInputPort callback.
    _imageIn = InputPort('image');
    initInputPort(_imageIn, _onImage);
    _imageIn.onDisconnected.listen((_) => _dropImage());

    initOutputPort(_segmentOut);
    widget.onIndexedOutputPort?.call(0, _segmentOut);
    widget.onIndexedOutputPort?.call(1, _linkageOut);

    // Load available sessions from backend and select the first one by default.
    _loadSessions();
  }

  @override
  void dispose() {
    _imageIn.dispose();
    _segmentOut.dispose();
    _linkageOut.dispose();
    super.dispose();
  }

  // ── Ingress ───────────────────────────────────────────────────────────────

  Future<void> _onImage(AaPayload aa) async {
    final source = await _resolveFromAa(aa);
    if (!mounted) return;
    setState(() => _portImage = source);
    maybeAutoFire();
  }

  /// Reads an image location or blob out of an incoming AA.
  ///
  /// `AaPayload.vals` holds only strings and ints, so raw bytes cannot ride in
  /// one directly — a `bytes` column carries base64. `url` and `path` are also
  /// accepted, because upstream nodes emit locations rather than blobs (the
  /// Inventory node's `entry` payload carries `url`, for one).
  Future<_ImageSource?> _resolveFromAa(AaPayload aa) async {
    final b64 = aa.value('bytes');
    if (b64 != null && b64.isNotEmpty) {
      try {
        return _ImageSource.bytes(
          base64Decode(b64),
          filename: aa.value('filename') ?? 'image.png',
        );
      } catch (_) {
        setError('image: `bytes` column is not valid base64');
        return null;
      }
    }

    final location = aa.value('url') ?? aa.value('path');
    if (location == null || location.isEmpty) {
      setError('image: expected a `bytes`, `url` or `path` column');
      return null;
    }
    return _resolveLocation(location, aa.value('filename'));
  }

  /// Classifies a location into something SegForge can fetch, or bytes to
  /// upload on its behalf.
  ///
  /// An http(s) URL is passed straight through: SegForge downloads it itself,
  /// so re-fetching and re-uploading here would move the image three times
  /// instead of once. A local path has to be read and uploaded, because
  /// `package:http` cannot fetch `file://` and SegForge would have no way to
  /// reach it.
  Future<_ImageSource?> _resolveLocation(String location, String? filename) async {
    final uri = Uri.tryParse(location);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _ImageSource.url(location, filename: filename ?? _basename(location));
    }
    try {
      final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : location;
      return _ImageSource.bytes(
        await File(path).readAsBytes(),
        filename: filename ?? _basename(path) ?? 'image.png',
      );
    } catch (e) {
      setError(e);
      return null;
    }
  }

  void _dropImage() {
    if (!mounted || _portImage == null) return;
    setState(() => _portImage = null);
    setIdle();
  }

  // ── Wait / Execute ────────────────────────────────────────────────────────

  /// Execute forwards what is held, so readiness means "there is something to
  /// forward" — not "an image has arrived", which is Open Forge's condition.
  @override
  bool get isReady => _segmentAa != null || _linkageAa != null;

  @override
  void fire() {
    final segment = _segmentAa;
    final linkage = _linkageAa;

    // An empty AA is dropped by InputPort's ingress guard anyway, so emitting
    // one would be a silent no-op rather than a signal.
    if (segment != null && segment.cols.isNotEmpty) _segmentOut.emit(segment);
    if (linkage != null && linkage.cols.isNotEmpty) _linkageOut.emit(linkage);

    setComplete(detail: _summaryText ?? 'forwarded');
  }

  // ── Sessions ──────────────────────────────────────────────────────────────

  /// Loads the list of saved SegForge sessions from the backend.
  /// Loads saved sessions from backend Parquet storage.
  Future<void> _loadSessions() async {
    try {
      final sessions = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _sessionsList = sessions;
        _selectedSessionId = sessions.isNotEmpty ? sessions[0]['session_id'] as String : null;
      });
    } catch (e) {
      debugPrint('Warning: Failed to load sessions from backend: $e');
      // Continue with empty list if load fails.
    }
  }

  /// Time-ordered session ID (matches DN's existing pattern).
  static String _newSessionId() {
    final now = DateTime.now();
    return 'session-${now.microsecondsSinceEpoch.toRadixString(36)}'
        '-${now.hashCode.toRadixString(36)}';
  }

  /// Prompts user for session name/description and creates a new session.
  Future<void> _createNewSession() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New SegForge Session'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Session Name',
                  hintText: 'e.g., "Slide Analysis"',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g., "Segmenting presentation slides"',
                ),
                maxLines: null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != true || !mounted) return;

    // Generate ID for the new session. It will be persisted to Parquet only after
    // SegForge runs and produces results (in _collect).
    final sessionId = _newSessionId();
    final now = DateTime.now();
    final newSession = {
      'session_id': sessionId,
      'name': nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : 'Session ${now.toString().substring(0, 10)}',
      'description': descCtrl.text.trim(),
      'created_at': now.toIso8601String(),
      'image_url': '',
    };

    setState(() {
      _sessionsList.insert(0, newSession);
      _selectedSessionId = sessionId;
    });
    nameCtrl.dispose();
    descCtrl.dispose();
  }

  // ── Backend Management ────────────────────────────────────────────────────────

  static const String _sfBackendDir =
      '/Users/gcr/populi.Wk/SegForge/backend';
  static const String _sfUvicorn =
      '/Users/gcr/populi.Wk/SegForge/.venv/bin/uvicorn';

  /// Ensures the SF backend is healthy, auto-launching it if necessary.
  ///
  /// First does a quick health check. If unhealthy, spawns uvicorn in the
  /// background and polls until it responds (up to ~20 s). Throws if the
  /// backend cannot be reached after launch.
  Future<void> _ensureBackendHealthy(int gen) async {
    // Fast path: already up.
    try {
      if (await _api.healthCheck()) return;
    } catch (_) {}

    if (gen != _execGen || !mounted) return;

    // Not running — launch it in the background.
    await Process.start(
      _sfUvicorn,
      ['main:app', '--host', '127.0.0.1', '--port', '8401'],
      workingDirectory: _sfBackendDir,
      mode: ProcessStartMode.detachedWithStdio,
    );

    // Poll until healthy (10 × 2 s = 20 s max).
    for (var attempt = 0; attempt < 10; attempt++) {
      if (gen != _execGen || !mounted) return;
      await Future.delayed(const Duration(seconds: 2));
      try {
        if (await _api.healthCheck()) return;
      } catch (_) {}
    }

    throw Exception(
      'SegForge backend did not become healthy at ${_api.baseUrl} after launch.',
    );
  }

  // ── Open Forge ────────────────────────────────────────────────────────────

  bool get _canOpenForge =>
      _portImage != null &&
      _selectedSessionId != null &&
      status != NodeStatus.working;

  Future<void> _onOpenForge() async {
    if (!_canOpenForge) return;
    final gen = ++_execGen;

    setWorking();
    setState(() {
      _segmentAa = null;
      _linkageAa = null;
      _summaryText = null;
    });

    try {
      // Ensure SF backend is healthy; launch if necessary.
      await _ensureBackendHealthy(gen);
      if (gen != _execGen || !mounted) return;

      // Image comes only from the input port; the manual field is gone.
      final source = _portImage;
      if (source == null) return; // Should not happen due to _canOpenForge check.

      final String sessionId = _selectedSessionId!;
      final String imageUrl;
      if (source.url != null) {
        // SegForge fetches the URL itself and uploads into the selected session.
        imageUrl = source.url!;
      } else {
        // No URL exists for these bytes, so upload them to the selected session.
        await _api.uploadImage(
          source.bytes!,
          filename: source.filename,
          sessionId: sessionId,
        );
        imageUrl = _api.originalImageUrl(sessionId);
      }
      if (gen != _execGen || !mounted) return;

      // Initialize the session on the backend with metadata. The backend stores
      // this so SF frontend can fetch it via /getSession/{id}.
      await _api.initSession(
        sessionId: sessionId,
        name: 'Session $sessionId',
        description: source.filename,
        imageUrl: imageUrl,
      );
      if (gen != _execGen || !mounted) return;

      // Now launch SF frontend. It will read initialization from backend.
      final process = await _launcher(
        executable: widget.appPathOverride ?? _segForgeAppPath,
        environment: {
          'SEGFORGE_SESSION_ID': sessionId,
          'SEGFORGE_IMAGE_URL': imageUrl,
          'SEGFORGE_BACKEND_URL': _api.baseUrl,
        },
      );
      if (gen != _execGen || !mounted) {
        process.kill();
        return;
      }
      setState(() => _running = process);

      await process.exitCode;
      if (gen != _execGen || !mounted) return;
      setState(() => _running = null);

      await _collect(sessionId, source.filename, gen);
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setState(() => _running = null);
      setError(e);
    }
  }

  /// Pulls a finished session's results and maps them onto the two outputs.
  Future<void> _collect(String sessionId, String filename, int gen) async {
    final session = await _api.loadSession(sessionId);
    if (gen != _execGen || !mounted) return;

    if (session.isEmpty) {
      // Closing the app without ever running an inference is an ordinary
      // outcome, not a crash. Say so and emit nothing, matching how the other
      // nodes report a run that produced no rows.
      setState(() {
        _segmentAa = null;
        _linkageAa = null;
        _summaryText = null;
      });
      setError('SegForge closed without producing a segmentation');
      return;
    }

    // Persist the session to DN's Parquet store for later replay/inspection.
    try {
      await _api.saveSession({
        'session_id': session.sessionId,
        'created_at': session.createdAt,
        'name': session.sessionId,
        'description': filename,
        'image_url': '',
        'width': session.width,
        'height': session.height,
        'prompts': session.prompts,
        'results': {
          'boxes': session.boxes,
          'scores': session.scores,
          'masks': session.masksRle,
        },
      });
    } catch (e) {
      // Save failure is a warning, not a fatal error; continue with results.
      debugPrint('Warning: Failed to persist session $sessionId: $e');
    }
    if (gen != _execGen || !mounted) return;

    // Ask SegForge to materialize the mask and cutout PNGs. Its UI no longer
    // drives either, so the node does — otherwise mask_bytes would exist only
    // when the user happened to press Save, and crop_bytes never.
    await _api.saveMasks(sessionId);
    if (gen != _execGen || !mounted) return;
    await _api.createSegments(sessionId);
    if (gen != _execGen || !mounted) return;

    final count = session.segmentCount;
    final crops = <Uint8List?>[];
    final masks = <Uint8List?>[];

    final cutoutUrls = await _api.showSegments(sessionId);
    if (gen != _execGen || !mounted) return;

    for (var i = 0; i < count; i++) {
      // Cutouts are full-canvas with transparency outside the mask, so crop to
      // the segment's own box to get an actual sub-image.
      Uint8List? crop;
      if (i < cutoutUrls.length && i < session.boxes.length) {
        final full = await _api.fetchBytes(cutoutUrls[i]);
        if (gen != _execGen || !mounted) return;
        final b = session.boxes[i];
        crop = await _cropper(full, ui.Rect.fromLTRB(b[0], b[1], b[2], b[3]));
        if (gen != _execGen || !mounted) return;
      }
      crops.add(crop);

      try {
        masks.add(await _api.fetchBytes(_api.maskUrl(sessionId, i)));
      } catch (_) {
        masks.add(null); // Missing mask is an omitted cell, not a failure.
      }
      if (gen != _execGen || !mounted) return;
    }

    final imageId = SegForgeMapping.imageIdFor(filename);
    final segmentAa = SegForgeMapping.segments(
      session,
      imageId: imageId,
      crops: crops,
      masks: masks,
    );
    final linkageAa = SegForgeMapping.linkage(session, imageId: imageId);

    setState(() {
      _segmentAa = segmentAa;
      _linkageAa = linkageAa;
      _summaryText = '$count segment${count == 1 ? '' : 's'} · '
          '${session.prompts.length} prompt${session.prompts.length == 1 ? '' : 's'}';
    });
    setComplete(detail: _summaryText);
    maybeAutoFire();
  }

  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _running?.kill();
    _running = null;
    setIdle();
  }

  static String? _basename(String? path) {
    if (path == null || path.isEmpty) return null;
    final cut = path.lastIndexOf('/') > path.lastIndexOf('\\')
        ? path.lastIndexOf('/')
        : path.lastIndexOf('\\');
    return cut >= 0 ? path.substring(cut + 1) : path;
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'image'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'segment',
          idx: 0,
          hasData: (_segmentAa?.cols.isNotEmpty ?? false),
        ),
        singleOutputConnector(
          label: 'linkage',
          idx: 1,
          hasData: (_linkageAa?.cols.isNotEmpty ?? false),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        Text(
          'Session',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: scheme.outlineVariant,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        value: _selectedSessionId,
                        isDense: true,
                        isExpanded: true,
                        underline: const SizedBox(), // Remove default underline
                        items: _sessionsList.isEmpty
                            ? [
                                DropdownMenuItem(
                                  enabled: false,
                                  child: Text(
                                    'No sessions',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ]
                            : [
                                ..._sessionsList.map((s) {
                                  final id = s['session_id'] as String;
                                  final name = (s['name'] as String?) ?? id;
                                  return DropdownMenuItem(
                                    value: id,
                                    child: Text(
                                      name.length > 30 ? '${name.substring(0, 27)}...' : name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }),
                              ],
                        onChanged: busy || _sessionsList.isEmpty
                            ? null
                            : (v) {
                                if (v != null) {
                                  setState(() => _selectedSessionId = v);
                                }
                              },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              height: 40,
              width: 40,
              child: IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Create new session',
                onPressed: busy ? null : _createNewSession,
                style: IconButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  side: BorderSide(
                    color: scheme.outlineVariant,
                    width: 1,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 30,
          child: OutlinedButton.icon(
            onPressed: _canOpenForge ? _onOpenForge : null,
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open Forge'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: theme.textTheme.labelSmall,
            ),
          ),
        ),
        const SizedBox(height: 8),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }
}
