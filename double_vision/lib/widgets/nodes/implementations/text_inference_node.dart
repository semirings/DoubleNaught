import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/text_inference_api.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../../../backend_config.dart';

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
class TextInferenceNode extends BaseNodeWidget {
  static const double _width = 320;

  final bool modelHandleConnected;
  final void Function(PortRef source)? onModelHandleConnect;
  final void Function(InputPort port)? onModelHandlePort;

  final bool promptConnected;
  final void Function(PortRef source)? onPromptConnect;
  final void Function(InputPort port)? onPromptPort;

  final TextInferenceApi api;

  const TextInferenceNode({
    super.key,
    required super.node,
    this.modelHandleConnected = false,
    this.onModelHandleConnect,
    this.onModelHandlePort,
    this.promptConnected = false,
    this.onPromptConnect,
    this.onPromptPort,
    super.onOutputPort,
    super.connectedOutputs,
    super.initialParams,
    super.onParams,
    this.api = const TextInferenceApi(),
  });

  @override
  State<TextInferenceNode> createState() => _TextInferenceNodeState();
}

class _TextInferenceNodeState extends BaseNodeState<TextInferenceNode> {
  @override String   get nodeTitle    => 'Text Inference';
  @override IconData get nodeIcon     => Icons.auto_awesome_outlined;
  @override String   get workingLabel => 'generating…';
  @override double   get nodeWidth    => TextInferenceNode._width;

  final InputPort  _modelIn  = InputPort('modelHandle');
  final InputPort  _promptIn = InputPort('promptIn');
  final OutputPort _out      = OutputPort('resultOut');

  AaPayload? _modelHandle;
  AaPayload? _prompt;
  TextInferenceMetrics? _lastMetrics;

  late int    _maxTokens;
  late double _temperature;
  late double _topP;
  late double _repetitionPenalty;

  bool get _canGenerate =>
      _modelHandle != null && _prompt != null && status != NodeStatus.working;

  @override
  String cleanError(Object e) {
    final msg = '$e';
    if (msg.contains('Connection refused') ||
        msg.contains('SocketException') ||
        msg.contains('ClientException')) {
      return 'Backend not reachable — is double_touch running at '
          '${BackendConfig.baseUrl}?';
    }
    return super.cleanError(e);
  }

  @override
  void initState() {
    super.initState();
    _maxTokens = int.tryParse(widget.initialParams?['maxTokens'] ?? '') ?? 512;
    _temperature =
        double.tryParse(widget.initialParams?['temperature'] ?? '') ?? 0.7;
    _topP = double.tryParse(widget.initialParams?['topP'] ?? '') ?? 0.95;
    _repetitionPenalty =
        double.tryParse(widget.initialParams?['repetitionPenalty'] ?? '') ?? 1.1;

    widget.onModelHandlePort?.call(_modelIn);
    _modelIn.onDataArrived.listen(_onModelHandle);
    widget.onPromptPort?.call(_promptIn);
    _promptIn.onDataArrived.listen(_onPrompt);
    initOutputPort(_out);
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
    setState(() => _modelHandle = payload);
    setIdle();
  }

  void _onPrompt(AaPayload payload) {
    if (!mounted) return;
    setState(() => _prompt = payload);
    setIdle();
  }

  Future<void> _generate() async {
    final handle = _modelHandle;
    final prompt = _prompt;
    if (handle == null || prompt == null || !_canGenerate) return;
    setWorking();
    try {
      final result = await widget.api.generate(
        modelHandle: handle,
        prompt: prompt,
        params: TextGenParams(
          maxTokens:         _maxTokens,
          temperature:       _temperature,
          topP:              _topP,
          repetitionPenalty: _repetitionPenalty,
        ),
      );
      if (!mounted) return;
      _out.emit(result.result);
      saveParams({
        'maxTokens':         '$_maxTokens',
        'temperature':       '$_temperature',
        'topP':              '$_topP',
        'repetitionPenalty': '$_repetitionPenalty',
      });
      setState(() => _lastMetrics = result.metrics);
      setComplete();
    } catch (e) {
      if (mounted) setError(e);
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
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
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'resultOut',
          idx: 0,
          hasData: status == NodeStatus.complete,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy  = status == NodeStatus.working;

    return Column(
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
            icon: busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(busy ? 'Generating…' : 'Generate'),
          ),
        ),
        if (_lastMetrics != null) ...[
          const SizedBox(height: 8),
          _metricsPanel(theme, _lastMetrics!),
        ],
        const SizedBox(height: 6),
        statusRow(),
      ],
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

    final modelId   = _modelHandle?.value('model_id') ?? '(no model)';
    final userPrompt = _prompt?.value('user_prompt')  ?? '(no prompt)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          modelId.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
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
    final busy   = status == NodeStatus.working;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _slider(theme, label: 'Max tokens',    value: _maxTokens.toDouble(), min: 64,  max: 4096, divisions: 62, display: '$_maxTokens',                         disabled: busy, onChanged: (v) => setState(() => _maxTokens = v.round())),
          _slider(theme, label: 'Temperature',   value: _temperature,          min: 0.0, max: 2.0,  divisions: 40, display: _temperature.toStringAsFixed(2),        disabled: busy, onChanged: (v) => setState(() => _temperature = v)),
          _slider(theme, label: 'Top-p',         value: _topP,                 min: 0.0, max: 1.0,  divisions: 20, display: _topP.toStringAsFixed(2),               disabled: busy, onChanged: (v) => setState(() => _topP = v)),
          _slider(theme, label: 'Rep. penalty',  value: _repetitionPenalty,    min: 1.0, max: 2.0,  divisions: 20, display: _repetitionPenalty.toStringAsFixed(2),  disabled: busy, onChanged: (v) => setState(() => _repetitionPenalty = v)),
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
    required bool disabled,
    required ValueChanged<double> onChanged,
  }) =>
      Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: disabled ? null : onChanged,
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(display,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall),
          ),
        ],
      );

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
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
