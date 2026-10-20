import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/generate_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';
import '../base/wait_gated_execution.dart';
import 'vlm_trainer_node_widget.dart' show firstValue;

/// Text (and optionally image) to image with Qwen-Image-2.1, run by mflux on
/// the backend's Mac.
///
/// Inputs: `model` (idx 0, optional) — a Load Model row, its `pathOrUrl`
/// picks the model (empty = Qwen-Image-2.1); `lora` (idx 1, optional) — a row
/// with `path` to an image-model LoRA `.safetensors` (strength below);
/// `image` (idx 2, optional) — a row with `image_b64` (or `bytes`, which is what
/// Load File emits for a picture) as the starting image;
/// `prompt` (idx 3, optional) — a row with `text` (Load File on a .txt) or
/// `prompt`, which replaces the Prompt field.
///
/// Model family: **Qwen-Image-2.1** or **Z-Image-Turbo**. A LoRA only works on
/// the family it was trained for, so a wired LoRA row's `family` column (the
/// Image LoRA Trainer writes `z-image`) decides it; with none, the selector does.
/// Switching family also swaps the default step count (40 for Qwen, 9 for the
/// distilled Z-Image-Turbo) unless the field was changed by hand. Z-Image has
/// no Edit mode.
///
/// Mode, when a start image is wired: **Img2img** repaints the picture (Image
/// strength: higher keeps more of it) and **Edit** treats the prompt as an
/// instruction about it (Edit strength: 1 = full edit, lower = subtler).
/// Output `image` (idx 0): one `image` row with `image_b64` and `path`.
///
/// Execute-only: a generation takes a minute or more. The model recommends 40
/// steps; fewer is quicker and rougher.
class ImageGenNodeWidget extends BaseNodeWidget {
  final GenerateApi? api;
  final Duration poll;

  final bool modelConnected;
  final void Function(PortRef source)? onModelConnect;
  final void Function(InputPort port)? onModelInputPort;
  final bool loraConnected;
  final void Function(PortRef source)? onLoraConnect;
  final void Function(InputPort port)? onLoraInputPort;
  final bool imageConnected;
  final void Function(PortRef source)? onImageConnect;
  final void Function(InputPort port)? onImageInputPort;
  final bool promptConnected;
  final void Function(PortRef source)? onPromptConnect;
  final void Function(InputPort port)? onPromptInputPort;

  const ImageGenNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onOutputPort,
    super.connectedOutputs,
    this.onModelConnect,
    this.onModelInputPort,
    this.modelConnected = false,
    this.onLoraConnect,
    this.onLoraInputPort,
    this.loraConnected = false,
    this.onImageConnect,
    this.onImageInputPort,
    this.imageConnected = false,
    this.onPromptConnect,
    this.onPromptInputPort,
    this.promptConnected = false,
    this.api,
    this.poll = const Duration(seconds: 2),
  });

  @override
  State<ImageGenNodeWidget> createState() => _ImageGenNodeWidgetState();
}

class _ImageGenNodeWidgetState extends BaseNodeState<ImageGenNodeWidget>
    with WaitGatedExecution<ImageGenNodeWidget> {
  @override String   get nodeTitle    => 'Generate';
  @override IconData get nodeIcon     => Icons.image_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel =>
      _total > 0 ? 'generating $_step/$_total' : 'starting';

  late final GenerateApi _api;
  late final InputPort _modelIn;
  late final InputPort _loraIn;
  late final InputPort _imageIn;
  late final InputPort _promptIn;
  final OutputPort _out = OutputPort('image');
  late final TextEditingController _prompt;
  final TextEditingController _wiredCtl = TextEditingController();
  late final TextEditingController _steps;
  late final TextEditingController _size;
  late final TextEditingController _seed;
  late final TextEditingController _strength;
  late final TextEditingController _imgStrength;
  late final TextEditingController _editStrength;
  String _mode = 'img2img';
  String _familyChoice = 'qwen';
  String _lastFamily = 'qwen';

  AaPayload? _modelRow;
  AaPayload? _loraRow;
  AaPayload? _initRow;
  AaPayload? _promptRow;
  String? _runId;
  Timer? _timer;
  int _gen = 0;
  int _step = 0;
  int _total = 0;
  Uint8List? _png;
  double? _seconds;

  int? _int(TextEditingController c, {int min = 1}) {
    final n = int.tryParse(c.text.trim());
    return (n != null && n >= min) ? n : null;
  }

  double? get _strengthValue {
    final v = double.tryParse(_strength.text.trim());
    return (v != null && v >= 0 && v <= 2) ? v : null;
  }

  double? get _imgStrengthValue {
    final v = double.tryParse(_imgStrength.text.trim());
    return (v != null && v >= 0 && v <= 1) ? v : null;
  }

  double? get _editStrengthValue {
    final v = double.tryParse(_editStrength.text.trim());
    return (v != null && v > 0 && v <= 1) ? v : null;
  }

  /// `qwen` or `z-image`: the wired LoRA's `family` if it names one we know,
  /// else the selector.
  String get _family {
    final f = firstValue(_loraRow, 'family');
    return (f == 'qwen' || f == 'z-image') ? f! : _familyChoice;
  }

  bool get _familyFromLora {
    final f = firstValue(_loraRow, 'family');
    return f == 'qwen' || f == 'z-image';
  }

  bool get _zimage => _family == 'z-image';

  static String _defaultSteps(String family) => family == 'z-image' ? '9' : '40';

  /// After anything that can change [_family]: swap the step count when it is
  /// still the old family's default, so a Z-Image run is not 40 turbo steps.
  void _familyMoved() {
    final now = _family;
    if (now == _lastFamily) return;
    if (_steps.text.trim() == _defaultSteps(_lastFamily)) {
      _steps.text = _defaultSteps(now);
    }
    _lastFamily = now;
    _persist();
  }

  bool get _edit => !_zimage && _mode == 'edit';

  /// Edit wants multiples of 32; plain generation, 16.
  int get _grid => _edit ? 32 : 16;

  int? get _sizeValue {
    final n = _int(_size, min: 64);
    return (n != null && n % _grid == 0) ? n : null;
  }

  String get _model => firstValue(_modelRow, 'pathOrUrl') ?? '';
  String get _lora => firstValue(_loraRow, 'path') ?? '';
  /// The wired prompt (a file's `text`, or a `prompt` column) wins over the
  /// field; with nothing wired the field is the prompt.
  String? get _wiredPrompt {
    final v = firstValue(_promptRow, 'prompt') ?? firstValue(_promptRow, 'text');
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  String get _promptText => (_wiredPrompt ?? _prompt.text).trim();
  /// The starting picture: `image_b64`, or `bytes` (Load File's column for an
  /// image file).
  String get _init =>
      firstValue(_initRow, 'image_b64') ?? firstValue(_initRow, 'bytes') ?? '';

  /// A wire is connected and a row arrived, but it holds no picture. Said out
  /// loud and blocks Execute: ignoring it would give an unrelated text-to-image
  /// result that looks like the picture had no effect.
  bool get _imageProblem => _initRow != null && _init.isEmpty;

  @override
  bool get isReady =>
      _promptText.isNotEmpty &&
      _int(_steps) != null &&
      _sizeValue != null &&
      _int(_seed, min: 0) != null &&
      _strengthValue != null &&
      _imgStrengthValue != null &&
      _editStrengthValue != null &&
      !_imageProblem &&
      !(_edit && _init.isEmpty);

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const GenerateApi();
    final p = widget.initialParams;
    _prompt = TextEditingController(text: p?['prompt'] ?? '');
    _steps = TextEditingController(text: p?['steps'] ?? '40');
    _size = TextEditingController(text: p?['size'] ?? '1024');
    _seed = TextEditingController(text: p?['seed'] ?? '42');
    _strength = TextEditingController(text: p?['loraStrength'] ?? '1.0');
    _imgStrength = TextEditingController(text: p?['imageStrength'] ?? '0.6');
    _editStrength = TextEditingController(text: p?['editStrength'] ?? '1.0');
    _mode = p?['mode'] == 'edit' ? 'edit' : 'img2img';
    _familyChoice = p?['family'] == 'z-image' ? 'z-image' : 'qwen';
    _lastFamily = _familyChoice;

    _modelIn = InputPort('model');
    widget.onModelInputPort?.call(_modelIn);
    _modelIn.onDataArrived.listen((aa) {
      if (mounted) setState(() => _modelRow = aa);
    });
    _modelIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _modelRow = null);
    });

    _loraIn = InputPort('lora');
    widget.onLoraInputPort?.call(_loraIn);
    _loraIn.onDataArrived.listen((aa) {
      if (!mounted) return;
      setState(() {
        _loraRow = aa;
        _familyMoved();
      });
    });
    _loraIn.onDisconnected.listen((_) {
      if (!mounted) return;
      setState(() {
        _loraRow = null;
        _familyMoved();
      });
    });

    _imageIn = InputPort('image');
    widget.onImageInputPort?.call(_imageIn);
    _imageIn.onDataArrived.listen((aa) {
      if (mounted) setState(() => _initRow = aa);
    });
    _imageIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _initRow = null);
    });

    _promptIn = InputPort('prompt');
    widget.onPromptInputPort?.call(_promptIn);
    _promptIn.onDataArrived.listen((aa) {
      if (!mounted) return;
      setState(() {
        _promptRow = aa;
        _wiredCtl.text = _wiredPrompt ?? '';
      });
    });
    _promptIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _promptRow = null);
    });

    initOutputPort(_out);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _modelIn.dispose();
    _loraIn.dispose();
    _imageIn.dispose();
    _promptIn.dispose();
    _wiredCtl.dispose();
    _out.dispose();
    for (final c in [_prompt, _steps, _size, _seed, _strength, _imgStrength, _editStrength]) {
      c.dispose();
    }
    super.dispose();
  }

  void _persist() => saveParams({
        'prompt': _prompt.text,
        'steps': _steps.text.trim(),
        'size': _size.text.trim(),
        'seed': _seed.text.trim(),
        'loraStrength': _strength.text.trim(),
        'imageStrength': _imgStrength.text.trim(),
        'editStrength': _editStrength.text.trim(),
        'mode': _mode,
        'family': _familyChoice,
      });

  @override
  void fire() => _generate();

  Future<void> _generate() async {
    if (!isReady || status == NodeStatus.working) return;
    final gen = ++_gen;
    setState(() {
      _step = 0;
      _total = _int(_steps)!;
      _png = null;
      _seconds = null;
    });
    setWorking();
    try {
      final id = await _api.start(
        prompt: _promptText,
        model: _model,
        steps: _int(_steps)!,
        size: _sizeValue!,
        seed: _int(_seed, min: 0)!,
        lora: _lora,
        loraScale: _strengthValue!,
        imageB64: _init,
        imageStrength: _imgStrengthValue!,
        mode: _edit ? 'edit' : 'img2img',
        editStrength: _editStrengthValue!,
        family: _family,
      );
      if (gen != _gen || !mounted) return;
      _runId = id;
      _timer?.cancel();
      _timer = Timer.periodic(widget.poll, (_) => _check(gen));
    } catch (e) {
      if (gen != _gen || !mounted) return;
      setError(e);
    }
  }

  Future<void> _check(int gen) async {
    final id = _runId;
    if (id == null || gen != _gen) return;
    try {
      final st = await _api.status(id);
      if (gen != _gen || !mounted) return;
      setState(() {
        _step = st.step;
        if (st.total > 0) _total = st.total;
      });
      switch (st.status) {
        case 'done':
          _timer?.cancel();
          final bytes = await _api.image(id);
          if (gen != _gen || !mounted) return;
          setState(() {
            _png = bytes;
            _seconds = st.seconds;
          });
          setComplete(
            detail: st.seconds == null ? 'image ready' : 'done in ${st.seconds!.round()}s',
          );
          _out.emit(AaPayload(
            rows: const ['image', 'image'],
            cols: const ['image_b64', 'path'],
            vals: [base64Encode(bytes), st.path],
          ));
        case 'failed':
          _timer?.cancel();
          setError(st.error ?? 'generation failed');
        case 'cancelled':
          _timer?.cancel();
          setIdle();
      }
    } catch (e) {
      if (gen != _gen || !mounted) return;
      _timer?.cancel();
      setError(e);
    }
  }

  Future<void> _cancel() async {
    final id = _runId;
    _gen++;
    _timer?.cancel();
    setIdle();
    if (id != null) {
      try {
        await _api.cancel(id);
      } catch (_) {}
    }
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'model',
          idx: 0,
          active: widget.modelConnected,
          onConnect: widget.onModelConnect,
        ),
        InputConnector(
          label: 'lora',
          idx: 1,
          active: widget.loraConnected,
          onConnect: widget.onLoraConnect,
        ),
        InputConnector(
          label: 'image',
          idx: 2,
          active: widget.imageConnected,
          onConnect: widget.onImageConnect,
        ),
        InputConnector(
          label: 'prompt',
          idx: 3,
          active: widget.promptConnected,
          onConnect: widget.onPromptConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'image',
          idx: 0,
          active: _png != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;

    Widget field(String label, TextEditingController c, String key,
            {String? error}) =>
        Expanded(
          child: TextField(
            key: ValueKey(key),
            controller: c,
            enabled: !busy,
            onChanged: (_) {
              _persist();
              setState(() {});
            },
            decoration: InputDecoration(
              labelText: label,
              errorText: error,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(4)),
        TextField(
          key: ValueKey(_wiredPrompt == null ? 'gen-prompt' : 'gen-prompt-wired'),
          controller: _wiredPrompt == null ? _prompt : _wiredCtl,
          enabled: !busy && _wiredPrompt == null,
          readOnly: _wiredPrompt != null,
          minLines: 3,
          maxLines: 6,
          onChanged: (_) {
            _persist();
            setState(() {});
          },
          decoration: InputDecoration(
            labelText: 'Prompt',
            helperText: _wiredPrompt != null
                ? 'from the prompt port'
                : (_zimage
                    ? 'Z-Image-Turbo'
                    : (_model.isEmpty ? 'Qwen-Image-2.1' : _model)),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const ValueKey('gen-family'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'qwen', label: Text('Qwen-Image')),
            ButtonSegment(value: 'z-image', label: Text('Z-Image')),
          ],
          selected: {_family},
          onSelectionChanged: (busy || _familyFromLora)
              ? null
              : (v) {
                  setState(() {
                    _familyChoice = v.first;
                    _familyMoved();
                  });
                  _persist();
                },
        ),
        if (_familyFromLora)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('set by the LoRA',
                key: const ValueKey('gen-family-note'),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 8),
        if (!_zimage)
        SegmentedButton<String>(
          key: const ValueKey('gen-mode'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'img2img', label: Text('Img2img')),
            ButtonSegment(value: 'edit', label: Text('Edit')),
          ],
          selected: {_mode},
          onSelectionChanged: busy
              ? null
              : (v) {
                  setState(() => _mode = v.first);
                  _persist();
                },
        ),
        if (!_zimage) const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            field('Steps', _steps, 'gen-steps',
                error: _int(_steps) == null ? '≥ 1' : null),
            const SizedBox(width: 8),
            field('Size', _size, 'gen-size',
                error: _sizeValue == null ? '×$_grid' : null),
            const SizedBox(width: 8),
            field('Seed', _seed, 'gen-seed',
                error: _int(_seed, min: 0) == null ? '≥ 0' : null),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            field('LoRA strength', _strength, 'gen-strength',
                error: _strengthValue == null ? '0 – 2' : null),
            const SizedBox(width: 8),
            if (_edit)
              field('Edit strength', _editStrength, 'gen-edit-strength',
                  error: _editStrengthValue == null ? '>0 – 1' : null)
            else
              field('Image strength', _imgStrength, 'gen-image-strength',
                  error: _imgStrengthValue == null ? '0 – 1' : null),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _imageProblem
              ? 'The image input has no picture (needs a `bytes` or `image_b64` column).'
              : (_edit && _init.isEmpty)
                  ? 'Edit needs a start image on the image input.'
                  : [
                  _lora.isEmpty ? 'no LoRA' : 'LoRA: $_lora',
                  _init.isEmpty ? 'no start image' : 'start image',
                ].join(' · '),
          key: const ValueKey('gen-inputs'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
              color: (_imageProblem || (_edit && _init.isEmpty))
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _cancel : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
        if (_png != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(_png!, key: const ValueKey('gen-image'), fit: BoxFit.contain),
          ),
          if (_seconds != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${_seconds!.round()} s',
                  style: theme.textTheme.labelSmall),
            ),
        ],
      ],
    );
  }
}
