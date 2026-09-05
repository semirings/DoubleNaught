import 'package:flutter/material.dart';

import '../../../models/workflow.dart';
import 'base_node.dart' show kPortRowHeight;
import 'connection_drag_scope.dart';

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

    // Output label sits to the LEFT of the dot (right-aligned toward the edge).
    // Fixed-height slot: the wrapper centers it on the port anchor, so the dot's
    // center coincides with the connected noodle's endpoint.
    final content = SizedBox(
      height: kPortRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(width: 6),
            dot,
          ],
        ),
      ),
    );

    if (dragData != null) {
      final scope = ConnectionDragScope.of(context);
      // The whole label+dot is the drag target, not just the 14px dot, so an
      // edge is easy to grab.
      return Draggable<PortRef>(
        data: dragData,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        // Drive the canvas's live preview curve (edge creation itself is still
        // handled by the input port's DragTarget).
        onDragStarted: () => scope?.onDragStart(dragData!),
        onDragUpdate: (d) => scope?.onDragUpdate(d.globalPosition),
        onDragEnd: (_) => scope?.onDragEnd(),
        onDraggableCanceled: (_, __) => scope?.onDragEnd(),
        feedback: _DragDot(color: scheme.primary),
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: content),
      );
    }

    // mouseCursor overrides InkWell's default pointer/hand — output port
    // dots are not "buttons"; keep the arrow so the UI is consistent with
    // input ports (only the drag handle itself uses SystemMouseCursors.grab).
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.basic,
      borderRadius: BorderRadius.circular(12),
      child: content,
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
