import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/text_inference_api.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

enum _LoadStatus { idle, loading, ready, error }

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
class TextModelLoaderNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  // trigger (AA) — idx 0
  final bool triggerConnected;
  final void Function(PortRef source)? onTriggerConnect;
  final void Function(InputPort port)? onInputPort;

  // modelHandle (AA) — output idx 0
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  /// Saved settings (model id, lora path).
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  /// Backend client.  Injectable for tests; defaults to the shared instance.
  final TextInferenceApi api;

  const TextModelLoaderNode({
    super.key,
    required this.node,
    this.triggerConnected = false,
    this.onTriggerConnect,
    this.onInputPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.initialParams,
    this.onParams,
    this.api = const TextInferenceApi(),
  });

  @override
  State<TextModelLoaderNode> createState() => _TextModelLoaderNodeState();
}

class _TextModelLoaderNodeState extends State<TextModelLoaderNode> {
  final InputPort _trigger = InputPort('trigger');
  final OutputPort _out = OutputPort('modelHandle');

  late TextEditingController _modelIdCtrl;
  late TextEditingController _loraPathCtrl;

  _LoadStatus _status = _LoadStatus.idle;
  String? _error;
  TextLoadStats? _stats;

  bool get _canLoad =>
      _modelIdCtrl.text.trim().isNotEmpty && _status != _LoadStatus.loading;

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
    widget.onInputPort?.call(_trigger);
    widget.onOutputPort?.call(_out);
    _trigger.onDataArrived.listen(_onTrigger);
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
    if (_status != _LoadStatus.loading) _load();
  }

  void _saveParams() {
    widget.onParams?.call({
      'modelId': _modelIdCtrl.text.trim(),
      'loraPath': _loraPathCtrl.text.trim(),
    });
  }

  Future<void> _load() async {
    final modelId = _modelIdCtrl.text.trim();
    if (modelId.isEmpty) return;
    setState(() {
      _status = _LoadStatus.loading;
      _error = null;
    });
    try {
      final result = await widget.api.loadModel(
        modelId,
        loraPath: _loraPathCtrl.text.trim(),
      );
      if (!mounted) return;
      _out.emit(result.handle);
      _saveParams();
      setState(() {
        _stats = result.stats;
        _status = _LoadStatus.ready;
      });
    } catch (e) {
      if (mounted) {
        final msg = '$e';
        final friendly = (msg.contains('Connection refused') ||
                msg.contains('SocketException') ||
                msg.contains('ClientException'))
            ? 'Backend not reachable — is double_touch running on :8000?'
            : msg;
        setState(() {
          _status = _LoadStatus.error;
          _error = friendly;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: TextModelLoaderNode._width,
      child: DoubleNaughtNodeWrapper(
        title: 'Text Model Loader',
        icon: Icons.memory_outlined,
        inputPorts: [
          InputConnector(
            label: 'trigger',
            idx: 0,
            active: widget.triggerConnected,
            onConnect: widget.onTriggerConnect,
          ),
        ],
        outputPorts: [
          OutputConnector(
            label: 'modelHandle',
            idx: 0,
            active: _status == _LoadStatus.ready ||
                widget.connectedOutputs.contains(0),
            dragData: PortRef(nodeId: widget.node.id, idx: 0),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _modelIdCtrl,
              decoration: const InputDecoration(
                labelText: 'Model ID / Path',
                hintText: 'mlx-community/phi-4-mini-instruct-4bit',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              enabled: _status != _LoadStatus.loading,
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _loraPathCtrl,
              decoration: const InputDecoration(
                labelText: 'LoRA Path (optional)',
                hintText: '/path/to/adapters/',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              enabled: _status != _LoadStatus.loading,
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: _canLoad ? _load : null,
                icon: _status == _LoadStatus.loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_for_offline_outlined, size: 16),
                label: Text(
                  _status == _LoadStatus.loading ? 'Loading…' : 'Load Model',
                ),
              ),
            ),
            if (_stats != null) ...[
              const SizedBox(height: 8),
              _statsPanel(theme, _stats!),
            ],
            const SizedBox(height: 6),
            _statusRow(theme),
          ],
        ),
      ),
    );
  }

  Widget _statsPanel(ThemeData theme, TextLoadStats stats) {
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
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
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

  Widget _statusRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      _LoadStatus.idle => (scheme.outline, 'idle'),
      _LoadStatus.loading => (scheme.primary, 'loading model…'),
      _LoadStatus.ready => (Colors.green, 'ready'),
      _LoadStatus.error => (scheme.error, 'error'),
    };
    final detail =
        (_status == _LoadStatus.error && _error != null) ? ' · $_error' : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label$detail',
            style:
                theme.textTheme.bodySmall?.copyWith(color: color),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
