import 'package:flutter/material.dart';

import '../../../models/workflow.dart';
import 'base_node.dart' show kPortRowHeight;

/// A node's input port: a labelled connector dot on the left edge of a node.
/// Acts as a drop target for an [OutputConnector] drag — when an output
/// [PortRef] is dropped here, [onConnect] is called with that source endpoint
/// so the canvas can record a [WorkflowEdge].
class InputConnector extends StatelessWidget {
  final String label;

  /// Input slot index on the owning node (`PortRef.idx`).
  final int idx;

  /// Whether this input is currently wired to an upstream output.
  final bool active;

  /// Called with the dragged output endpoint when an edge is dropped here.
  final void Function(PortRef source)? onConnect;

  const InputConnector({
    super.key,
    required this.label,
    this.idx = 0,
    this.active = false,
    this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DragTarget<PortRef>(
      onAcceptWithDetails: (details) => onConnect?.call(details.data),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        final color = (active || hovering) ? scheme.primary : scheme.outline;
        // MouseRegion overrides any click-cursor that Material ancestors emit
        // — ports are drop targets, not tappable buttons.
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: SizedBox(
            // The visible slot is kPortRowHeight tall. A trailing invisible
            // extension pushes the DragTarget's hit area 80px rightward into
            // the node body, so users don't have to aim at the 14px dot.
            height: kPortRowHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (active || hovering) ? color : scheme.surface,
                      border: Border.all(color: color, width: 2),
                      // Glow while a compatible output is dragged over this
                      // port — visual confirmation the connection will land.
                      boxShadow: hovering
                          ? [
                              BoxShadow(
                                color: scheme.primary,
                                blurRadius: 8,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
                  // Invisible extension — widens the drop zone without
                  // changing what the user sees.
                  const SizedBox(width: 80),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
