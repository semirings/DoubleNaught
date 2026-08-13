import 'package:flutter/material.dart';

import '../models/workflow.dart';
import '../widgets/nodes/nodes.dart';

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
  NodeType(name: 'AA → JSONL',          type: 'aa2jsonl'),
  NodeType(name: 'AA Binary Normalizer', type: 'aa_binary_normalizer'),
  NodeType(name: 'Categories', type: 'categories'),
  NodeType(name: 'Chunk', type: 'chunk'),
  NodeType(name: 'D4M', type: 'd4m'),
  NodeType(name: 'Fetch', type: 'fetch'),
  NodeType(name: 'File Source', type: 'file_source'),
  NodeType(name: 'Image Display', type: 'image_display'),
  NodeType(name: 'Inventory', type: 'inventory'),
  // Camel-case type per the JSONL Formatter spec in DESIGN.md.
  NodeType(name: 'JSONL Formatter', type: 'jsonlFormatterNode'),
  NodeType(name: 'Load File', type: 'load_file'),
  NodeType(name: 'Load Model', type: 'load_model'),
  NodeType(name: 'Model Builder', type: 'model_builder'),
  NodeType(name: 'Model Classifier', type: 'model_classifier'),
  NodeType(name: 'Preview', type: 'preview'),
  // Camel-case type per the Polyglot Exec spec in DESIGN.md.
  NodeType(name: 'Polyglot Exec', type: 'polyglotExecNode'),
  // Camel-case type per the Prompt Node spec in DESIGN.md; the rest of this
  // registry predates that convention.
  NodeType(name: 'Prompt Node', type: 'promptNode'),
  // Camel-case type per the Remote Service spec in DESIGN.md.
  NodeType(name: 'Remote Service', type: 'remoteServiceNode'),
  NodeType(name: 'Review', type: 'review'),
  NodeType(name: 'SAM3 Control', type: 'sam3'),
  NodeType(name: 'Save File', type: 'save_file'),
  // Camel-case type per the Secure Settings spec in DESIGN.md.
  NodeType(name: 'Secure Settings', type: 'secureSettingsNode'),
  NodeType(name: 'Split', type: 'split'),
  NodeType(name: 'Start', type: 'start'),
  NodeType(name: 'Text Inference', type: 'text_inference'),
  NodeType(name: 'Text Model Loader', type: 'text_model_loader'),
  NodeType(name: 'Text Preview', type: 'text_preview'),
  NodeType(name: 'Text Prompt', type: 'text_prompt'),
  NodeType(name: 'Tokenizer', type: 'tokenizer'),
  NodeType(name: 'URL Source', type: 'url_source'),
];

/// Fallback card shown when a workflow file references a node type that has no
/// registered implementation in this build.
class PlaceholderNode extends BaseNodeWidget {
  const PlaceholderNode({super.key, required super.node});

  @override
  State<PlaceholderNode> createState() => _PlaceholderNodeState();
}

class _PlaceholderNodeState extends BaseNodeState<PlaceholderNode> {
  @override
  String get nodeTitle => widget.node.type;

  @override
  IconData get nodeIcon => Icons.help_outline;

  @override
  Widget buildNodeBody(BuildContext context) =>
      Text('(not implemented)', style: Theme.of(context).textTheme.bodySmall);
}
