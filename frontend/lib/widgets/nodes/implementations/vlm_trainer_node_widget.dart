import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/vlm_api.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';
import '../base/wait_gated_execution.dart';

/// First value in [aa] for column [col], or null.
String? firstValue(AaPayload? aa, String col) {
  if (aa == null) return null;
  for (var i = 0; i < aa.cols.length && i < aa.vals.length; i++) {
    final v = '${aa.vals[i]}'.trim();
    if (aa.cols[i] == col && v.isNotEmpty) return v;
  }
  return null;
}

/// Fine-tunes a vision-language model (Qwen-VL) with LoRA on a collected set.
///
/// Inputs: `dataset` (idx 0, required) — Collect Loraset's output; `model`
/// (idx 1, optional) — a Load Model row whose `pathOrUrl` replaces the field.
/// Output `lora` (idx 0): one `adapter` row with `path` and `model`.
///
/// Execute-only: training takes minutes to hours, so it never starts because
/// data arrived. The adapter is a small file *beside* the untouched base
/// model; the Caption node loads both together.
class VlmTrainerNodeWidget extends BaseNodeWidget {
  final VlmApi? api;
  final Duration poll;

  final bool modelConnected;
  final void Function(PortRef source)? onModelConnect;
  final void Function(InputPort port)? onModelInputPort;

  const VlmTrainerNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.onModelConnect,
    this.onModelInputPort,
    this.modelConnected = false,
    this.api,
    this.poll = const Duration(seconds: 2),
  });

  @override
  State<VlmTrainerNodeWidget> createState() => _VlmTrainerNodeWidgetState();
}

class _VlmTrainerNodeWidgetState extends BaseNodeState<VlmTrainerNodeWidget>
    with WaitGatedExecution<VlmTrainerNodeWidget> {
  @override String   get nodeTitle    => 'LoRA Trainer';
  @override IconData get nodeIcon     => Icons.tune;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel =>
      _total > 0 ? 'training $_step/$_total' : 'starting';

  late final VlmApi _api;
  late final InputPort _datasetIn;
  late final InputPort _modelIn;
  final OutputPort _out = OutputPort('lora');
  late final TextEditingController _model;
  late final TextEditingController _epochs;
  late final TextEditingController _rank;

  AaPayload? _dataset;
  AaPayload? _modelRow;
  String? _runId;
  Timer? _timer;
  int _gen = 0;
  int _step = 0;
  int _total = 0;
  String? _adapter;

  String? get _datasetPath => firstValue(_dataset, 'path');
  String get _effectiveModel =>
      firstValue(_modelRow, 'pathOrUrl') ?? _model.text.trim();

  int? _positive(TextEditingController c) {
    final n = int.tryParse(c.text.trim());
    return (n != null && n >= 1) ? n : null;
  }

  @override
  bool get isReady =>
      _datasetPath != null &&
      _effectiveModel.isNotEmpty &&
      _positive(_epochs) != null &&
      _positive(_rank) != null;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const VlmApi();
    final p = widget.initialParams;
    _model = TextEditingController(text: p?['model'] ?? VlmApi.defaultModel);
    _epochs = TextEditingController(text: p?['epochs'] ?? '3');
    _rank = TextEditingController(text: p?['rank'] ?? '8');

    _datasetIn = InputPort('dataset');
    initInputPort(_datasetIn, (aa) {
      if (!mounted) return;
      setState(() => _dataset = aa);
    });
    _datasetIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _dataset = null);
    });

    _modelIn = InputPort('model');
    widget.onModelInputPort?.call(_modelIn);
    _modelIn.onDataArrived.listen((aa) {
      if (mounted) setState(() => _modelRow = aa);
    });
    _modelIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _modelRow = null);
    });

    initOutputPort(_out);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _datasetIn.dispose();
    _modelIn.dispose();
    _out.dispose();
    _model.dispose();
    _epochs.dispose();
    _rank.dispose();
    super.dispose();
  }

  void _persist() => saveParams({
        'model': _model.text.trim(),
        'epochs': _epochs.text.trim(),
        'rank': _rank.text.trim(),
      });

  @override
  void fire() => _train();

  Future<void> _train() async {
    final dataset = _datasetPath;
    if (dataset == null || !isReady || status == NodeStatus.working) return;
    final gen = ++_gen;
    setState(() {
      _step = 0;
      _total = 0;
      _adapter = null;
    });
    setWorking();
    try {
      final started = await _api.startTrain(
        dataset: dataset,
        model: _effectiveModel,
        epochs: _positive(_epochs)!,
        rank: _positive(_rank)!,
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
      final st = await _api.trainStatus(id);
      if (gen != _gen || !mounted) return;
      setState(() {
        _step = st.step;
        _total = st.total;
      });
      switch (st.status) {
        case 'done':
          _timer?.cancel();
          setState(() => _adapter = st.adapter);
          setComplete(detail: 'adapter saved');
          _out.emit(AaPayload(
            rows: const ['adapter', 'adapter'],
            cols: const ['path', 'model'],
            vals: [st.adapter, _effectiveModel],
          ));
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

  Future<void> _cancel() async {
    final id = _runId;
    _gen++;
    _timer?.cancel();
    setIdle();
    if (id != null) {
      try {
        await _api.cancelTrain(id);
      } catch (_) {}
    }
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'dataset'),
        InputConnector(
          label: 'model',
          idx: 1,
          active: widget.modelConnected,
          onConnect: widget.onModelConnect,
        ),
      ];

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
    final fromPort = firstValue(_modelRow, 'pathOrUrl') != null;

    Widget numField(String label, TextEditingController c, String key) => Expanded(
          child: TextField(
            key: ValueKey(key),
            controller: c,
            enabled: !busy,
            keyboardType: TextInputType.number,
            onChanged: (_) {
              _persist();
              setState(() {});
            },
            decoration: InputDecoration(
              labelText: label,
              errorText: _positive(c) == null ? '≥ 1' : null,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(2)),
        TextField(
          key: const ValueKey('vlm-model'),
          controller: _model,
          enabled: !busy && !fromPort,
          onChanged: (_) {
            _persist();
            setState(() {});
          },
          decoration: InputDecoration(
            labelText: 'Base model',
            helperText: fromPort ? 'from the model port' : 'Hugging Face id or local path',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            numField('Epochs', _epochs, 'vlm-epochs'),
            const SizedBox(width: 8),
            numField('Rank', _rank, 'vlm-rank'),
          ],
        ),
        const SizedBox(height: 10),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _cancel : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
        if (_adapter != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            _adapter!,
            key: const ValueKey('vlm-adapter'),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
