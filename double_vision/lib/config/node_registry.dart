import 'package:flutter/material.dart';

import '../models/workflow.dart';

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
];

/// Fallback card for a registered-but-not-yet-implemented node type.
class PlaceholderNode extends StatelessWidget {
  final WorkflowNode node;
  const PlaceholderNode({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('${node.type}\n(not implemented)',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}
