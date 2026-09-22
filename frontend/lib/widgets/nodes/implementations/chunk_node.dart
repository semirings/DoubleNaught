import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/chunk_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A workflow processing node (AA-in → AA-out) that applies author-aware or
/// generic boundary-aware chunking on the backend.
///
/// Three strategies are selectable:
/// - **Author** (default) — existing author-registry path.
/// - **Paragraph / Sentence** — boundary-aware; configurable max tokens,
///   stride, and EOT injection.
/// - **Character Count** — fixed-window fallback; configurable max chars
///   and stride.
class ChunkNode extends BaseNodeWidget {
  final ChunkApi api;

  const ChunkNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const ChunkApi(),
  });

  @override
  State<ChunkNode> createState() => _ChunkNodeState();
}

class _ChunkNodeState extends BaseNodeState<ChunkNode> {
  @override String   get nodeTitle    => 'Chunk';
  @override IconData get nodeIcon     => Icons.segment;
  @override String   get workingLabel => 'chunking';

  final InputPort _in  = InputPort('text');
  final OutputPort _out = OutputPort('chunks');

  AaPayload? _incoming;
  AaPayload? _lastOutput;
  ChunkStats? _stats;

  late ChunkConfig _config;

  late final TextEditingController _maxTokensCtrl;
  late final TextEditingController _maxCharsCtrl;
  late final TextEditingController _strideCtrl;

  bool get _canChunk => _incoming != null && status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    _config = widget.initialParams != null && widget.initialParams!.isNotEmpty
        ? ChunkConfig.fromParams(widget.initialParams!)
        : const ChunkConfig();
    _maxTokensCtrl = TextEditingController(text: '${_config.maxTokens}');
    _maxCharsCtrl  = TextEditingController(text: '${_config.maxChars}');
    _strideCtrl    = TextEditingController(text: '${_config.stride}');
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _maxTokensCtrl.dispose();
    _maxCharsCtrl.dispose();
    _strideCtrl.dispose();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _stats = null;
    });
    setIdle();
    _chunk();
  }

  ChunkConfig _configFromFields() => _config.copyWith(
        maxTokens: int.tryParse(_maxTokensCtrl.text) ?? _config.maxTokens,
        maxChars:  int.tryParse(_maxCharsCtrl.text)  ?? _config.maxChars,
        stride:    int.tryParse(_strideCtrl.text)    ?? _config.stride,
      );

  void _saveParams() => saveParams(_configFromFields().toParams());

  Future<void> _chunk() async {
    final incoming = _incoming;
    if (incoming == null || status == NodeStatus.working) return;
    final config = _configFromFields();
    setState(() => _config = config);
    setWorking();
    _saveParams();
    try {
      final result = await widget.api.chunk(incoming, config: config);
      if (!mounted) return;
      _lastOutput = result.aa;
      _out.emit(result.aa);
      setState(() => _stats = result.stats);
      setComplete();
    } catch (e) {
      if (!mounted) return;
      setError(e);
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'text',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'aaOut',
          idx: 0,
          active: _lastOutput != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        _upstreamInfo(theme),
        const SizedBox(height: 10),

        _strategyRow(theme, busy),
        const SizedBox(height: 6),

        if (_config.strategy == ChunkStrategy.paragraphSentence) ...[
          _intField('Max tokens', _maxTokensCtrl, busy),
          _intField('Stride (tokens)', _strideCtrl, busy),
          _eotToggle(theme, busy),
          const SizedBox(height: 4),
        ] else if (_config.strategy == ChunkStrategy.characterCount) ...[
          _intField('Max chars', _maxCharsCtrl, busy),
          _intField('Stride (chars)', _strideCtrl, busy),
          const SizedBox(height: 4),
        ],

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canChunk ? _chunk : null,
            icon: busy ? busyIcon() : const Icon(Icons.segment, size: 18),
            label: const Text('Chunk'),
          ),
        ),
        if (_stats != null) ...[
          const SizedBox(height: 10),
          _statsPanel(theme, _stats!),
        ],
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  // ── Sub-builders ─────────────────────────────────────────────────────────

  Widget _strategyRow(ThemeData theme, bool busy) {
    const items = [
      DropdownMenuItem(value: ChunkStrategy.author,           child: Text('Author')),
      DropdownMenuItem(value: ChunkStrategy.paragraphSentence, child: Text('Para / Sentence')),
      DropdownMenuItem(value: ChunkStrategy.characterCount,   child: Text('Char Count')),
    ];
    return Row(
      children: [
        Text('Strategy:', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<ChunkStrategy>(
            value: _config.strategy,
            isDense: true,
            isExpanded: true,
            style: theme.textTheme.bodySmall,
            items: items,
            onChanged: busy
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => _config = _config.copyWith(strategy: v));
                    _saveParams();
                  },
          ),
        ),
      ],
    );
  }

  Widget _intField(String label, TextEditingController ctrl, bool busy) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
              onChanged: (_) => _saveParams(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _eotToggle(ThemeData theme, bool busy) {
    return Row(
      children: [
        Text('Inject EOT', style: theme.textTheme.bodySmall),
        const Spacer(),
        Switch(
          value: _config.injectEot,
          onChanged: busy
              ? null
              : (v) {
                  setState(() => _config = _config.copyWith(injectEot: v));
                  _saveParams();
                },
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a Fetch node',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final author    = incoming.value('author');
    final workTitle = incoming.value('work_title');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (workTitle != null && workTitle.isNotEmpty) ? workTitle : '(untitled)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (author != null && author.isNotEmpty)
          Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _statsPanel(ThemeData theme, ChunkStats stats) {
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${stats.chunkCount} chunks',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'tokens: ${stats.totalTokens} total · '
            '${stats.meanTokens.toStringAsFixed(0)} avg · '
            '${stats.minTokens}–${stats.maxTokens} range',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
