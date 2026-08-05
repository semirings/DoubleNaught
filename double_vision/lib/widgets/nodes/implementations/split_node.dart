import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/split_api.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

enum _SplitStatus { idle, busy, complete, error }

/// Splits a token AA into train and val subsets by unique row key (chunk_id).
///
/// Input:  AA from TokenizerNode (row=chunk_id, col=tok:N, val=token_id).
/// Output: two AAs on separate ports — train (idx 0) and val (idx 1).
///
/// Config: split ratio (default 80/20), strategy (random/sequential), seed.
/// Splits automatically when new data arrives.
class SplitNode extends StatefulWidget {
  final WorkflowNode node;
  final Map<String, String>? initialParams;
  final void Function(Map<String, String>)? onParams;

  final bool inputConnected;
  final void Function(PortRef source)? onInputConnect;
  final void Function(InputPort port)? onInputPort;
  final void Function(OutputPort port)? onTrainOutputPort;
  final void Function(OutputPort port)? onValOutputPort;
  final Set<int> connectedOutputs;

  final SplitApi api;

  const SplitNode({
    super.key,
    required this.node,
    this.initialParams,
    this.onParams,
    this.inputConnected = false,
    this.onInputConnect,
    this.onInputPort,
    this.onTrainOutputPort,
    this.onValOutputPort,
    this.connectedOutputs = const {},
    this.api = const SplitApi(),
  });

  @override
  State<SplitNode> createState() => _SplitNodeState();
}

class _SplitNodeState extends State<SplitNode> {
  final InputPort _in = InputPort('tokens');
  final OutputPort _trainOut = OutputPort('train');
  final OutputPort _valOut = OutputPort('val');

  AaPayload? _incoming;
  SplitResult? _lastResult;
  _SplitStatus _status = _SplitStatus.idle;
  String? _error;

  late double _ratio;
  late String _strategy;
  late int _seed;

  late final TextEditingController _seedCtrl;

  bool get _canRun =>
      _incoming != null && _status != _SplitStatus.busy;

  @override
  void initState() {
    super.initState();
    final p = widget.initialParams ?? const {};
    _ratio = double.tryParse(p['ratio'] ?? '') ?? 0.8;
    _strategy = p['strategy'] ?? 'random';
    _seed = int.tryParse(p['seed'] ?? '') ?? 42;
    _seedCtrl = TextEditingController(text: '$_seed');

    widget.onInputPort?.call(_in);
    widget.onTrainOutputPort?.call(_trainOut);
    widget.onValOutputPort?.call(_valOut);
    _in.onDataArrived.listen(_onIncoming);
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
      _incoming = payload;
      _status = _SplitStatus.idle;
      _lastResult = null;
      _error = null;
    });
    _run();
  }

  Future<void> _run() async {
    final incoming = _incoming;
    if (incoming == null || _status == _SplitStatus.busy) return;
    setState(() {
      _status = _SplitStatus.busy;
      _error = null;
    });
    try {
      final result = await widget.api.split(
        incoming,
        ratio: _ratio,
        strategy: _strategy,
        seed: _seed,
      );
      if (!mounted) return;
      _lastResult = result;
      _trainOut.emit(result.trainAa);
      _valOut.emit(result.valAa);
      setState(() => _status = _SplitStatus.complete);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      setState(() {
        _status = _SplitStatus.error;
        _error = msg.contains(': ') ? msg.split(': ').skip(1).join(': ') : msg;
      });
    }
  }

  void _saveParams() {
    widget.onParams?.call({
      'ratio': '$_ratio',
      'strategy': _strategy,
      'seed': '$_seed',
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = _status == _SplitStatus.busy;
    final hasOutput = _lastResult != null;

    return DoubleNaughtNodeWrapper(
      title: 'Split',
      icon: Icons.call_split_rounded,
      inputPorts: [
        InputConnector(
          label: 'tokens',
          idx: 0,
          active: widget.inputConnected,
          onConnect: (src) => widget.onInputConnect?.call(src),
        ),
      ],
      outputPorts: [
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
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),

          // Ratio slider
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
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),

          // Strategy + seed
          Row(
            children: [
              Text('Strategy:', style: theme.textTheme.bodySmall),
              const SizedBox(width: 6),
              DropdownButton<String>(
                value: _strategy,
                isDense: true,
                style: theme.textTheme.bodySmall,
                items: const [
                  DropdownMenuItem(value: 'random', child: Text('random')),
                  DropdownMenuItem(
                      value: 'sequential', child: Text('sequential')),
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

          // Split button
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
                  : const Icon(Icons.call_split_rounded, size: 16),
              label: Text(busy ? 'Splitting…' : 'Split'),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Status / result
          _statusRow(theme, scheme),
        ],
      ),
    );
  }

  Widget _statusRow(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (_status) {
      _SplitStatus.idle => (scheme.outline, 'idle'),
      _SplitStatus.busy => (scheme.primary, 'splitting…'),
      _SplitStatus.complete => (Colors.green, 'complete'),
      _SplitStatus.error => (scheme.error, 'error'),
    };

    final r = _lastResult;
    final detail = _status == _SplitStatus.error && _error != null
        ? ' · $_error'
        : r != null
            ? '  train ${r.trainCount} · val ${r.valCount} chunks'
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
