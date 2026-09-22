import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/split_api.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// Splits a token AA into train and val subsets by unique row key (chunk_id).
///
/// Input:  AA from TokenizerNode (row=chunk_id, col=tok:N, val=token_id).
/// Output: two AAs on separate ports — train (idx 0) and val (idx 1).
///
/// Config: split ratio (default 80/20), strategy (random/sequential), seed.
/// Splits automatically when new data arrives.
class SplitNode extends BaseNodeWidget {
  final void Function(OutputPort port)? onTrainOutputPort;
  final void Function(OutputPort port)? onValOutputPort;
  final SplitApi api;

  const SplitNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.connectedOutputs,
    this.onTrainOutputPort,
    this.onValOutputPort,
    this.api = const SplitApi(),
  });

  @override
  State<SplitNode> createState() => _SplitNodeState();
}

class _SplitNodeState extends BaseNodeState<SplitNode> {
  @override String   get nodeTitle    => 'Split';
  @override IconData get nodeIcon     => Icons.call_split_rounded;
  @override String   get workingLabel => 'splitting…';

  final InputPort  _in       = InputPort('tokens');
  final OutputPort _trainOut = OutputPort('train');
  final OutputPort _valOut   = OutputPort('val');

  AaPayload?  _incoming;
  SplitResult? _lastResult;
  String?      _error;

  late double _ratio;
  late String _strategy;
  late int    _seed;

  late final TextEditingController _seedCtrl;

  bool get _canRun =>
      _incoming != null && status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    final p = widget.initialParams ?? const {};
    _ratio    = double.tryParse(p['ratio']    ?? '') ?? 0.8;
    _strategy = p['strategy'] ?? 'random';
    _seed     = int.tryParse(p['seed']        ?? '') ?? 42;
    _seedCtrl = TextEditingController(text: '$_seed');

    initInputPort(_in, _onIncoming);
    widget.onTrainOutputPort?.call(_trainOut);
    widget.onValOutputPort?.call(_valOut);
  }

  @override
  void dispose() {
    _seedCtrl.dispose();
    _in.dispose();
    _trainOut.dispose();
    _valOut.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming    = payload;
      _lastResult  = null;
      _error       = null;
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
      final result = await widget.api.split(
        incoming,
        ratio:    _ratio,
        strategy: _strategy,
        seed:     _seed,
      );
      if (!mounted) return;
      _lastResult = result;
      _trainOut.emit(result.trainAa);
      _valOut.emit(result.valAa);
      setComplete();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanError(e));
      setError(e);
    }
  }

  void _saveParams() => saveParams({
        'ratio':    '$_ratio',
        'strategy': _strategy,
        'seed':     '$_seed',
      });

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'tokens'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) {
    final hasOutput = _lastResult != null;
    return [
      OutputConnector(
        label: 'train',
        idx: 0,
        active: hasOutput || widget.connectedOutputs.contains(0),
        dragData: PortRef(nodeId: widget.node.id, idx: 0),
      ),
      OutputConnector(
        label: 'val',
        idx: 1,
        active: hasOutput || widget.connectedOutputs.contains(1),
        dragData: PortRef(nodeId: widget.node.id, idx: 1),
      ),
    ];
  }

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme  = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy   = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),

        Row(
          children: [
            Text('Train ratio:', style: theme.textTheme.bodySmall),
            Expanded(
              child: Slider(
                value: _ratio,
                min: 0.5,
                max: 0.95,
                divisions: 9,
                label: '${(_ratio * 100).round()}%',
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() => _ratio = (v * 20).round() / 20);
                        _saveParams();
                      },
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${(_ratio * 100).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),

        Row(
          children: [
            Text('Strategy:', style: theme.textTheme.bodySmall),
            const SizedBox(width: 6),
            DropdownButton<String>(
              value: _strategy,
              isDense: true,
              style: theme.textTheme.bodySmall,
              items: const [
                DropdownMenuItem(value: 'random',     child: Text('random')),
                DropdownMenuItem(value: 'sequential', child: Text('sequential')),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _strategy = v);
                      _saveParams();
                    },
            ),
            const Spacer(),
            Text('Seed:', style: theme.textTheme.bodySmall),
            const SizedBox(width: 4),
            SizedBox(
              width: 52,
              child: TextField(
                controller: _seedCtrl,
                enabled: !busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                ),
                onChanged: (v) {
                  _seed = int.tryParse(v) ?? _seed;
                  _saveParams();
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
                ? busyIcon()
                : const Icon(Icons.call_split_rounded, size: 16),
            label: Text(busy ? 'Splitting…' : 'Split'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ),
        const SizedBox(height: 6),

        _splitStatusRow(theme, scheme),
      ],
    );
  }

  // 7×7 dot, top:3, gap:6 — also shows train/val counts
  Widget _splitStatusRow(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (status) {
      NodeStatus.idle     => (scheme.outline, 'idle'),
      NodeStatus.working  => (scheme.primary, 'splitting…'),
      NodeStatus.complete => (Colors.green,   'complete'),
      NodeStatus.error    => (scheme.error,   'error'),
    };

    final r = _lastResult;
    final detail = status == NodeStatus.error && _error != null
        ? ' · $_error'
        : r != null
            ? '  train ${r.trainCount} · val ${r.valCount} chunks'
            : '';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 7, height: 7,
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
