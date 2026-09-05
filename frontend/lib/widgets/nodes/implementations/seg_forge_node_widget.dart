import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Process;
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
import '../base/input_connector.dart';
import '../base/io_support.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';
import '../../../models/workflow.dart' show PortRef;

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

  /// Crop seam; defaults to [cropPng].
  ///
  /// Injectable because rasterizing through `dart:ui` inside `testWidgets`
  /// does not complete — the test zone never produces a frame for it — so
  /// widget tests substitute a synchronous stand-in.
  final Future<Uint8List?> Function(Uint8List bytes, ui.Rect rect)? cropper;

  /// Called when an edge is dropped on `session`.
  final void Function(PortRef source)? onSessionConnect;

  /// Registers the `session` port.
  final void Function(InputPort port)? onSessionInputPort;

  /// Whether `session` has an incoming edge.
  final bool sessionConnected;

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
    this.cropper,
    this.onSessionConnect,
    this.onSessionInputPort,
    this.sessionConnected = false,
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

  late final SegForgeApi _api;
  late final SegForgeLauncher _launcher;
  late final Future<Uint8List?> Function(Uint8List, ui.Rect) _cropper;

  late final InputPort _imageIn;
  late final InputPort _sessionIn;
  final OutputPort _segmentOut = OutputPort('segment');
  final OutputPort _linkageOut = OutputPort('linkage');

  final TextEditingController _appPath = TextEditingController();

  Uint8List? _imageBytes;
  String? _imageFilename;
  String? _sessionId;

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

    _appPath.text = widget.initialParams?['appPath'] ?? '';
    // Persist the path and re-evaluate Open Forge's enablement as it is typed.
    _appPath.addListener(_onAppPathChanged);

    // Only the canonical port goes through initInputPort — it always calls the
    // single widget.onInputPort callback, so `session` registers via its own.
    _imageIn = InputPort('image');
    initInputPort(_imageIn, _onImage);
    _imageIn.onDisconnected.listen((_) => _dropImage());

    _sessionIn = InputPort('session', isRequired: false);
    widget.onSessionInputPort?.call(_sessionIn);
    _sessionIn.onDataArrived.listen(_onSession);
    _sessionIn.onDisconnected.listen((_) => _dropSession());

    initOutputPort(_segmentOut);
    widget.onIndexedOutputPort?.call(0, _segmentOut);
    widget.onIndexedOutputPort?.call(1, _linkageOut);
  }

  void _onAppPathChanged() {
    if (!mounted) return;
    saveParams({'appPath': _appPath.text.trim()});
    setState(() {});
  }

  @override
  void dispose() {
    _appPath.removeListener(_onAppPathChanged);
    _imageIn.dispose();
    _sessionIn.dispose();
    _segmentOut.dispose();
    _linkageOut.dispose();
    _appPath.dispose();
    super.dispose();
  }

  // ── Ingress ───────────────────────────────────────────────────────────────

  Future<void> _onImage(AaPayload aa) async {
    final bytes = await _resolveImageBytes(aa);
    if (!mounted) return;
    setState(() {
      _imageBytes = bytes;
      _imageFilename = aa.value('filename') ??
          aa.value('path') ??
          aa.value('url') ??
          _imageFilename;
    });
    maybeAutoFire();
  }

  /// Turns an incoming AA into image bytes.
  ///
  /// `AaPayload.vals` holds only strings and ints, so raw bytes cannot ride in
  /// one directly — a `bytes` column carries base64. A `path`/`url` column is
  /// also accepted because upstream file nodes emit locations, not blobs.
  Future<Uint8List?> _resolveImageBytes(AaPayload aa) async {
    final b64 = aa.value('bytes');
    if (b64 != null && b64.isNotEmpty) {
      try {
        return base64Decode(b64);
      } catch (_) {
        setError('image: `bytes` column is not valid base64');
        return null;
      }
    }

    final location = aa.value('path') ?? aa.value('url');
    if (location == null || location.isEmpty) {
      setError('image: expected a `bytes`, `path` or `url` column');
      return null;
    }

    try {
      final uri = Uri.tryParse(location);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        return await _api.fetchBytes(location);
      }
      final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : location;
      return await File(path).readAsBytes();
    } catch (e) {
      setError(e);
      return null;
    }
  }

  void _onSession(AaPayload aa) {
    if (!mounted) return;
    setState(() => _sessionId = aa.value('session_id') ??
        (aa.vals.isNotEmpty ? aa.vals.first.toString() : null));
    maybeAutoFire();
  }

  void _dropImage() {
    if (!mounted || _imageBytes == null) return;
    setState(() {
      _imageBytes = null;
      _imageFilename = null;
    });
    setIdle();
  }

  void _dropSession() {
    if (!mounted || _sessionId == null) return;
    setState(() => _sessionId = null);
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

  // ── Open Forge ────────────────────────────────────────────────────────────

  bool get _canOpenForge =>
      _imageBytes != null &&
      _appPath.text.trim().isNotEmpty &&
      status != NodeStatus.working;

  Future<void> _onOpenForge() async {
    if (!_canOpenForge) return;
    final gen = ++_execGen;
    final bytes = _imageBytes!;
    final filename = _basename(_imageFilename) ?? 'image.png';

    setWorking();
    setState(() {
      _segmentAa = null;
      _linkageAa = null;
      _summaryText = null;
    });

    try {
      // 1. Register the image server-side. This both creates the session and
      //    makes the image fetchable over SegForge's /storage mount, which is
      //    how a byte[] input becomes the URL the app takes at launch.
      final upload = await _api.uploadImage(
        bytes,
        filename: filename,
        sessionId: _sessionId,
      );
      if (gen != _execGen || !mounted) return;

      final sessionId = upload.sessionId;

      // 2. Launch the app and wait for its window to close.
      final process = await _launcher(
        executable: _appPath.text.trim(),
        environment: {
          'SEGFORGE_SESSION_ID': sessionId,
          'SEGFORGE_IMAGE_URL': _api.originalImageUrl(sessionId),
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

      // 3. Read back what the session ended up holding.
      await _collect(sessionId, filename, gen);
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
        InputConnector(
          label: 'session',
          idx: 1,
          active: widget.sessionConnected,
          onConnect: widget.onSessionConnect,
        ),
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
        SizedBox(height: BaseNodeState.portLaneClearance(2)),
        Text(
          'SegForge app',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        IOSupport.field(controller: _appPath, enabled: !busy),
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
