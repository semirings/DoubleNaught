import 'dart:convert';

import 'workflow.dart';

/// One port on a collapsed group node, proxying a port on a node inside it.
///
/// This is the `GroupInputNode` / `GroupOutputNode` role from the spec, expressed
/// as data rather than as a node: a boundary is just the mapping
/// `group port idx ⇄ inner child port`, which is all an edge needs to be
/// re-pointed in either direction.
class GroupBoundary {
  /// Port index on the group node — inputs and outputs are numbered separately,
  /// matching the left/right port lanes of every other node.
  final int idx;

  /// The child port this proxies.
  final PortRef inner;

  /// What the group card shows beside the dot.
  final String label;

  const GroupBoundary({
    required this.idx,
    required this.inner,
    required this.label,
  });

  factory GroupBoundary.fromJson(Map<String, dynamic> json) => GroupBoundary(
        idx: json['idx'] as int,
        inner: PortRef.fromJson(json['inner'] as Map<String, dynamic>),
        label: json['label'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'idx': idx,
        'inner': inner.toJson(),
        'label': label,
      };
}

/// The graph held inside a group node.
///
/// [nodes] carry positions **relative to the group node**, so moving the group
/// moves its contents for free and ungrouping is one addition per child
/// (`group position + relative position`). [edges] are the connections wholly
/// inside; edges that crossed the boundary at group time became [inputs] /
/// [outputs] instead.
class SubgraphGraph {
  final List<WorkflowNode> nodes;
  final List<WorkflowEdge> edges;
  final List<GroupBoundary> inputs;
  final List<GroupBoundary> outputs;

  const SubgraphGraph({
    this.nodes = const [],
    this.edges = const [],
    this.inputs = const [],
    this.outputs = const [],
  });

  factory SubgraphGraph.fromJson(Map<String, dynamic> json) => SubgraphGraph(
        nodes: [
          for (final n in (json['nodes'] as List? ?? const []))
            WorkflowNode.fromJson(n as Map<String, dynamic>),
        ],
        edges: [
          for (final e in (json['edges'] as List? ?? const []))
            WorkflowEdge.fromJson(e as Map<String, dynamic>),
        ],
        inputs: [
          for (final b in (json['inputs'] as List? ?? const []))
            GroupBoundary.fromJson(b as Map<String, dynamic>),
        ],
        outputs: [
          for (final b in (json['outputs'] as List? ?? const []))
            GroupBoundary.fromJson(b as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'nodes': [for (final n in nodes) n.toJson()],
        'edges': [for (final e in edges) e.toJson()],
        'inputs': [for (final b in inputs) b.toJson()],
        'outputs': [for (final b in outputs) b.toJson()],
      };
}

/// Group-node conventions: the type string, and how a subgraph rides along in
/// the node's `params`.
///
/// Storing the subgraph as JSON in `params` means a group persists through the
/// existing save/load path with no change to [Workflow] — `params` is already
/// "the node's saved settings", and for a group the contents *are* the setting.
/// It also keeps one source of truth: there is no parallel map on the canvas to
/// drift out of step with `_nodes`.
abstract final class NodeGroup {
  static const String type = 'groupNode';

  /// `params` key holding the encoded [SubgraphGraph].
  static const String subgraphKey = 'subgraph';

  /// `params` key holding the user-visible group name.
  static const String labelKey = 'label';

  static bool isGroup(WorkflowNode node) => node.type == type;

  /// The subgraph inside [node], or null when it is not a group (or its params
  /// are unreadable — a hand-edited workflow file should not crash the canvas).
  static SubgraphGraph? subgraphOf(WorkflowNode node) {
    final raw = node.params[subgraphKey];
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? SubgraphGraph.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }

  static String labelOf(WorkflowNode node) =>
      node.params[labelKey]?.isNotEmpty == true
          ? node.params[labelKey]!
          : 'Group';

  /// A group node carrying [subgraph]. Params are otherwise untouched, so a
  /// regrouped container keeps whatever else it was storing.
  static WorkflowNode withSubgraph(
    WorkflowNode node,
    SubgraphGraph subgraph, {
    String? label,
  }) =>
      node.copyWith(
        params: {
          ...node.params,
          subgraphKey: jsonEncode(subgraph.toJson()),
          if (label != null) labelKey: label,
        },
      );
}
