import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/image_train_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/gated_node_state.dart';
import '../base/output_connector.dart';
import '../base/training_fields_mixin.dart';
import 'vlm_trainer_node_widget.dart' show firstValue;

/// Trains an **image** LoRA (Z-Image-Turbo, through mflux) on a collected set.
///
/// Input `dataset` (idx 0, required) — Collect Loraset's output (`path`).
/// Output `lora` (idx 0): one `adapter` row with `path` (the `.safetensors`),
/// `model` and `family` (`z-image`, which Generate reads to pick its model).
///
/// Execute-only: a run takes from minutes to hours. While it runs, "Use latest
/// checkpoint" writes the newest saved adapter to the output so Generate can
/// try it before training ends. The trigger word, if any, is put in front of
/// every caption; put the same word in the Generate prompt to switch it on.
///
/// Shares its epochs/rank/resolution fields and bounds with Image LoRA
/// Cloud Trainer (the cloud-backed sibling) via [TrainingFieldsMixin] — see that file for
/// why the two nodes aren't merged into one with a local/cloud toggle.
class ImageTrainNodeWidget extends BaseNodeWidget {
  final ImageTrainApi? api;
  final Duration poll;

  const ImageTrainNodeWidget({
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
    this.poll = const Duration(seconds: 2),
  });

  @override
  State<ImageTrainNodeWidget> createState() => _ImageTrainNodeWidgetState();
}

class _ImageTrainNodeWidgetState extends GatedNodeState<ImageTrainNodeWidget>
    with TrainingFieldsMixin<ImageTrainNodeWidget> {
  @override String   get nodeTitle    => 'Image LoRA Trainer';
  @override IconData get nodeIcon     => Icons.brush_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel =>
      _total > 0 ? 'training $_step/$_total' : 'starting';

  late final ImageTrainApi _api;
  late final InputPort _datasetIn;
  final OutputPort _out = OutputPort('lora');
  late final TextEditingController _trigger;

  /// '0' (none), '4' or '8' — the only values the backend accepts
  /// (`quantize must be 0 (none), 4 or 8`). A dropdown rather than a
  /// numField like the others, since there's nothing to type: it's a
  /// closed choice, not an open-ended number with a range to validate.
  String _quantize = '0';

  AaPayload? _dataset;
  String? _runId;
  Timer? _timer;
  int _gen = 0;
  int _step = 0;
  int _total = 0;
  int _images = 0;
  int _checkpoints = 0;
  String? _adapter;
  String? _note;

  String? get _datasetPath => firstValue(_dataset, 'path');

  @override
  bool get isReady =>
      _datasetPath != null &&
      epochsValue != null &&
      rankValue != null &&
      resolutionValue != null;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const ImageTrainApi();
    final p = widget.initialParams;
    initTrainingFields(p);
    _trigger = TextEditingController(text: p?['trigger'] ?? '');
    _quantize = p?['quantize'] ?? '0';

    _datasetIn = InputPort('dataset');
    initInputPort(_datasetIn, (aa) {
      if (!mounted) return;
      setState(() => _dataset = aa);
    });
    _datasetIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _dataset = null);
    });

    initOutputPort(_out);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _datasetIn.dispose();
    _out.dispose();
    disposeTrainingFields();
    _trigger.dispose();
    super.dispose();
  }

  void _persist() => saveParams({
        'epochs': epochsController.text.trim(),
        'rank': rankController.text.trim(),
        'resolution': resolutionController.text.trim(),
        'trigger': _trigger.text.trim(),
        'quantize': _quantize,
      });

  @override
  void fire() => _train();

  void _emit(String adapter) {
    _out.emit(AaPayload(
      rows: const ['adapter', 'adapter', 'adapter'],
      cols: const ['path', 'model', 'family'],
      vals: [adapter, 'z-image-turbo', 'z-image'],
    ));
  }

  Future<void> _train() async {
    final dataset = _datasetPath;
    if (dataset == null || !isReady || status == NodeStatus.working) return;
    final gen = ++_gen;
    setState(() {
      _step = 0;
      _total = 0;
      _images = 0;
      _checkpoints = 0;
      _adapter = null;
      _note = null;
    });
    setWorking();
    try {
      final started = await _api.start(
        dataset: dataset,
        epochs: epochsValue!,
        rank: rankValue!,
        resolution: resolutionValue!,
        trigger: _trigger.text.trim(),
        quantize: int.parse(_quantize),
      );
      if (gen != _gen || !mounted) return;
      _runId = started.runId;
      setState(() {
        _images = started.images;
        _total = started.total;
      });
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
        _checkpoints = st.checkpoints;
      });
      switch (st.status) {
        case 'done':
          _timer?.cancel();
          setState(() => _adapter = st.adapter);
          setComplete(detail: 'adapter saved');
          _emit(st.adapter);
        case 'failed':
          _timer?.cancel();
          setError(st.error ?? 'training failed');
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

  Future<void> _useCheckpoint() async {
    final id = _runId;
    if (id == null) return;
    try {
      final st = await _api.exportNow(id);
      if (!mounted) return;
      setState(() {
        _adapter = st.adapter;
        _note = 'checkpoint at step ${st.iteration} sent to the lora output';
      });
      _emit(st.adapter);
    } catch (e) {
      if (!mounted) return;
      setState(() => _note = '$e'.replaceFirst('Exception: ', ''));
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
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'dataset')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'lora',
          idx: 0,
          active: _adapter != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
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
          'Z-Image-Turbo (downloads on first use)',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        trainingFieldsRow(
          busy: busy,
          onAnyChanged: () {
            _persist();
            setState(() {});
          },
          epochsKey: 'imgtrain-epochs',
          rankKey: 'imgtrain-rank',
          resolutionKey: 'imgtrain-resolution',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              key: const ValueKey('imgtrain-quantize'),
              initialValue: _quantize,
              isDense: true,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Quantize',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              style: theme.textTheme.bodySmall,
              items: const [
                DropdownMenuItem(value: '0', child: Text('None')),
                DropdownMenuItem(value: '8', child: Text('8-bit')),
                DropdownMenuItem(value: '4', child: Text('4-bit')),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _quantize = v);
                      _persist();
                    },
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('imgtrain-trigger'),
          controller: _trigger,
          enabled: !busy,
          onChanged: (_) => _persist(),
          decoration: const InputDecoration(
            labelText: 'Trigger word (optional)',
            helperText: 'put it in front of every caption; use it in prompts',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        ...buildWaitAndExecute(busy: busy, onCancel: _cancel),
        const SizedBox(height: 8),
        statusRow(),
        if (busy && _images > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$_images images · $_checkpoints checkpoint${_checkpoints == 1 ? '' : 's'} saved',
              key: const ValueKey('imgtrain-progress'),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (busy && _checkpoints > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('imgtrain-checkpoint'),
              onPressed: _useCheckpoint,
              child: const Text('Use latest checkpoint'),
            ),
          ),
        if (_note != null)
          Text(_note!,
              key: const ValueKey('imgtrain-note'),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        if (_adapter != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            _adapter!,
            key: const ValueKey('imgtrain-adapter'),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
