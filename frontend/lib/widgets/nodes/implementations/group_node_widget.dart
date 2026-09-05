import 'package:flutter/material.dart';

import '../../../models/node_group.dart';
import '../../../models/workflow.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A collapsed subgraph on the canvas — see `DESIGN.md` → "Group node".
///
/// Shows what it contains and exposes one port per boundary, so the wires that
/// crossed the selection when it was grouped still land somewhere meaningful.
/// It has no body controls of its own: everything it does is Ungroup, Regroup,
/// and being dragged around as one thing.
///
/// **Collapsed groups do not run.** The children are not mounted while packed, so
/// their info-bus ports do not exist and no payload crosses the boundary. A group
/// is an organisational device; ungroup to execute. That is stated on the card so
/// it cannot be mistaken for a broken pipeline.
class GroupNodeWidget extends BaseNodeWidget {
  /// Which of this group's input boundaries currently have an incoming edge.
  final Set<int> connectedInputs;

  /// Called when an edge is dropped on input boundary [idx].
  final void Function(PortRef source, int idx)? onInputConnectAt;

  const GroupNodeWidget({
    super.key,
    required super.node,
    this.connectedInputs = const {},
    this.onInputConnectAt,
    super.connectedOutputs,
  });

  @override
  State<GroupNodeWidget> createState() => _GroupNodeWidgetState();
}

class _GroupNodeWidgetState extends BaseNodeState<GroupNodeWidget> {
  @override IconData get nodeIcon => Icons.workspaces_outline;
  @override double get nodeWidth => 260;

  @override
  String get nodeTitle => NodeGroup.labelOf(widget.node);

  SubgraphGraph get _subgraph =>
      NodeGroup.subgraphOf(widget.node) ?? const SubgraphGraph();

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        for (final b in _subgraph.inputs)
          InputConnector(
            label: b.label,
            idx: b.idx,
            active: widget.connectedInputs.contains(b.idx),
            onConnect: widget.onInputConnectAt == null
                ? null
                : (source) => widget.onInputConnectAt!(source, b.idx),
          ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        for (final b in _subgraph.outputs)
          OutputConnector(
            label: b.label,
            idx: b.idx,
            active: widget.connectedOutputs.contains(b.idx),
            dragData: PortRef(nodeId: widget.node.id, idx: b.idx),
          ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sub = _subgraph;
    final ports = sub.inputs.length > sub.outputs.length
        ? sub.inputs.length
        : sub.outputs.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(ports.clamp(1, 8))),
        Text(
          '${sub.nodes.length} nodes · ${sub.edges.length} internal wires',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (sub.nodes.isNotEmpty) ...[
          const SizedBox(height: 6),
          // A peek at the contents, so a packed group is identifiable without
          // unpacking it.
          Text(
            sub.nodes.map((n) => n.type).take(6).join(', ') +
                (sub.nodes.length > 6 ? ', …' : ''),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.pause_circle_outline, size: 13, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Packed — ungroup to run (⌘⇧G)',
                style:
                    theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
