import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/vlm_api.dart';
import '../base/base_node_widget.dart';
import '../base/gated_node_state.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';
import 'vlm_trainer_node_widget.dart' show firstValue;

/// Captions images with a vision-language model, optionally with a LoRA on top.
///
/// Inputs: `image` (idx 0, required) — rows carrying `image_b64` (Seg Forge's
/// `llmPayload`); `model` (idx 1, optional) — a Load Model row; `lora` (idx 2,
/// optional) — the trainer's `adapter` row. Leave `lora` unconnected to caption
/// with the plain base model: run both and compare to see what training did.
/// Output `captions` (idx 0): per input row, `caption` (+ `file_name` when
/// the row had one).
///
/// Caption with the prompt the set was trained with (default: the same one).
class VlmCaptionNodeWidget extends BaseNodeWidget {
  final VlmApi? api;

  final bool modelConnected;
  final void Function(PortRef source)? onModelConnect;
  final void Function(InputPort port)? onModelInputPort;
  final bool loraConnected;
  final void Function(PortRef source)? onLoraConnect;
  final void Function(InputPort port)? onLoraInputPort;

  const VlmCaptionNodeWidget({
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
    this.onLoraConnect,
    this.onLoraInputPort,
    this.loraConnected = false,
    this.api,
  });

  @override
  State<VlmCaptionNodeWidget> createState() => _VlmCaptionNodeWidgetState();
}

class _VlmCaptionNodeWidgetState extends GatedNodeState<VlmCaptionNodeWidget> {
  @override String   get nodeTitle    => 'Caption';
  @override IconData get nodeIcon     => Icons.image_search_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel =>
      _total > 0 ? 'captioning $_done/$_total' : 'captioning';

  late final VlmApi _api;
  late final InputPort _imageIn;
  late final InputPort _modelIn;
  late final InputPort _loraIn;
  final OutputPort _out = OutputPort('captions');
  late final TextEditingController _model;
  late final TextEditingController _prompt;

  AaPayload? _images;
  AaPayload? _modelRow;
  AaPayload? _loraRow;
  AaPayload? _result;
  int _gen = 0;
  int _done = 0;
  int _total = 0;
  int _failed = 0;

  /// Rows of [_images] that carry an image, as `{id, b64, file_name}`.
  List<Map<String, String>> get _rows {
    final aa = _images;
    if (aa == null) return const [];
    final byRow = <String, Map<String, String>>{};
    final order = <String>[];
    for (var i = 0; i < aa.rows.length && i < aa.cols.length && i < aa.vals.length; i++) {
      final id = '${aa.rows[i]}';
      final m = byRow.putIfAbsent(id, () {
        order.add(id);
        return {'id': id};
      });
      m['${aa.cols[i]}'] = '${aa.vals[i]}';
    }
    return [
      for (final id in order)
        if ((byRow[id]!['image_b64'] ?? '').isNotEmpty) byRow[id]!,
    ];
  }

  String get _effectiveModel =>
      firstValue(_modelRow, 'pathOrUrl') ?? _model.text.trim();

  /// The LoRA file, or '' for the plain base model.
  String get _adapter => firstValue(_loraRow, 'path') ?? '';

  @override
  bool get isReady => _rows.isNotEmpty && _effectiveModel.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const VlmApi();
    final p = widget.initialParams;
    _model = TextEditingController(text: p?['model'] ?? VlmApi.defaultModel);
    _prompt = TextEditingController(text: p?['prompt'] ?? VlmApi.defaultPrompt);

    _imageIn = InputPort('image');
    initInputPort(_imageIn, (aa) {
      if (!mounted) return;
      setState(() {
        _images = aa;
        _result = null;
      });
    });
    _imageIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _images = null);
    });

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
      if (mounted) setState(() => _loraRow = aa);
    });
    _loraIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _loraRow = null);
    });

    initOutputPort(_out);
  }

  @override
  void dispose() {
    _imageIn.dispose();
    _modelIn.dispose();
    _loraIn.dispose();
    _out.dispose();
    _model.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _persist() =>
      saveParams({'model': _model.text.trim(), 'prompt': _prompt.text.trim()});

  @override
  void fire() => _run();

  Future<void> _run() async {
    final rows = _rows;
    if (rows.isEmpty || !isReady || status == NodeStatus.working) return;
    final gen = ++_gen;
    setState(() {
      _done = 0;
      _total = rows.length;
      _failed = 0;
      _result = null;
    });
    setWorking();
    final outRows = <String>[], outCols = <String>[], outVals = <String>[];
    String? firstError;
    for (final r in rows) {
      try {
        final text = await _api.caption(
          imageB64: r['image_b64']!,
          model: _effectiveModel,
          adapter: _adapter,
          prompt: _prompt.text.trim().isEmpty
              ? VlmApi.defaultPrompt
              : _prompt.text.trim(),
        );
        outRows.add(r['id']!);
        outCols.add('caption');
        outVals.add(text);
        final fn = r['file_name'];
        if (fn != null && fn.isNotEmpty) {
          outRows.add(r['id']!);
          outCols.add('file_name');
          outVals.add(fn);
        }
      } catch (e) {
        _failed++;
        firstError ??= '$e';
      }
      if (gen != _gen || !mounted) return;
      setState(() => _done++);
    }
    if (outRows.isEmpty) {
      setError('all ${rows.length} caption call(s) failed: $firstError');
      return;
    }
    final aa = AaPayload(rows: outRows, cols: outCols, vals: outVals);
    setState(() => _result = aa);
    setComplete(
      detail: '${rows.length - _failed} captions'
          '${_failed > 0 ? ' · $_failed failed' : ''}'
          '${_adapter.isEmpty ? ' · base model' : ''}',
    );
    _out.emit(aa);
  }

  void _cancel() {
    _gen++;
    setIdle();
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'image'),
        InputConnector(
          label: 'model',
          idx: 1,
          active: widget.modelConnected,
          onConnect: widget.onModelConnect,
        ),
        InputConnector(
          label: 'lora',
          idx: 2,
          active: widget.loraConnected,
          onConnect: widget.onLoraConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'captions',
          idx: 0,
          active: _result != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;
    final fromPort = firstValue(_modelRow, 'pathOrUrl') != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(3)),
        TextField(
          key: const ValueKey('cap-model'),
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
        TextField(
          key: const ValueKey('cap-prompt'),
          controller: _prompt,
          enabled: !busy,
          onChanged: (_) => _persist(),
          decoration: const InputDecoration(
            labelText: 'Prompt',
            helperText: 'use the prompt the set was trained with',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _adapter.isEmpty ? 'no LoRA — plain base model' : 'LoRA: $_adapter',
          key: const ValueKey('cap-adapter'),
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        ...buildWaitAndExecute(busy: busy, onCancel: _cancel),
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }
}
