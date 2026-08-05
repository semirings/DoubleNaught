import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/text_inference_api.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

enum _InferStatus { idle, generating, complete, error }

/// A **processing node** (AA-in × 2 → AA-out) that takes a model-handle AA
/// and a ChatML prompt AA, runs generative inference via the backend
/// `/text/infer` route, and emits the result AA on `resultOut`.
///
/// Ports:
///   * `modelHandle` (AA, idx 0) — from [TextModelLoaderNode].
///   * `promptIn`    (AA, idx 1) — from [TextPromptNode].
///   * `resultOut`   (AA, idx 0 output) — inference result AA.
///
/// Generation hyper-parameters are exposed as UI sliders and persisted via
/// the `initialParams` / `onParams` mechanism.
///
/// Result AA row: `result:<uuid12>`, cols: `response_text` · `model_id` ·
/// `input_tokens` · `output_tokens` · `tokens_per_sec` · `stop_reason` ·
/// `generated_at` · `ext:image_prompt` · `ext:aa_context`.
class TextInferenceNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  // modelHandle (AA) — idx 0
  final bool modelHandleConnected;
  final void Function(PortRef source)? onModelHandleConnect;
  final void Function(InputPort port)? onModelHandlePort;

  // promptIn (AA) — idx 1
  final bool promptConnected;
  final void Function(PortRef source)? onPromptConnect;
  final void Function(InputPort port)? onPromptPort;

  // resultOut (AA) — output idx 0
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  /// Saved generation parameters.
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  /// Backend client.  Injectable for tests; defaults to the shared instance.
  final TextInferenceApi api;

  const TextInferenceNode({
    super.key,
    required this.node,
    this.modelHandleConnected = false,
    this.onModelHandleConnect,
    this.onModelHandlePort,
    this.promptConnected = false,
    this.onPromptConnect,
    this.onPromptPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.initialParams,
    this.onParams,
    this.api = const TextInferenceApi(),
  });

  @override
  State<TextInferenceNode> createState() => _TextInferenceNodeState();
}

class _TextInferenceNodeState extends State<TextInferenceNode> {
  final InputPort _modelIn = InputPort('modelHandle');
  final InputPort _promptIn = InputPort('promptIn');
  final OutputPort _out = OutputPort('resultOut');

  AaPayload? _modelHandle;
  AaPayload? _prompt;
  TextInferenceMetrics? _lastMetrics;
  _InferStatus _status = _InferStatus.idle;
  String? _error;

  // Generation parameters (restored from initialParams).
  late int _maxTokens;
  late double _temperature;
  late double _topP;
  late double _repetitionPenalty;

  bool get _canGenerate =>
      _modelHandle != null &&
      _prompt != null &&
      _status != _InferStatus.generating;

  @override
  void initState() {
    super.initState();
    _maxTokens =
        int.tryParse(widget.initialParams?['maxTokens'] ?? '') ?? 512;
    _temperature =
        double.tryParse(widget.initialParams?['temperature'] ?? '') ?? 0.7;
    _topP = double.tryParse(widget.initialParams?['topP'] ?? '') ?? 0.95;
    _repetitionPenalty =
        double.tryParse(widget.initialParams?['repetitionPenalty'] ?? '') ?? 1.1;

    widget.onModelHandlePort?.call(_modelIn);
    widget.onPromptPort?.call(_promptIn);
    widget.onOutputPort?.call(_out);

    _modelIn.onDataArrived.listen(_onModelHandle);
    _promptIn.onDataArrived.listen(_onPrompt);
  }

  @override
  void dispose() {
    _modelIn.dispose();
    _promptIn.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onModelHandle(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _modelHandle = payload;
      _status = _InferStatus.idle;
    });
  }

  void _onPrompt(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _prompt = payload;
      _status = _InferStatus.idle;
    });
  }

  void _saveParams() {
    widget.onParams?.call({
      'maxTokens': '$_maxTokens',
      'temperature': '$_temperature',
      'topP': '$_topP',
      'repetitionPenalty': '$_repetitionPenalty',
    });
  }

  Future<void> _generate() async {
    final handle = _modelHandle;
    final prompt = _prompt;
    if (handle == null || prompt == null) return;
    if (_status == _InferStatus.generating) return;

    setState(() {
      _status = _InferStatus.generating;
      _error = null;
    });
    try {
      final result = await widget.api.generate(
        modelHandle: handle,
        prompt: prompt,
        params: TextGenParams(
          maxTokens: _maxTokens,
          temperature: _temperature,
          topP: _topP,
          repetitionPenalty: _repetitionPenalty,
        ),
      );
      if (!mounted) return;
      _out.emit(result.result);
      _saveParams();
      setState(() {
        _lastMetrics = result.metrics;
        _status = _InferStatus.complete;
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
          _status = _InferStatus.error;
          _error = friendly;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: TextInferenceNode._width,
      child: DoubleNaughtNodeWrapper(
        title: 'Text Inference',
        icon: Icons.auto_awesome_outlined,
        inputPorts: [
          InputConnector(
            label: 'modelHandle',
            idx: 0,
            active: widget.modelHandleConnected,
            onConnect: widget.onModelHandleConnect,
          ),
          InputConnector(
            label: 'promptIn',
            idx: 1,
            active: widget.promptConnected,
            onConnect: widget.onPromptConnect,
          ),
        ],
        outputPorts: [
          OutputConnector(
            label: 'resultOut',
            idx: 0,
            active: _status == _InferStatus.complete ||
                widget.connectedOutputs.contains(0),
            dragData: PortRef(nodeId: widget.node.id, idx: 0),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _upstreamInfo(theme),
            const SizedBox(height: 10),
            _paramsPanel(theme),
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                onPressed: _canGenerate ? _generate : null,
                icon: _status == _InferStatus.generating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_outlined, size: 18),
                label: Text(
                  _status == _InferStatus.generating
                      ? 'Generating…'
                      : 'Generate',
                ),
              ),
            ),
            if (_lastMetrics != null) ...[
              const SizedBox(height: 8),
              _metricsPanel(theme, _lastMetrics!),
            ],
            const SizedBox(height: 6),
            _statusRow(theme),
          ],
        ),
      ),
    );
  }

  Widget _upstreamInfo(ThemeData theme) {
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    if (_modelHandle == null && _prompt == null) {
      return Text('Wire modelHandle and promptIn to enable inference.',
          style: muted);
    }

    final modelId = _modelHandle?.value('model_id') ?? '(no model)';
    final userPrompt = _prompt?.value('user_prompt') ?? '(no prompt)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          modelId.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          userPrompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
      ],
    );
  }

  Widget _paramsPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _slider(
            theme,
            label: 'Max tokens',
            value: _maxTokens.toDouble(),
            min: 64,
            max: 4096,
            divisions: 62,
            display: '$_maxTokens',
            onChanged: (v) => setState(() => _maxTokens = v.round()),
          ),
          _slider(
            theme,
            label: 'Temperature',
            value: _temperature,
            min: 0.0,
            max: 2.0,
            divisions: 40,
            display: _temperature.toStringAsFixed(2),
            onChanged: (v) => setState(() => _temperature = v),
          ),
          _slider(
            theme,
            label: 'Top-p',
            value: _topP,
            min: 0.0,
            max: 1.0,
            divisions: 20,
            display: _topP.toStringAsFixed(2),
            onChanged: (v) => setState(() => _topP = v),
          ),
          _slider(
            theme,
            label: 'Rep. penalty',
            value: _repetitionPenalty,
            min: 1.0,
            max: 2.0,
            divisions: 20,
            display: _repetitionPenalty.toStringAsFixed(2),
            onChanged: (v) => setState(() => _repetitionPenalty = v),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    ThemeData theme, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }

  Widget _metricsPanel(ThemeData theme, TextInferenceMetrics m) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: scheme.primaryContainer.withValues(alpha: 0.18),
        border: Border.all(color: scheme.primaryContainer),
      ),
      child: Text(
        '${m.outputTokens} tokens · ${m.tokensPerSec.toStringAsFixed(1)} tok/s · '
        '${(m.generationTimeMs / 1000).toStringAsFixed(1)} s · ${m.stopReason}',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _statusRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      _InferStatus.idle => (scheme.outline, 'idle'),
      _InferStatus.generating => (scheme.primary, 'generating…'),
      _InferStatus.complete => (Colors.green, 'complete'),
      _InferStatus.error => (scheme.error, 'error'),
    };
    final detail =
        (_status == _InferStatus.error && _error != null) ? ' · $_error' : '';
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
            style: theme.textTheme.bodySmall?.copyWith(color: color),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
