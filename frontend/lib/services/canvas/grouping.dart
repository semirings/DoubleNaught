import '../../models/node_group.dart';
import '../../models/workflow.dart';

/// A canvas graph after a group or ungroup — the whole result, so the caller
/// swaps state once rather than mutating in steps.
class GroupingResult {
  final List<WorkflowNode> nodes;
  final List<WorkflowEdge> edges;

  /// Ids the caller should leave selected. After grouping, the container; after
  /// ungrouping, the unpacked children (per the spec's "keep the unpacked child
  /// nodes selected").
  final Set<int> selection;

  const GroupingResult({
    required this.nodes,
    required this.edges,
    required this.selection,
  });
}

/// Collapse and expand a set of canvas nodes — see `DESIGN.md` → "Group node".
///
/// Pure functions over `(nodes, edges, selection)`: no widgets, no `setState`,
/// nothing async. The canvas calls these and assigns the result, which is what
/// makes the edge-remapping rules testable in isolation — they are the part that
/// silently loses connections if it is wrong.
abstract final class Grouping {
  /// Collapse [selection] into one group node.
  ///
  /// * The group sits at the selection's top-left, and children are stored
  ///   relative to it.
  /// * Edges wholly inside move into the subgraph.
  /// * Edges crossing the boundary become group ports: an external source
  ///   feeding a child becomes an **input**, a child feeding an external target
  ///   becomes an **output**, and the external edge is re-pointed at the group.
  ///   Several external sources into one child port share a single input port,
  ///   because they address the same destination.
  /// * Edges wholly outside are untouched.
  ///
  /// [reuseId], [atX]/[atY] and [label] let a regroup rebuild the same container
  /// in the same place; otherwise [newId] is used and the position is derived.
  ///
  /// Returns null when [selection] has fewer than two nodes, or names a node
  /// that is not on the canvas — a group of one is just a node, and a group of
  /// phantoms is a bug worth surfacing as "nothing happened".
  static GroupingResult? group({
    required List<WorkflowNode> nodes,
    required List<WorkflowEdge> edges,
    required Set<int> selection,
    required int newId,
    int? reuseId,
    double? atX,
    double? atY,
    String? label,
  }) {
    if (selection.length < 2) return null;
    final byId = {for (final n in nodes) n.id: n};
    if (!selection.every(byId.containsKey)) return null;

    final members = [
      for (final n in nodes)
        if (selection.contains(n.id)) n,
    ];
    final groupId = reuseId ?? newId;
    final originX = atX ?? members.map((n) => n.x).reduce(_min);
    final originY = atY ?? members.map((n) => n.y).reduce(_min);

    // Children hold positions relative to the container.
    final children = [
      for (final n in members) n.copyWith(x: n.x - originX, y: n.y - originY),
    ];

    final internal = <WorkflowEdge>[];
    final external = <WorkflowEdge>[];
    final inputs = <String, GroupBoundary>{};
    final outputs = <String, GroupBoundary>{};
    final remapped = <WorkflowEdge>[];

    // Stable boundary numbering: sorting by (child id, port idx) means the same
    // selection always produces the same port order, so a group/ungroup/regroup
    // cycle does not shuffle a user's wires.
    String key(PortRef p) => '${p.nodeId}:${p.idx}';
    final crossingIn = <PortRef>[];
    final crossingOut = <PortRef>[];

    for (final e in edges) {
      final fromInside = selection.contains(e.from.nodeId);
      final toInside = selection.contains(e.to.nodeId);
      if (fromInside && toInside) {
        internal.add(e);
      } else if (toInside) {
        crossingIn.add(e.to);
        external.add(e);
      } else if (fromInside) {
        crossingOut.add(e.from);
        external.add(e);
      }
      // Wholly outside: left alone below.
    }

    int order(PortRef a, PortRef b) =>
        a.nodeId == b.nodeId ? a.idx - b.idx : a.nodeId - b.nodeId;
    final inPorts = <PortRef>[...{for (final p in crossingIn) key(p): p}.values]
      ..sort(order);
    final outPorts = <PortRef>[...{for (final p in crossingOut) key(p): p}.values]
      ..sort(order);

    for (var i = 0; i < inPorts.length; i++) {
      final inner = inPorts[i];
      inputs[key(inner)] = GroupBoundary(
        idx: i,
        inner: inner,
        label: 'in$i',
      );
    }
    for (var i = 0; i < outPorts.length; i++) {
      final inner = outPorts[i];
      outputs[key(inner)] = GroupBoundary(
        idx: i,
        inner: inner,
        label: 'out$i',
      );
    }

    for (final e in edges) {
      final fromInside = selection.contains(e.from.nodeId);
      final toInside = selection.contains(e.to.nodeId);
      if (fromInside && toInside) continue; // now internal
      if (toInside) {
        remapped.add(e.copyWith(
          to: PortRef(nodeId: groupId, idx: inputs[key(e.to)]!.idx),
        ));
      } else if (fromInside) {
        remapped.add(e.copyWith(
          from: PortRef(nodeId: groupId, idx: outputs[key(e.from)]!.idx),
        ));
      } else {
        remapped.add(e);
      }
    }

    final subgraph = SubgraphGraph(
      nodes: children,
      edges: internal,
      inputs: inputs.values.toList()..sort((a, b) => a.idx - b.idx),
      outputs: outputs.values.toList()..sort((a, b) => a.idx - b.idx),
    );

    final container = NodeGroup.withSubgraph(
      WorkflowNode(id: groupId, type: NodeGroup.type, x: originX, y: originY),
      subgraph,
      label: label ?? 'Group ${children.length}',
    );

    return GroupingResult(
      nodes: [
        for (final n in nodes)
          if (!selection.contains(n.id)) n,
        container,
      ],
      edges: remapped,
      selection: {groupId},
    );
  }

  /// Expand the group node [groupId] back onto the canvas.
  ///
  /// Children are spawned at `group position + relative position`, internal edges
  /// come back verbatim, and every external edge that terminated on a group port
  /// is re-pointed at the child port that port proxied. The container is removed
  /// and the children are left selected.
  ///
  /// An external edge whose port index has no boundary — a workflow file edited
  /// by hand, say — is **dropped rather than re-pointed at nothing**, since
  /// keeping it would leave an edge addressing a node that no longer exists.
  ///
  /// Returns null when [groupId] is not a group node carrying a subgraph.
  static GroupingResult? ungroup({
    required List<WorkflowNode> nodes,
    required List<WorkflowEdge> edges,
    required int groupId,
  }) {
    final container = nodes.where((n) => n.id == groupId).firstOrNull;
    if (container == null || !NodeGroup.isGroup(container)) return null;
    final subgraph = NodeGroup.subgraphOf(container);
    if (subgraph == null) return null;

    final children = [
      for (final n in subgraph.nodes)
        n.copyWith(x: container.x + n.x, y: container.y + n.y),
    ];
    final childIds = {for (final n in children) n.id};

    final inputsByIdx = {for (final b in subgraph.inputs) b.idx: b};
    final outputsByIdx = {for (final b in subgraph.outputs) b.idx: b};

    final restored = <WorkflowEdge>[];
    for (final e in edges) {
      final toGroup = e.to.nodeId == groupId;
      final fromGroup = e.from.nodeId == groupId;
      if (!toGroup && !fromGroup) {
        restored.add(e);
        continue;
      }
      // A self-edge on the group cannot be mapped to a single child port pair.
      if (toGroup && fromGroup) continue;

      if (toGroup) {
        final inner = inputsByIdx[e.to.idx]?.inner;
        if (inner != null) restored.add(e.copyWith(to: inner));
      } else {
        final inner = outputsByIdx[e.from.idx]?.inner;
        if (inner != null) restored.add(e.copyWith(from: inner));
      }
    }

    return GroupingResult(
      nodes: [
        for (final n in nodes)
          if (n.id != groupId) n,
        ...children,
      ],
      edges: [...restored, ...subgraph.edges],
      selection: childIds,
    );
  }

  static double _min(double a, double b) => a < b ? a : b;
}
