import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/output_connector.dart';

/// A **source node** that packages user-authored system and user prompts into
/// a ChatML associative array and emits it on the `promptOut` output port.
///
/// No backend call is made — the AA is assembled entirely on the client.
///
/// ChatML AA contract
/// ------------------
/// Row: `prompt:<uuid12>`
///
/// | col               | val                                    |
/// |-------------------|----------------------------------------|
/// | system_prompt     | textarea text                          |
/// | user_prompt       | textarea text                          |
/// | template          | "chatml"                               |
/// | timestamp         | ISO-8601 UTC (set at Package time)     |
/// | ext:stop_sequences| "" — reserved for downstream override  |
/// | ext:image_prompt  | "" — reserved for Flux/mflux nodes     |
///
/// The `ext:` namespace is the forward-compatibility hook: downstream nodes
/// (image generation, AA-context injection) can consume these columns without
/// changing the inference contract.
class TextPromptNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  /// Registers the `promptOut` egress port with the canvas bridge.
  final void Function(OutputPort port)? onOutputPort;

  /// Output port indices with an outgoing edge.
  final Set<int> connectedOutputs;

  /// Saved node parameters; restored on load.
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  const TextPromptNode({
    super.key,
    required this.node,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.initialParams,
    this.onParams,
  });

  @override
  State<TextPromptNode> createState() => _TextPromptNodeState();
}

class _TextPromptNodeState extends State<TextPromptNode> {
  final OutputPort _out = OutputPort('promptOut');

  late TextEditingController _systemCtrl;
  late TextEditingController _userCtrl;

  bool _packaged = false;

  @override
  void initState() {
    super.initState();
    _systemCtrl = TextEditingController(
      text: widget.initialParams?['systemPrompt'] ?? 'You are a helpful assistant.',
    );
    _userCtrl = TextEditingController(
      text: widget.initialParams?['userPrompt'] ?? '',
    );
    widget.onOutputPort?.call(_out);
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    _userCtrl.dispose();
    _out.dispose();
    super.dispose();
  }

  void _package() {
    final systemPrompt = _systemCtrl.text;
    final userPrompt = _userCtrl.text;
    final rowId = 'prompt:${_shortUuid()}';

    final cols = [
      'system_prompt',
      'user_prompt',
      'template',
      'timestamp',
      'ext:stop_sequences',
      'ext:image_prompt',
    ];
    final vals = [
      systemPrompt,
      userPrompt,
      'chatml',
      DateTime.now().toUtc().toIso8601String(),
      '',
      '',
    ];

    final aa = AaPayload(
      rows: List.filled(cols.length, rowId),
      cols: cols,
      vals: vals,
    );
    _out.emit(aa);
    widget.onParams?.call({
      'systemPrompt': systemPrompt,
      'userPrompt': userPrompt,
    });
    setState(() => _packaged = true);
  }

  /// 12-char hex snippet — good enough for a session-scoped row key.
  String _shortUuid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return now.toRadixString(16).padLeft(12, '0').substring(0, 12);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUser = _userCtrl.text.trim().isNotEmpty;

    return SizedBox(
      width: TextPromptNode._width,
      child: DoubleNaughtNodeWrapper(
        title: 'Text Prompt',
        icon: Icons.chat_bubble_outline,
        outputPorts: [
          OutputConnector(
            label: 'promptOut',
            idx: 0,
            active: _packaged || widget.connectedOutputs.contains(0),
            dragData: PortRef(nodeId: widget.node.id, idx: 0),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // System prompt
            Text(
              'System Prompt',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _systemCtrl,
              onChanged: (_) => setState(() => _packaged = false),
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'You are a helpful assistant.',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
            const SizedBox(height: 10),
            // User prompt
            Text(
              'User Prompt',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _userCtrl,
              onChanged: (_) => setState(() => _packaged = false),
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: 'Enter your message…',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: hasUser ? _package : null,
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('Package Prompt'),
              ),
            ),
            if (_packaged) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Prompt packaged',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.green),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
