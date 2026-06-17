import 'package:flutter/material.dart';

import '../models/workflow.dart';

/// A node's output port: a labelled connector dot on the right edge of a node.
/// When [dragData] is supplied the dot becomes a drag source — dragging it onto
/// an [InputConnector] creates a [WorkflowEdge] (see `workflow_page.dart`).
class OutputConnector extends StatelessWidget {
  /// Port label, e.g. `"contents"`.
  final String label;

  /// Whether the port currently has data available to stream.
  final bool active;

  /// Output slot index on the owning node (`PortRef.idx`).
  final int idx;

  /// Optional tap handler (e.g. to start/preview the stream).
  final VoidCallback? onTap;

  /// When non-null, the dot is draggable and carries this port reference as the
  /// edge's source endpoint.
  final PortRef? dragData;

  const OutputConnector({
    super.key,
    required this.label,
    this.active = false,
    this.idx = 0,
    this.onTap,
    this.dragData,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.outline;

    final dot = Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? color : scheme.surface,
        border: Border.all(color: color, width: 2),
      ),
    );

    Widget portDot = dot;
    if (dragData != null) {
      portDot = Draggable<PortRef>(
        data: dragData,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _DragDot(color: scheme.primary),
        child: dot,
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(width: 6),
            portDot,
          ],
        ),
      ),
    );
  }
}

/// The little dot that follows the pointer while dragging an edge.
class _DragDot extends StatelessWidget {
  final Color color;
  const _DragDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}
