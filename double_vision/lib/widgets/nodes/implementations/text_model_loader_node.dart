import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/text_inference_api.dart';
import '../base/base_node_widget.dart';

/// A **source node** that loads a generative text model via mlx-lm and emits
/// a model-handle [AaPayload] on its `modelHandle` output port.
///
/// The node is distinct from [LoadModelNode] (which loads zero-shot
/// classifiers): this one targets Apple Silicon generative inference via
/// `mlx-lm` and understands the LoRA adapter path convention.
///
/// Ports:
///   * `trigger` (AA, idx 0) — optional reactive trigger; loading the model
///     is re-executed whenever a payload arrives (e.g. from a Start node).
///   * `modelHandle` (AA, idx 0 output) — the model-handle AA emitted after
///     a successful load, ready to wire into [TextInferenceNode].
///
/// Model-handle AA row: `model:<slug>`, cols: `model_id` · `backend` ·
/// `context_length` · `loaded_at` · `source_type` · `lora_path` ·
/// `ext:max_new_tokens` · `ext:embedding_dim`.
class TextModelLoaderNode extends BaseNodeWidget {
  static const double _width = 320;

  final TextInferenceApi api;

  const TextModelLoaderNode({
    super.key,
    required super.node,
    bool triggerConnected = false,
    void Function(PortRef source)? onTriggerConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    super.initialParams,
    super.onParams,
    this.api = const TextInferenceApi(),
  }) : super(
          inputConnected: triggerConnected,
          onInputConnect: onTriggerConnect,
        );

  @override
  State<TextModelLoaderNode> createState() => _TextModelLoaderNodeState();
}

class _TextModelLoaderNodeState extends BaseNodeState<TextModelLoaderNode> {
  @override String   get nodeTitle    => 'Text Model Loader';
  @override IconData get nodeIcon     => Icons.memory_outlined;
  @override String   get workingLabel => 'loading model…';
  @override double   get nodeWidth    => TextModelLoaderNode._width;

  final InputPort  _trigger = InputPort('trigger');
  final OutputPort _out     = OutputPort('modelHandle');

  late TextEditingController _modelIdCtrl;
  late TextEditingController _loraPathCtrl;

  TextLoadStats? _stats;

  bool get _canLoad =>
      _modelIdCtrl.text.trim().isNotEmpty && status != NodeStatus.working;

  @override
  String cleanError(Object e) {
    final msg = '$e';
    if (msg.contains('Connection refused') ||
        msg.contains('SocketException') ||
        msg.contains('ClientException')) {
      return 'Backend not reachable — is double_touch running on :8000?';
    }
    return super.cleanError(e);
  }

  @override
  void initState() {
    super.initState();
    _modelIdCtrl = TextEditingController(
      text: widget.initialParams?['modelId'] ??
          'mlx-community/phi-4-mini-instruct-4bit',
    );
    _loraPathCtrl = TextEditingController(
      text: widget.initialParams?['loraPath'] ?? '',
    );
    initInputPort(_trigger, _onTrigger);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _modelIdCtrl.dispose();
    _loraPathCtrl.dispose();
    _trigger.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onTrigger(AaPayload _) {
    if (status != NodeStatus.working) _load();
  }

  Future<void> _load() async {
    final modelId = _modelIdCtrl.text.trim();
    if (modelId.isEmpty) return;
    setWorking();
    try {
      final result = await widget.api.loadModel(
        modelId,
        loraPath: _loraPathCtrl.text.trim(),
      );
      if (!mounted) return;
      _out.emit(result.handle);
      saveParams({
        'modelId':   _modelIdCtrl.text.trim(),
        'loraPath':  _loraPathCtrl.text.trim(),
      });
      setState(() => _stats = result.stats);
      setComplete();
    } catch (e) {
      if (mounted) setError(e);
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'trigger'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'modelHandle',
          idx: 0,
          hasData: status == NodeStatus.complete,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final busy = status == NodeStatus.working;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _modelIdCtrl,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'Model ID / Path',
            hintText: 'mlx-community/phi-4-mini-instruct-4bit',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _loraPathCtrl,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'LoRA Path (optional)',
            hintText: '/path/to/adapters/',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 36,
          child: ElevatedButton.icon(
            onPressed: _canLoad ? _load : null,
            icon: busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_for_offline_outlined, size: 16),
            label: Text(busy ? 'Loading…' : 'Load Model'),
          ),
        ),
        if (_stats != null) ...[
          const SizedBox(height: 8),
          _statsPanel(_stats!),
        ],
        const SizedBox(height: 6),
        statusRow(),
      ],
    );
  }

  Widget _statsPanel(TextLoadStats stats) {
    final theme  = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stats.modelId.split('/').last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '${stats.backend} · ctx ${stats.contextLength ~/ 1024}k'
            '${stats.loraPath.isNotEmpty ? ' · LoRA' : ''}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
