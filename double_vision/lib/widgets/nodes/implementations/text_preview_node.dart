import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../focus_panel.dart' show FocusContent;
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';

/// A **sink node** that receives the inference result AA from
/// [TextInferenceNode] and renders the response text.
///
/// The node body shows a compact excerpt; a "View in panel" button opens the
/// full response in the Focus Panel tab (the same mechanism [PreviewNode] uses
/// for AA tables and images).  Inference metrics (token counts, throughput)
/// are shown beneath the excerpt.
///
/// Port:
///   * `resultIn` (AA, idx 0) — the result AA from [TextInferenceNode].
///     Expected cols: `response_text`, `model_id`, `input_tokens`,
///     `output_tokens`, `tokens_per_sec`, `stop_reason`.
class TextPreviewNode extends StatefulWidget {
  final WorkflowNode node;

  /// True when an edge feeds `resultIn`.
  final bool resultConnected;

  /// Called when an edge is dropped on `resultIn`.
  final void Function(PortRef source)? onConnect;

  /// Registers `resultIn` with the canvas bridge.
  final void Function(InputPort port)? onInputPort;

  /// Pushes text content to the Focus Panel tab for this node.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Opens the Focus Panel and selects this node's tab.
  final void Function(int nodeId)? onView;

  const TextPreviewNode({
    super.key,
    required this.node,
    this.resultConnected = false,
    this.onConnect,
    this.onInputPort,
    this.onContent,
    this.onView,
  });

  @override
  State<TextPreviewNode> createState() => _TextPreviewNodeState();
}

class _TextPreviewNodeState extends State<TextPreviewNode> {
  final InputPort _in = InputPort('resultIn');

  // Extracted fields for display — derived on each arrival.
  String? _responseText;
  String? _modelId;
  String? _tokensPerSec;
  String? _inputTokens;
  String? _outputTokens;
  String? _stopReason;

  static const int _excerptMaxChars = 280;

  bool get _hasResponse =>
      _responseText != null && _responseText!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.onInputPort?.call(_in);
    _in.onDataArrived.listen(_onResult);
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _onResult(AaPayload payload) {
    if (!mounted) return;
    final text = payload.value('response_text') ?? '';
    setState(() {
      _responseText = text;
      _modelId = payload.value('model_id');
      _tokensPerSec = payload.value('tokens_per_sec');
      _inputTokens = payload.value('input_tokens');
      _outputTokens = payload.value('output_tokens');
      _stopReason = payload.value('stop_reason');
    });
    if (text.isNotEmpty) {
      widget.onContent?.call(
        widget.node.id,
        FocusContent.text(
          text,
          subtitle: _metricsSummary(),
        ),
      );
    }
  }

  String _metricsSummary() {
    final parts = <String>[];
    if (_modelId != null && _modelId!.isNotEmpty) {
      parts.add(_modelId!.split('/').last);
    }
    if (_inputTokens != null) parts.add('$_inputTokens in');
    if (_outputTokens != null) parts.add('$_outputTokens out');
    if (_tokensPerSec != null) {
      final tps = double.tryParse(_tokensPerSec!);
      if (tps != null) parts.add('${tps.toStringAsFixed(1)} tok/s');
    }
    if (_stopReason != null && _stopReason != 'eos') {
      parts.add(_stopReason!);
    }
    return parts.join(' · ');
  }

  void _copyToClipboard() {
    if (_responseText == null) return;
    Clipboard.setData(ClipboardData(text: _responseText!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Response copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DoubleNaughtNodeWrapper(
      title: 'Text Preview',
      icon: Icons.text_snippet_outlined,
      inputPorts: [
        InputConnector(
          label: 'resultIn',
          idx: 0,
          active: widget.resultConnected,
          onConnect: widget.onConnect,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _body(theme),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _hasResponse
                      ? () => widget.onView?.call(widget.node.id)
                      : null,
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('View in panel'),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: _hasResponse ? _copyToClipboard : null,
                icon: const Icon(Icons.copy_outlined, size: 16),
                tooltip: 'Copy response',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    if (!widget.resultConnected) {
      return Text('Connect a Text Inference node.', style: muted);
    }

    if (!_hasResponse) {
      return Text('Waiting for a result…', style: muted);
    }

    final text = _responseText!;
    final excerpt = text.length > _excerptMaxChars
        ? '${text.substring(0, _excerptMaxChars)}…'
        : text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Excerpt
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            excerpt,
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 6),
        // Metrics row
        Text(
          _metricsSummary(),
          style: muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
