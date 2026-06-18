import 'package:flutter/material.dart';

import '../models/workflow.dart';
import '../widgets/base_node.dart';

/// A node kind that can be instantiated from the Workflow header dropdown.
class NodeType {
  /// Human-readable name shown in the dropdown (e.g. "File Source").
  final String name;

  /// Persisted [WorkflowNode.type] identifier (e.g. "file_source").
  final String type;

  const NodeType({required this.name, required this.type});
}

/// Registry of available node kinds. Add new entries here (and a case in
/// `_WorkflowPageState._buildNode`) as the `double_*` service nodes land.
const List<NodeType> nodeTypes = [
  NodeType(name: 'File Source', type: 'file_source'),
  NodeType(name: 'Preview', type: 'preview'),
  NodeType(name: 'SAM3 Control', type: 'sam3'),
];

/// Fallback card for a registered-but-not-yet-implemented node type. Extends
/// [BaseNode] so it inherits the Base Node Blueprint chrome for free.
class PlaceholderNode extends BaseNode {
  final WorkflowNode node;
  const PlaceholderNode({super.key, required this.node});

  @override
  String get title => node.type;

  @override
  IconData get icon => Icons.help_outline;

  @override
  Widget buildBody(BuildContext context) => Text(
        '(not implemented)',
        style: Theme.of(context).textTheme.bodySmall,
      );
}
