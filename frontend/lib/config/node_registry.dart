import 'package:flutter/material.dart';

import '../models/workflow.dart';
import '../widgets/nodes/nodes.dart';

/// The catalog's top-level grouping — see `DESIGN.md` → "Node Catalog".
///
/// [label] heads the accordion; [chip] is the short form on the filter row, where
/// horizontal space is tight.
///
/// Order here is display order, so the categories read as a pipeline: data comes
/// in, code is analysed, output is formatted, models are asked, work is executed,
/// a fine-tune is trained.
enum NodeCategory {
  data('Data & Ingestion', 'Data'),
  code('AST & Code Analysis', 'Code'),
  formatting('Formatting & Serialization', 'Formatting'),
  ai('AI & Teacher Models', 'AI/LLM'),
  compute('Execution & Compute', 'Compute'),
  training('Training & Fine-Tuning', 'Training');

  const NodeCategory(this.label, this.chip);

  final String label;
  final String chip;
}

/// A node kind that can be instantiated from the Node Catalog.
class NodeType {
  /// Human-readable name shown in the catalog (e.g. "File Source").
  final String name;

  /// Persisted [WorkflowNode.type] identifier (e.g. "file_source").
  final String type;

  /// Which accordion this node lives under.
  final NodeCategory category;

  /// One line explaining what the node does. Shown under the name and searched.
  final String description;

  /// Extra search terms — file formats, protocol names, synonyms someone would
  /// plausibly type. Searched alongthe name and description, never displayed, so
  /// a node can be findable by a word that would clutter its card.
  final List<String> tags;

  const NodeType({
    required this.name,
    required this.type,
    required this.category,
    this.description = '',
    this.tags = const [],
  });

  /// Whether this node matches a catalog search for [query].
  ///
  /// Case-insensitive substring match over name, description and tags. A blank
  /// query matches everything.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    if (name.toLowerCase().contains(needle)) return true;
    if (description.toLowerCase().contains(needle)) return true;
    return tags.any((tag) => tag.toLowerCase().contains(needle));
  }
}

/// Registry of available node kinds. Add new entries here (and a case in
/// `_WorkflowPageState._buildNode`) as the `double_*` service nodes land.
///
/// Every entry carries a [NodeCategory]: the catalog groups by it, so an entry
/// without one would be unreachable in the UI — hence it is a required field
/// rather than an optional annotation.
const List<NodeType> nodeTypes = [
  // 'AA → JSONL' (aa2jsonl) was removed here: JSONL formatting is consolidated
  // into 'JSONL Formatter' (jsonlFormatterNode). The widget and the builder case
  // survive so workflows saved before the change still load.

  // ── Data & Ingestion ───────────────────────────────────────────────────────
  NodeType(
    name: 'File Source',
    type: 'file_source',
    category: NodeCategory.data,
    description: 'Read a local file and stream its raw contents.',
    tags: ['ingest', 'disk', 'picker', 'source', 'bytes'],
  ),
  NodeType(
    name: 'URL Source',
    type: 'url_source',
    category: NodeCategory.data,
    description: 'Ingest a remote document by URL.',
    tags: ['ingest', 'http', 'web', 'download', 'source'],
  ),
  NodeType(
    name: 'Load File',
    type: 'load_file',
    category: NodeCategory.data,
    description: 'Load Parquet, Arrow, JSON, CSV or source text as an AA.',
    tags: ['parquet', 'arrow', 'csv', 'json', 'jl', 'read', 'open'],
  ),
  NodeType(
    name: 'Save File',
    type: 'save_file',
    category: NodeCategory.data,
    description: 'Write an AA, text or image to disk.',
    tags: ['export', 'write', 'parquet', 'csv', 'jsonl', 'sink', 'disk'],
  ),
  NodeType(
    name: 'Fetch',
    type: 'fetch',
    category: NodeCategory.data,
    description: 'Retrieve and clean the text of a remote work.',
    tags: ['http', 'scrape', 'clean', 'html', 'web'],
  ),
  NodeType(
    name: 'Inventory',
    type: 'inventory',
    category: NodeCategory.data,
    description: 'Track the corpus of works available to the pipeline.',
    tags: ['catalog', 'corpus', 'registry', 'works'],
  ),
  NodeType(
    name: 'Categorize',
    type: 'categories',
    category: NodeCategory.data,
    description: 'Define the label set a classifier scores against.',
    tags: ['labels', 'taxonomy', 'classes'],
  ),
  NodeType(
    name: 'Preview',
    type: 'preview',
    category: NodeCategory.data,
    description: 'Inspect an AA or byte stream on the canvas.',
    tags: ['inspect', 'table', 'view', 'debug', 'output'],
  ),
  NodeType(
    name: 'Image Display',
    type: 'image_display',
    category: NodeCategory.data,
    description: 'Show an image payload.',
    tags: ['inspect', 'view', 'picture', 'output'],
  ),

  // ── AST & Code Analysis ────────────────────────────────────────────────────
  NodeType(
    name: 'Function Extraction',
    type: 'functionExtractionNode',
    category: NodeCategory.code,
    description: 'Index every function and macro in a Julia file or tree.',
    tags: ['ast', 'parse', 'julia', 'definitions', 'macro', 'docstring', 'symbols'],
  ),

  // ── Formatting & Serialization ─────────────────────────────────────────────
  NodeType(
    name: 'JSONL Formatter',
    type: 'jsonlFormatterNode',
    category: NodeCategory.formatting,
    description: 'Build ChatML, prompt/completion or row JSONL training lines.',
    tags: ['jsonl', 'chatml', 'fine-tune', 'dataset', 'serialize', 'prompt'],
  ),
  NodeType(
    name: 'Chunk',
    type: 'chunk',
    category: NodeCategory.formatting,
    description: 'Split cleaned text into token-bounded passages.',
    tags: ['passages', 'segment', 'tokens', 'window', 'split'],
  ),
  NodeType(
    name: 'Tokenizer',
    type: 'tokenizer',
    category: NodeCategory.formatting,
    description: 'Count tokens per chunk with tiktoken.',
    tags: ['tokens', 'tiktoken', 'count', 'encode'],
  ),

  // ── AI & Teacher Models ────────────────────────────────────────────────────
  NodeType(
    name: 'LLM Documenter',
    type: 'llmDocumenterNode',
    category: NodeCategory.ai,
    description: 'Send a payload to Gemini, Claude, OpenAI or Ollama.',
    tags: ['gemini', 'claude', 'anthropic', 'openai', 'ollama', 'llm', 'teacher', 'api'],
  ),
  NodeType(
    name: 'Secure Settings',
    type: 'secureSettingsNode',
    category: NodeCategory.ai,
    description: 'Hold provider credentials in the OS key vault.',
    tags: ['api key', 'credential', 'vault', 'keychain', 'auth', 'secret'],
  ),
  NodeType(
    name: 'Prompt',
    type: 'promptNode',
    category: NodeCategory.ai,
    description: 'Compose a prompt, optionally seeded from a file.',
    tags: ['prompt', 'instruction', 'compose', 'text'],
  ),
  NodeType(
    name: 'Model Classifier',
    type: 'model_classifier',
    category: NodeCategory.ai,
    description: 'Score documents against candidate labels zero-shot.',
    tags: ['classify', 'zero-shot', 'labels', 'transformers'],
  ),
  NodeType(
    name: 'SAM3',
    type: 'sam3',
    category: NodeCategory.ai,
    description: 'Drive SAM3 segmentation with text or box prompts.',
    tags: ['segment', 'vision', 'mask', 'image', 'sam'],
  ),
  NodeType(
    name: 'Balloon Scrub',
    type: 'balloon_scrub',
    category: NodeCategory.ai,
    description: 'Detect every speech balloon on a comic page and LaMa-scrub '
        'them in one automatic pass.',
    tags: [
      'balloon',
      'bubble',
      'comic',
      'scrub',
      'inpaint',
      'lama',
      'text',
      'remove',
    ],
  ),
  NodeType(
    name: 'Seg Forge',
    type: 'segForgeNode',
    category: NodeCategory.ai,
    description: 'Segment an image in the SegForge app, then emit its '
        'segments and prompt linkage.',
    tags: [
      'segforge',
      'segment',
      'vision',
      'mask',
      'crop',
      'bbox',
      'image',
      'sam',
      'prompt',
      'linkage',
      'external',
    ],
  ),

  // ── Execution & Compute ────────────────────────────────────────────────────
  NodeType(
    name: 'Polyglot Exec',
    type: 'polyglotExecNode',
    category: NodeCategory.compute,
    description: 'Run Julia, Python, JavaScript or Bash source in a subprocess.',
    tags: ['julia', 'python', 'javascript', 'node', 'bash', 'shell', 'run', 'script'],
  ),
  NodeType(
    name: 'D4M',
    type: 'd4m',
    category: NodeCategory.compute,
    description: 'Evaluate D4M associative-array expressions in Julia.',
    tags: ['assoc', 'julia', 'matrix', 'algebra', 'expression', 'query'],
  ),
  NodeType(
    name: 'Start',
    type: 'start',
    category: NodeCategory.compute,
    description: 'Trigger a run from the head of the graph.',
    tags: ['trigger', 'run', 'begin', 'entry'],
  ),

  // ── Training & Fine-Tuning ─────────────────────────────────────────────────
  NodeType(
    name: 'Split',
    type: 'split',
    category: NodeCategory.training,
    description: 'Divide a token AA into train and validation subsets.',
    tags: ['train', 'val', 'dataset', 'holdout', 'partition'],
  ),
  NodeType(
    name: 'Review',
    type: 'review',
    category: NodeCategory.training,
    description: 'Approve, edit or reject passages before they train.',
    tags: ['curate', 'human', 'approve', 'dataset', 'quality'],
  ),
  NodeType(
    name: 'Model Builder',
    type: 'model_builder',
    category: NodeCategory.training,
    description: 'Define and build a GPT-style transformer.',
    tags: ['transformer', 'gpt', 'architecture', 'train', 'slm'],
  ),
  NodeType(
    name: 'Load Model',
    type: 'load_model',
    category: NodeCategory.training,
    description: 'Restore a built model from a checkpoint.',
    tags: ['checkpoint', 'weights', 'restore', 'slm'],
  ),
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
