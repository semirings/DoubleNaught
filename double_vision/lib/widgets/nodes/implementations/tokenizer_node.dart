import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/tokenizer_api.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A processing node that tokenizes text chunks using tiktoken on the backend.
///
/// Input:  AA from ChunkNode (row=chunk_id, col="text", val=text).
/// Output: AA of token IDs (row=chunk_id, col="tok:NNNNNN", val=token_id).
///
/// The encoding is configurable (gpt2, cl100k_base, p50k_base) and persisted
/// to workflow params. Tokenization runs automatically when new data arrives.
class TokenizerNode extends BaseNodeWidget {
  final TokenizerApi api;

  const TokenizerNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const TokenizerApi(),
  });

  @override
  State<TokenizerNode> createState() => _TokenizerNodeState();
}

class _TokenizerNodeState extends BaseNodeState<TokenizerNode> {
  @override String   get nodeTitle    => 'Tokenizer';
  @override IconData get nodeIcon     => Icons.token_outlined;
  @override String   get workingLabel => 'tokenizing…';

  final InputPort  _in  = InputPort('chunks');
  final OutputPort _out = OutputPort('tokens');

  AaPayload?       _incoming;
  TokenizeResult?  _lastResult;
  String?          _error;

  static const _encodings = ['gpt2', 'cl100k_base', 'p50k_base', 'p50k_edit'];
  late String _encoding;

  bool get _canRun => _incoming != null && status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    _encoding = widget.initialParams?['encoding'] ?? 'gpt2';
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming   = payload;
      _lastResult = null;
      _error      = null;
    });
    setIdle();
    _run();
  }

  Future<void> _run() async {
    final incoming = _incoming;
    if (incoming == null || status == NodeStatus.working) return;
    setState(() => _error = null);
    setWorking();
    try {
      final result = await widget.api.tokenize(incoming, encoding: _encoding);
      if (!mounted) return;
      _lastResult = result;
      _out.emit(result.aa);
      setComplete();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanError(e));
      setError(e);
    }
  }

  void _saveParams() => saveParams({'encoding': _encoding});

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'chunks',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'tokens',
          idx: 0,
          active: _lastResult != null || widget.connectedOutputs.contains(0),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),

        Row(
          children: [
            Text('Encoding: ', style: theme.textTheme.bodySmall),
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButton<String>(
                value: _encoding,
                isDense: true,
                isExpanded: true,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
                items: _encodings
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: busy
                    ? null
                    : (v) {
                        if (v == null) return;
                        setState(() => _encoding = v);
                        _saveParams();
                        if (_incoming != null) _run();
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canRun ? _run : null,
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 16),
            label: Text(busy ? 'Tokenizing…' : 'Tokenize'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ),
        const SizedBox(height: 6),

        _statusRow(theme, scheme),
      ],
    );
  }

  // Tokenizer uses a custom status row: 7×7 dot, top:3, gap:6, result detail.
  Widget _statusRow(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (status) {
      NodeStatus.idle     => (scheme.outline, 'idle'),
      NodeStatus.working  => (scheme.primary, 'tokenizing…'),
      NodeStatus.complete => (Colors.green,   'complete'),
      NodeStatus.error    => (scheme.error,   'error'),
    };

    final r = _lastResult;
    final detail = status == NodeStatus.error && _error != null
        ? ' · $_error'
        : r != null
            ? '  ${r.chunkCount} chunks · ${r.totalTokens} tokens · vocab ${r.vocabSize}'
            : '';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$label$detail',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
