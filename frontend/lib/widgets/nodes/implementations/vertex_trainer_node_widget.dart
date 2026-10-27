import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/cloud_train_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/gated_node_state.dart';
import '../base/output_connector.dart';
import '../base/training_fields_mixin.dart';
import 'vlm_trainer_node_widget.dart' show firstValue;

/// Trains an **image** LoRA (Z-Image-Turbo, via ai-toolkit) on Vertex AI —
/// the cloud-backed sibling of Image LoRA Trainer. Same `dataset` input and
/// `lora` output shape, so Generate and Load File need no changes to use
/// whichever one produced the adapter.
///
/// Unlike the local trainer, Vertex AI doesn't stream step-level progress or
/// support pulling a mid-run checkpoint: status is just
/// queued/running/done/failed/cancelled plus elapsed time, and the output
/// only appears once the job finishes.
///
/// Shares its epochs/rank/resolution fields and bounds with Image LoRA
/// Trainer via [TrainingFieldsMixin]. The two nodes stay separate rather
/// than merging into one with a local/cloud toggle: progress reporting,
/// quantize semantics and mid-run checkpoint export all differ enough
/// between the two backends that a merged node would need to branch its UI
/// on the toggle anyway, and keeping them separate means a saved workflow's
/// node `type` alone says whether a run was local or cloud-billed.
class VertexTrainerNodeWidget extends BaseNodeWidget {
  final CloudTrainApi? api;
  final Duration poll;

  const VertexTrainerNodeWidget({
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
    this.poll = const Duration(seconds: 3),
  });

  @override
  State<VertexTrainerNodeWidget> createState() => _VertexTrainerNodeWidgetState();
}

class _VertexTrainerNodeWidgetState extends GatedNodeState<VertexTrainerNodeWidget>
    with TrainingFieldsMixin<VertexTrainerNodeWidget> {
  @override String   get nodeTitle    => 'Image LoRA Cloud Trainer';
  @override IconData get nodeIcon     => Icons.cloud_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel =>
      _elapsed > 0 ? 'training (${_elapsed}s)' : 'starting';

  late final CloudTrainApi _api;
  late final InputPort _datasetIn;
  final OutputPort _out = OutputPort('lora');
  late final TextEditingController _trigger;

  /// Off by default: ai-toolkit's own zimage config needs no quantization
  /// on a 24GB L4; turn on to trade training quality for VRAM headroom.
  bool _quantize = false;

  AaPayload? _dataset;
  String? _runId;
  Timer? _timer;
  int _gen = 0;
  int _elapsed = 0;
  String? _adapter;

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
    _api = widget.api ?? const CloudTrainApi();
    final p = widget.initialParams;
    initTrainingFields(p);
    _trigger = TextEditingController(text: p?['trigger'] ?? '');
    _quantize = p?['quantize'] == 'true';

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
        'quantize': '$_quantize',
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
      _elapsed = 0;
      _adapter = null;
    });
    setWorking();
    try {
      final started = await _api.start(
        dataset: dataset,
        epochs: epochsValue!,
        rank: rankValue!,
        resolution: resolutionValue!,
        trigger: _trigger.text.trim(),
        quantize: _quantize,
      );
      if (gen != _gen || !mounted) return;
      _runId = started.runId;
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
      setState(() => _elapsed = st.elapsed);
      switch (st.status) {
        case 'done':
          _timer?.cancel();
          setState(() => _adapter = st.adapter);
          setComplete(detail: 'adapter saved');
          _emit(st.adapter);
        case 'failed':
          _timer?.cancel();
          setError(st.error ?? 'cloud training failed');
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
          'Z-Image-Turbo on Vertex AI (ai-toolkit)',
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
          epochsKey: 'vtrain-epochs',
          rankKey: 'vtrain-rank',
          resolutionKey: 'vtrain-resolution',
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('vtrain-trigger'),
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
        CheckboxListTile(
          key: const ValueKey('vtrain-quantize'),
          value: _quantize,
          onChanged: busy
              ? null
              : (v) {
                  setState(() => _quantize = v ?? false);
                  _persist();
                },
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Quantize'),
          subtitle: const Text('trade quality for VRAM headroom; usually unnecessary'),
        ),
        const SizedBox(height: 10),
        ...buildWaitAndExecute(busy: busy, onCancel: _cancel),
        const SizedBox(height: 8),
        statusRow(),
        if (_adapter != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            _adapter!,
            key: const ValueKey('vtrain-adapter'),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
