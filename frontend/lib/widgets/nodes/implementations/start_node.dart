import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// The **Start** execution catalyst: a source node whose inline `Go` button
/// kicks off the reactive pipeline. Pressing `Go` emits a trigger [AaPayload] on
/// its `trigger` output — driving any downstream AA consumer (e.g. LoadModel) —
/// and (optionally) asks the canvas to resolve/run the graph. The button shows a
/// `Running…` state while a run is in flight.
class StartNode extends BaseNodeWidget {
  /// Optional canvas run hook (the header's "Go" evaluation). Awaited so the
  /// button reflects the run's duration.
  final Future<void> Function()? onRun;

  const StartNode({
    super.key,
    required super.node,
    super.onOutputPort,
    super.connectedOutputs,
    this.onRun,
  });

  @override
  State<StartNode> createState() => _StartNodeState();
}

class _StartNodeState extends BaseNodeState<StartNode> {
  @override String   get nodeTitle => 'Start';
  @override IconData get nodeIcon  => Icons.play_circle_outline;

  final OutputPort _out = OutputPort('trigger');

  bool _running = false;
  int  _fires   = 0;

  static const _goColor = Color(0xFF43A047);

  @override
  void initState() {
    super.initState();
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_running) return;
    setState(() => _running = true);
    _out.emit(
      AaPayload(
        rows: const ['trigger'],
        cols: const ['signal', 'timestamp'],
        vals: ['go', DateTime.now().toUtc().toIso8601String()],
      ),
    );
    setState(() => _fires++);
    try {
      await widget.onRun?.call();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'trigger',
          idx: 0,
          active: _fires > 0 || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Kick off the pipeline from here.', style: muted),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _running ? null : _go,
            style: FilledButton.styleFrom(
              backgroundColor: _goColor,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _goColor.withValues(alpha: 0.5),
              disabledForegroundColor: Colors.white70,
            ),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(_running ? 'Running…' : 'Go'),
          ),
        ),
        if (_fires > 0) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.bolt, size: 14, color: _goColor),
              const SizedBox(width: 6),
              Text('Triggered $_fires time(s)', style: muted),
            ],
          ),
        ],
      ],
    );
  }
}
