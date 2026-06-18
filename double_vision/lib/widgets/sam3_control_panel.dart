import 'package:flutter/material.dart';

import '../services/sam3_api.dart';

/// The kind of prompt that produced a [Sam3Payload].
enum Sam3PromptKind { text, box, point }

/// Which interaction is currently armed. The workspace viewport reads this to
/// decide whether a click on the image should capture a box or a point (or
/// neither, while the user is typing a text prompt).
enum Sam3InteractionMode { text, box, point }

/// A single result emitted out of the SAM3 node. Carries everything the
/// downstream viewport needs and nothing it doesn't — the panel never renders
/// images itself.
///
///  * [results] — the backend `results` object (image-matrix metadata / masks).
///  * [coordinates] — the geometric prompt: box `[cx,cy,w,h]` or point `[x,y]`.
///  * [include] — include/exclude for box/point prompts.
class Sam3Payload {
  final Sam3PromptKind kind;
  final String? prompt;
  final List<double>? coordinates;
  final bool? include;
  final Map<String, dynamic> results;
  final double? processingTimeMs;

  const Sam3Payload({
    required this.kind,
    required this.results,
    this.prompt,
    this.coordinates,
    this.include,
    this.processingTimeMs,
  });
}

/// Drives box/point submissions from outside the panel. The workspace viewport
/// captures the actual pixel coordinates (the panel renders no image), then
/// hands them back here so the panel fires the matching backend call using its
/// current include/exclude state. Construct one, pass it to
/// [Sam3ControlPanel.controller], and call [submitPoint] / [submitBox].
class Sam3ControlPanelController {
  Sam3ControlPanelState? _state;

  void _attach(Sam3ControlPanelState state) => _state = state;
  void _detach(Sam3ControlPanelState state) {
    if (identical(_state, state)) _state = null;
  }

  /// The interaction the panel currently has armed.
  Sam3InteractionMode get activeSelectionMode =>
      _state?.activeSelectionMode ?? Sam3InteractionMode.text;

  /// Submit a normalized `[x, y]` point captured by the viewport.
  Future<void> submitPoint(List<double> normalizedXy) async =>
      _state?.submitPoint(normalizedXy);

  /// Submit a normalized `[cx, cy, w, h]` box captured by the viewport.
  Future<void> submitBox(List<double> normalizedCxcywh) async =>
      _state?.submitBox(normalizedCxcywh);
}

/// Modular SAM3 control surface, injected into a `DoubleNaughtNodeWrapper`
/// body slot. A **pure controller**: it owns the prompt text, the box/point
/// include-exclude toggles, and triggers the segmentation backend — but it does
/// **not** render segment images. Result payloads are piped out via [onResult]
/// for the workspace viewport to render.
class Sam3ControlPanel extends StatefulWidget {
  /// Backend session id. Backend calls require it; while null the prompt
  /// controls are disabled (no image has been loaded yet).
  final String? sessionId;

  /// Segmentation backend client.
  final Sam3Api api;

  /// Optional external driver for box/point coordinate submission.
  final Sam3ControlPanelController? controller;

  /// Pipes each successful result out of the node.
  final ValueChanged<Sam3Payload>? onResult;

  /// Notifies the workspace which interaction is armed, so its viewport can
  /// route image clicks to box vs point capture.
  final ValueChanged<Sam3InteractionMode>? onInteractionModeChanged;

  /// Surfaces backend/transport errors to the host.
  final ValueChanged<String>? onError;

  const Sam3ControlPanel({
    super.key,
    required this.sessionId,
    this.api = const Sam3Api(),
    this.controller,
    this.onResult,
    this.onInteractionModeChanged,
    this.onError,
  });

  @override
  State<Sam3ControlPanel> createState() => Sam3ControlPanelState();
}

class Sam3ControlPanelState extends State<Sam3ControlPanel> {
  final TextEditingController promptController = TextEditingController();

  /// Which interaction is armed for the viewport.
  Sam3InteractionMode activeSelectionMode = Sam3InteractionMode.text;

  /// Include (true) vs exclude (false) for each geometric prompt kind.
  bool boxSelectionInclude = true;
  bool pointSelectionInclude = true;

  /// Most recent coordinates submitted from the viewport.
  List<double>? currentPointCoordinates;
  List<double>? currentBoxCoordinates;

  bool isSubmitting = false;
  String? lastStatus;

  bool get _backendReady => widget.sessionId != null;
  bool get _canSubmit => _backendReady && !isSubmitting;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(Sam3ControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    promptController.dispose();
    super.dispose();
  }

  void _setInteractionMode(Sam3InteractionMode mode) {
    if (activeSelectionMode == mode) return;
    setState(() => activeSelectionMode = mode);
    widget.onInteractionModeChanged?.call(mode);
  }

  Future<void> _sendTextPrompt() async {
    final prompt = promptController.text.trim();
    if (!_canSubmit || prompt.isEmpty) return;
    _setInteractionMode(Sam3InteractionMode.text);
    await _run(() async {
      final res = await widget.api.segmentWithText(widget.sessionId!, prompt);
      _emit(Sam3Payload(
        kind: Sam3PromptKind.text,
        prompt: prompt,
        results: _resultsOf(res),
        processingTimeMs: _timeOf(res),
      ));
    });
  }

  /// Called by the controller when the viewport captures a point.
  Future<void> submitPoint(List<double> normalizedXy) async {
    if (!_canSubmit) return;
    setState(() => currentPointCoordinates = normalizedXy);
    await _run(() async {
      final res = await widget.api
          .segmentWithPoint(widget.sessionId!, normalizedXy, pointSelectionInclude);
      _emit(Sam3Payload(
        kind: Sam3PromptKind.point,
        coordinates: normalizedXy,
        include: pointSelectionInclude,
        results: _resultsOf(res),
        processingTimeMs: _timeOf(res),
      ));
    });
  }

  /// Called by the controller when the viewport captures a box.
  Future<void> submitBox(List<double> normalizedCxcywh) async {
    if (!_canSubmit) return;
    setState(() => currentBoxCoordinates = normalizedCxcywh);
    await _run(() async {
      final res = await widget.api
          .segmentWithBox(widget.sessionId!, normalizedCxcywh, boxSelectionInclude);
      _emit(Sam3Payload(
        kind: Sam3PromptKind.box,
        coordinates: normalizedCxcywh,
        include: boxSelectionInclude,
        results: _resultsOf(res),
        processingTimeMs: _timeOf(res),
      ));
    });
  }

  Future<void> _run(Future<void> Function() call) async {
    setState(() {
      isSubmitting = true;
      lastStatus = null;
    });
    try {
      await call();
    } catch (e) {
      if (mounted) setState(() => lastStatus = 'Error: $e');
      widget.onError?.call('$e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  void _emit(Sam3Payload payload) {
    widget.onResult?.call(payload);
    if (mounted) {
      setState(() => lastStatus = payload.processingTimeMs == null
          ? 'Done'
          : 'Done in ${payload.processingTimeMs!.toStringAsFixed(0)} ms');
    }
  }

  Map<String, dynamic> _resultsOf(Map<String, dynamic> res) =>
      (res['results'] as Map<String, dynamic>?) ?? const {};
  double? _timeOf(Map<String, dynamic> res) {
    final metrics = res['inferenceMetrics'] as Map<String, dynamic>?;
    return (metrics?['processingTimeMs'] as num?)?.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _textPromptSegment(theme),
        const SizedBox(height: 12),
        _boxPromptSegment(theme),
        const SizedBox(height: 12),
        _pointPromptSegment(theme),
        if (lastStatus != null) ...[
          const SizedBox(height: 8),
          Text(lastStatus!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  // 1) Text Prompt: input + square action submission button.
  Widget _textPromptSegment(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: promptController,
            enabled: _canSubmit,
            onTap: () => _setInteractionMode(Sam3InteractionMode.text),
            onSubmitted: (_) => _sendTextPrompt(),
            decoration: const InputDecoration(
              hintText: 'e.g. "cat", "wheel"',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: _canSubmit ? _sendTextPrompt : null,
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send, size: 18),
        ),
      ],
    );
  }

  // 2) Box Prompts: subtitle + Include/Exclude capsule pill.
  Widget _boxPromptSegment(ThemeData theme) {
    return _geometricSegment(
      theme,
      subtitle: 'Draw boxes to include/exclude regions',
      include: boxSelectionInclude,
      includeIcon: Icons.add_box_outlined,
      excludeIcon: Icons.indeterminate_check_box_outlined,
      onChanged: (include) {
        setState(() => boxSelectionInclude = include);
        _setInteractionMode(Sam3InteractionMode.box);
      },
    );
  }

  // 3) Point Prompts: subtitle + Include/Exclude capsule pill.
  Widget _pointPromptSegment(ThemeData theme) {
    return _geometricSegment(
      theme,
      subtitle: 'Click on the image to select specific points',
      include: pointSelectionInclude,
      includeIcon: Icons.add_circle_outline,
      excludeIcon: Icons.remove_circle_outline,
      onChanged: (include) {
        setState(() => pointSelectionInclude = include);
        _setInteractionMode(Sam3InteractionMode.point);
      },
    );
  }

  Widget _geometricSegment(
    ThemeData theme, {
    required String subtitle,
    required bool include,
    required IconData includeIcon,
    required IconData excludeIcon,
    required ValueChanged<bool> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          subtitle,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: true,
                label: const Text('Include'),
                icon: Icon(includeIcon, size: 16),
              ),
              ButtonSegment(
                value: false,
                label: const Text('Exclude'),
                icon: Icon(excludeIcon, size: 16),
              ),
            ],
            selected: {include},
            onSelectionChanged: (sel) => onChanged(sel.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
              // Capsule pill shape.
              shape: WidgetStatePropertyAll(StadiumBorder()),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}
