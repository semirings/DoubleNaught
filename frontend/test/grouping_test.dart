import 'package:double_vision/models/node_group.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/canvas/grouping.dart';
import 'package:flutter_test/flutter_test.dart';

WorkflowNode _n(int id, {double x = 0, double y = 0, String type = 'preview'}) =>
    WorkflowNode(id: id, type: type, x: x, y: y);

WorkflowEdge _e(int fromNode, int fromIdx, int toNode, int toIdx) =>
    WorkflowEdge(
      from: PortRef(nodeId: fromNode, idx: fromIdx),
      to: PortRef(nodeId: toNode, idx: toIdx),
    );

/// `from → to` as a comparable string, for order-independent edge assertions.
String _wire(WorkflowEdge e) =>
    '${e.from.nodeId}:${e.from.idx}->${e.to.nodeId}:${e.to.idx}';

Set<String> _wires(Iterable<WorkflowEdge> edges) => edges.map(_wire).toSet();

void main() {
  group('Grouping.group', () {
    test('collapses members and positions the container at their top-left', () {
      final result = Grouping.group(
        nodes: [_n(1, x: 300, y: 200), _n(2, x: 150, y: 260), _n(3, x: 900)],
        edges: const [],
        selection: {1, 2},
        newId: 10,
      )!;

      final container = result.nodes.singleWhere((n) => n.id == 10);
      expect(NodeGroup.isGroup(container), isTrue);
      // Top-left of the selection, per axis independently.
      expect(container.x, 150);
      expect(container.y, 200);

      // Members are gone from the canvas; the untouched node stays.
      expect(result.nodes.map((n) => n.id), containsAll([3, 10]));
      expect(result.nodes.map((n) => n.id), isNot(contains(1)));
      expect(result.selection, {10});

      // Children hold positions relative to the container.
      final sub = NodeGroup.subgraphOf(container)!;
      final child1 = sub.nodes.singleWhere((n) => n.id == 1);
      expect(child1.x, 150); // 300 - 150
      expect(child1.y, 0); //   200 - 200
    });

    test('internal edges move inside; outside edges are untouched', () {
      final result = Grouping.group(
        nodes: [_n(1), _n(2), _n(3), _n(4)],
        edges: [_e(1, 0, 2, 0), _e(3, 0, 4, 0)],
        selection: {1, 2},
        newId: 10,
      )!;

      // The 1→2 edge is inside the group, so it leaves the canvas.
      expect(_wires(result.edges), {'3:0->4:0'});
      final sub = NodeGroup.subgraphOf(
        result.nodes.singleWhere((n) => n.id == 10),
      )!;
      expect(_wires(sub.edges), {'1:0->2:0'});
    });

    test('an inbound crossing edge becomes an input port', () {
      final result = Grouping.group(
        nodes: [_n(1), _n(2), _n(3)],
        edges: [_e(3, 0, 1, 1)], // external 3 feeds child 1's port 1
        selection: {1, 2},
        newId: 10,
      )!;

      // The external edge now addresses the group's input 0.
      expect(_wires(result.edges), {'3:0->10:0'});

      final sub = NodeGroup.subgraphOf(
        result.nodes.singleWhere((n) => n.id == 10),
      )!;
      expect(sub.inputs, hasLength(1));
      expect(sub.inputs.single.idx, 0);
      expect(sub.inputs.single.inner.nodeId, 1);
      expect(sub.inputs.single.inner.idx, 1);
      expect(sub.outputs, isEmpty);
    });

    test('an outbound crossing edge becomes an output port', () {
      final result = Grouping.group(
        nodes: [_n(1), _n(2), _n(3)],
        edges: [_e(2, 1, 3, 0)],
        selection: {1, 2},
        newId: 10,
      )!;

      expect(_wires(result.edges), {'10:0->3:0'});
      final sub = NodeGroup.subgraphOf(
        result.nodes.singleWhere((n) => n.id == 10),
      )!;
      expect(sub.outputs.single.inner.nodeId, 2);
      expect(sub.outputs.single.inner.idx, 1);
    });

    test('two external sources into one child port share one input port', () {
      final result = Grouping.group(
        nodes: [_n(1), _n(2), _n(3), _n(4)],
        edges: [_e(3, 0, 1, 0), _e(4, 0, 1, 0)],
        selection: {1, 2},
        newId: 10,
      )!;

      final sub = NodeGroup.subgraphOf(
        result.nodes.singleWhere((n) => n.id == 10),
      )!;
      // Same destination ⇒ same port, not two ports for one inner target.
      expect(sub.inputs, hasLength(1));
      expect(_wires(result.edges), {'3:0->10:0', '4:0->10:0'});
    });

    test('boundary numbering is stable, sorted by (child id, port idx)', () {
      // Edges deliberately out of order.
      final result = Grouping.group(
        nodes: [_n(1), _n(2), _n(9)],
        edges: [_e(9, 0, 2, 1), _e(9, 1, 1, 0), _e(9, 2, 2, 0)],
        selection: {1, 2},
        newId: 10,
      )!;

      final sub = NodeGroup.subgraphOf(
        result.nodes.singleWhere((n) => n.id == 10),
      )!;
      expect(
        [for (final b in sub.inputs) '${b.inner.nodeId}:${b.inner.idx}'],
        ['1:0', '2:0', '2:1'],
      );
    });

    test('refuses a selection of one, or one naming a phantom node', () {
      expect(
        Grouping.group(
            nodes: [_n(1)], edges: const [], selection: {1}, newId: 10),
        isNull,
      );
      expect(
        Grouping.group(
            nodes: [_n(1), _n(2)],
            edges: const [],
            selection: {1, 99},
            newId: 10),
        isNull,
      );
    });
  });

  group('Grouping.ungroup', () {
    /// Canvas: 3 → [1 → 2] → 4, grouped.
    GroupingResult grouped() => Grouping.group(
          nodes: [_n(1, x: 300, y: 200), _n(2, x: 150, y: 260), _n(3), _n(4)],
          edges: [_e(1, 0, 2, 0), _e(3, 0, 1, 1), _e(2, 1, 4, 0)],
          selection: {1, 2},
          newId: 10,
        )!;

    test('restores absolute positions from group + relative', () {
      final after = Grouping.ungroup(
        nodes: grouped().nodes,
        edges: grouped().edges,
        groupId: 10,
      )!;

      final one = after.nodes.singleWhere((n) => n.id == 1);
      expect(one.x, 300);
      expect(one.y, 200);
      final two = after.nodes.singleWhere((n) => n.id == 2);
      expect(two.x, 150);
      expect(two.y, 260);
    });

    test('maps external edges back to the child ports they proxied', () {
      final g = grouped();
      final after = Grouping.ungroup(
        nodes: g.nodes,
        edges: g.edges,
        groupId: 10,
      )!;

      // Every wire is exactly what it was before grouping.
      expect(_wires(after.edges), {'1:0->2:0', '3:0->1:1', '2:1->4:0'});
      expect(after.nodes.map((n) => n.id), isNot(contains(10)));
      // The unpacked children stay selected.
      expect(after.selection, {1, 2});
    });

    test('group → ungroup is a round trip for nodes and edges', () {
      final nodes = [_n(1, x: 300, y: 200), _n(2, x: 150, y: 260), _n(3), _n(4)];
      final edges = [_e(1, 0, 2, 0), _e(3, 0, 1, 1), _e(2, 1, 4, 0)];

      final g = Grouping.group(
          nodes: nodes, edges: edges, selection: {1, 2}, newId: 10)!;
      final u =
          Grouping.ungroup(nodes: g.nodes, edges: g.edges, groupId: 10)!;

      expect(
        {for (final n in u.nodes) '${n.id}@${n.x},${n.y}'},
        {for (final n in nodes) '${n.id}@${n.x},${n.y}'},
      );
      expect(_wires(u.edges), _wires(edges));
    });

    test('regroup reuses the container id, position and label', () {
      final g = grouped();
      final label = NodeGroup.labelOf(g.nodes.singleWhere((n) => n.id == 10));
      final u = Grouping.ungroup(
        nodes: g.nodes,
        edges: g.edges,
        groupId: 10,
      )!;

      final again = Grouping.group(
        nodes: u.nodes,
        edges: u.edges,
        selection: u.selection,
        newId: 999, // must be ignored in favour of reuseId
        reuseId: 10,
        atX: 150,
        atY: 200,
        label: label,
      )!;

      final container = again.nodes.singleWhere((n) => n.id == 10);
      expect(again.nodes.map((n) => n.id), isNot(contains(999)));
      expect(container.x, 150);
      expect(container.y, 200);
      expect(NodeGroup.labelOf(container), label);
      // And the boundary wiring matches the first grouping exactly.
      expect(_wires(again.edges), _wires(g.edges));
    });

    test('an edge on a port with no boundary is dropped, not left dangling',
        () {
      final g = grouped();
      final withGhost = [...g.edges, _e(3, 0, 10, 7)]; // port 7 does not exist

      final after = Grouping.ungroup(
        nodes: g.nodes,
        edges: withGhost,
        groupId: 10,
      )!;

      // No edge may address the removed container, and none may point at a
      // port the group never had.
      expect(after.edges.any((e) => e.to.nodeId == 10 || e.from.nodeId == 10),
          isFalse);
      expect(_wires(after.edges), {'1:0->2:0', '3:0->1:1', '2:1->4:0'});
    });

    test('refuses a node that is not a group, or a group with no subgraph', () {
      expect(
        Grouping.ungroup(nodes: [_n(1)], edges: const [], groupId: 1),
        isNull,
      );
      expect(
        Grouping.ungroup(
          nodes: [_n(1, type: NodeGroup.type)],
          edges: const [],
          groupId: 1,
        ),
        isNull,
      );
    });
  });

  group('SubgraphGraph persistence', () {
    test('survives the params JSON round trip a save/load performs', () {
      final g = Grouping.group(
        nodes: [_n(1, x: 10, y: 20), _n(2, x: 40, y: 60), _n(3)],
        edges: [_e(1, 0, 2, 0), _e(3, 0, 1, 0)],
        selection: {1, 2},
        newId: 10,
      )!;
      final container = g.nodes.singleWhere((n) => n.id == 10);

      // Exactly what save→load does: WorkflowNode through JSON and back.
      final reloaded = WorkflowNode.fromJson(container.toJson());
      final sub = NodeGroup.subgraphOf(reloaded)!;

      expect(sub.nodes.map((n) => n.id), containsAll([1, 2]));
      expect(_wires(sub.edges), {'1:0->2:0'});
      expect(sub.inputs.single.inner.nodeId, 1);
      // And it can still be ungrouped after the trip.
      final after = Grouping.ungroup(
        nodes: [reloaded, _n(3)],
        edges: g.edges,
        groupId: 10,
      )!;
      expect(_wires(after.edges), {'1:0->2:0', '3:0->1:0'});
    });

    test('unreadable params degrade to null instead of throwing', () {
      const broken = WorkflowNode(
        id: 1,
        type: NodeGroup.type,
        params: {NodeGroup.subgraphKey: '{ truncated'},
      );
      expect(NodeGroup.subgraphOf(broken), isNull);
      expect(NodeGroup.labelOf(broken), 'Group');
    });
  });
}
