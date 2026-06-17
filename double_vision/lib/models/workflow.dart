/// Data model for a DoubleNaught workflow graph.
///
/// Mirrors the JSON shape:
/// ```json
/// {
///   "version": "0.1.0",
///   "nodes": [{"id": 1, "type": "double_down", "x": 0, "y": 0}],
///   "edges": [{"from": {"nodeId": 1, "idx": 0}, "to": {"nodeId": 2, "idx": 0}}]
/// }
/// ```
///
/// Classes are immutable; use [copyWith] to derive modified instances. Every
/// type round-trips via `fromJson` / `toJson` so a [Workflow] can be handed
/// straight to `dart:convert`'s `jsonEncode` / `jsonDecode` (and to the local
/// [StorageService] stub).
library;

/// A complete workflow: a versioned set of [nodes] connected by [edges].
class Workflow {
  /// Schema version of this document (e.g. `"0.1.0"`).
  final String version;
  final List<WorkflowNode> nodes;
  final List<WorkflowEdge> edges;

  const Workflow({
    required this.version,
    this.nodes = const [],
    this.edges = const [],
  });

  factory Workflow.fromJson(Map<String, dynamic> json) => Workflow(
        version: json['version'] as String,
        nodes: [
          for (final n in (json['nodes'] as List? ?? const []))
            WorkflowNode.fromJson(n as Map<String, dynamic>),
        ],
        edges: [
          for (final e in (json['edges'] as List? ?? const []))
            WorkflowEdge.fromJson(e as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'nodes': [for (final n in nodes) n.toJson()],
        'edges': [for (final e in edges) e.toJson()],
      };

  Workflow copyWith({
    String? version,
    List<WorkflowNode>? nodes,
    List<WorkflowEdge>? edges,
  }) =>
      Workflow(
        version: version ?? this.version,
        nodes: nodes ?? this.nodes,
        edges: edges ?? this.edges,
      );
}

/// A single node placed on the workflow canvas.
class WorkflowNode {
  /// Unique identifier within the workflow (referenced by [PortRef.nodeId]).
  final int id;

  /// Node kind — typically one of the `double_*` service names
  /// (e.g. `double_down`, `double_mind`, `double_talk`, `double_touch`).
  /// Kept as a free-form string so new node types need no model change.
  final String type;

  /// Canvas position. Stored as `double` since layout is continuous; the
  /// sample's integer literals (`0`) decode cleanly.
  final double x;
  final double y;

  const WorkflowNode({
    required this.id,
    required this.type,
    this.x = 0,
    this.y = 0,
  });

  factory WorkflowNode.fromJson(Map<String, dynamic> json) => WorkflowNode(
        id: json['id'] as int,
        type: json['type'] as String,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
      };

  WorkflowNode copyWith({int? id, String? type, double? x, double? y}) =>
      WorkflowNode(
        id: id ?? this.id,
        type: type ?? this.type,
        x: x ?? this.x,
        y: y ?? this.y,
      );
}

/// A directed connection between two node ports.
class WorkflowEdge {
  final PortRef from;
  final PortRef to;

  const WorkflowEdge({required this.from, required this.to});

  factory WorkflowEdge.fromJson(Map<String, dynamic> json) => WorkflowEdge(
        from: PortRef.fromJson(json['from'] as Map<String, dynamic>),
        to: PortRef.fromJson(json['to'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'from': from.toJson(),
        'to': to.toJson(),
      };

  WorkflowEdge copyWith({PortRef? from, PortRef? to}) =>
      WorkflowEdge(from: from ?? this.from, to: to ?? this.to);
}

/// A reference to a specific port on a node: which node ([nodeId]) and which
/// port slot ([idx]) on that node.
class PortRef {
  final int nodeId;
  final int idx;

  const PortRef({required this.nodeId, required this.idx});

  factory PortRef.fromJson(Map<String, dynamic> json) => PortRef(
        nodeId: json['nodeId'] as int,
        idx: json['idx'] as int,
      );

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'idx': idx,
      };

  PortRef copyWith({int? nodeId, int? idx}) =>
      PortRef(nodeId: nodeId ?? this.nodeId, idx: idx ?? this.idx);
}
