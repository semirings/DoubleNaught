import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/tokenizer_api.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

enum _TokenizerStatus { idle, busy, complete, error }

/// A processing node that tokenizes text chunks using tiktoken on the backend.
///
/// Input:  AA from ChunkNode (row=chunk_id, col="text", val=text).
/// Output: AA of token IDs (row=chunk_id, col="tok:NNNNNN", val=token_id).
///
/// The encoding is configurable (gpt2, cl100k_base, p50k_base) and persisted
/// to workflow params. Tokenization runs automatically when new data arrives.
class TokenizerNode extends StatefulWidget {
  final WorkflowNode node;
  final Map<String, String>? initialParams;
  final void Function(Map<String, String>)? onParams;

  final bool inputConnected;
  final void Function(PortRef source)? onInputConnect;
  final void Function(InputPort port)? onInputPort;
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  final TokenizerApi api;

  const TokenizerNode({
    super.key,
    required this.node,
    this.initialParams,
    this.onParams,
    this.inputConnected = false,
    this.onInputConnect,
    this.onInputPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.api = const TokenizerApi(),
  });

  @override
  State<TokenizerNode> createState() => _TokenizerNodeState();
}

class _TokenizerNodeState extends State<TokenizerNode> {
  final InputPort _in = InputPort('chunks');
  final OutputPort _out = OutputPort('tokens');

  AaPayload? _incoming;
  TokenizeResult? _lastResult;
  _TokenizerStatus _status = _TokenizerStatus.idle;
  String? _error;

  late String _encoding;

  static const _encodings = ['gpt2', 'cl100k_base', 'p50k_base', 'p50k_edit'];

  bool get _canRun =>
      _incoming != null && _status != _TokenizerStatus.busy;

  @override
  void initState() {
    super.initState();
    _encoding = widget.initialParams?['encoding'] ?? 'gpt2';
    widget.onInputPort?.call(_in);
    widget.onOutputPort?.call(_out);
    _in.onDataArrived.listen(_onIncoming);
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
      _incoming = payload;
      _status = _TokenizerStatus.idle;
      _lastResult = null;
      _error = null;
    });
    _run();
  }

  Future<void> _run() async {
    final incoming = _incoming;
    if (incoming == null || _status == _TokenizerStatus.busy) return;
    setState(() {
      _status = _TokenizerStatus.busy;
      _error = null;
    });
    try {
      final result = await widget.api.tokenize(incoming, encoding: _encoding);
      if (!mounted) return;
      _lastResult = result;
      _out.emit(result.aa);
      setState(() => _status = _TokenizerStatus.complete);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      setState(() {
        _status = _TokenizerStatus.error;
        _error = msg.contains(': ') ? msg.split(': ').skip(1).join(': ') : msg;
      });
    }
  }

  void _saveParams() {
    widget.onParams?.call({'encoding': _encoding});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasOutput = _lastResult != null;

    return DoubleNaughtNodeWrapper(
      title: 'Tokenizer',
      icon: Icons.token_outlined,
      inputPorts: [
        InputConnector(
          label: 'chunks',
          idx: 0,
          active: widget.inputConnected,
          onConnect: (src) => widget.onInputConnect?.call(src),
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'tokens',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),

          // Encoding selector
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
                  onChanged: _status == _TokenizerStatus.busy
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

          // Re-run button (auto-runs on data arrival, but user can re-trigger)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canRun ? _run : null,
              icon: _status == _TokenizerStatus.busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 16),
              label: Text(
                _status == _TokenizerStatus.busy ? 'Tokenizing…' : 'Tokenize',
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Status / stats
          _statusRow(theme, scheme),
        ],
      ),
    );
  }

  Widget _statusRow(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (_status) {
      _TokenizerStatus.idle => (scheme.outline, 'idle'),
      _TokenizerStatus.busy => (scheme.primary, 'tokenizing…'),
      _TokenizerStatus.complete => (Colors.green, 'complete'),
      _TokenizerStatus.error => (scheme.error, 'error'),
    };

    final r = _lastResult;
    final detail = _status == _TokenizerStatus.error && _error != null
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
