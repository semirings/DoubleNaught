// Loading a saved workflow whose edge points at a port that no longer exists.
//
// Context: `segForgeNode`'s input port id `promptInput` was renamed to
// `segmentPromptInput`, and `panelPromptInput` was added. Orphaning workflows
// saved against the old id is acceptable; CRASHING on them is not.
//
// What the first group establishes is why the rename orphans nothing at all:
// **port ids are never persisted**. `WorkflowStore` writes an edge as four
// integers — fromNode / fromIdx / toNode / toIdx — so no port id string ever
// reaches disk, and renaming one cannot invalidate a saved file.
//
// The remaining risk is therefore an edge to a port *index* with no registered
// port, which is a real shape (a node type that lost an output, or a file
// hand-edited). The second group pins that this is absorbed, not thrown.

import 'dart:io';

import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/workflow_api.dart';
import 'package:double_vision/services/workflow_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory store, so a widget test never does real file I/O (which never
/// completes inside `testWidgets`' fake-async zone).
class _FakeStore extends WorkflowStore {
  _FakeStore(this.workflow);

  final Workflow workflow;

  @override
  Future<bool> exists(String slug) async => slug == 'subject';

  @override
  Future<List<WorkflowMeta>> list() async => [
        WorkflowMeta(
          slug: 'subject',
          name: 'subject',
          nodeCount: workflow.nodes.length,
          edgeCount: workflow.edges.length,
        ),
      ];

  @override
  Future<Workflow?> read(String slug) async => workflow;

  @override
  Future<void> write(String slug, String name, Workflow wf) async {}

  @override
  Future<bool> delete(String slug) async => true;
}

/// A backend that refuses everything, so any node that reaches for the network
/// on load takes its error path instead of hanging on a real socket.
http.Client _deadBackend() =>
    MockClient((_) async => http.Response('{"detail":"no backend"}', 503));

Future<void> _openSubject(WidgetTester tester, Workflow wf) async {
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkflowPage(
          workflowApi: WorkflowApi(client: _deadBackend()),
          workflowStore: _FakeStore(wf),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open a saved workflow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('subject'));
    await tester.pumpAndSettle();
  }, _deadBackend);
}

void main() {
  group('port ids are not persisted, so a rename orphans nothing', () {
    late Directory tmp;
    late WorkflowStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dn_port_rename_');
      store = WorkflowStore(overrideDir: tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a saved edge carries indices only — no port id string', () async {
      const wf = Workflow(
        version: '0.1.0',
        nodes: [
          WorkflowNode(id: 1, type: 'prompt_node', x: 0, y: 0),
          WorkflowNode(id: 2, type: 'segForgeNode', x: 100, y: 0),
        ],
        edges: [
          // A Prompt node into Seg Forge's prompt port.
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 1),
          ),
        ],
      );
      await store.write('subject', 'Subject', wf);

      final raw = await File('${store.dirPath}/subject.json').readAsString();

      // The load-bearing assertion of this whole file: not the old id, not
      // the new ones, not any port id — the serializer has no column for one.
      expect(raw, isNot(contains('promptInput')));
      expect(raw, isNot(contains('segmentPromptInput')));
      expect(raw, isNot(contains('panelPromptInput')));
      // What it does carry instead.
      expect(raw, contains('toIdx'));

      // And the edge survives the round-trip on its index. (Compared
      // field-wise: PortRef does not implement ==, so a direct expect on the
      // object passes trivially for any two instances.)
      final back = await store.read('subject');
      expect(back!.edges.single.to.nodeId, 2);
      expect(back.edges.single.to.idx, 1);
    });

    test('an edge to an index with no port still round-trips intact',
        () async {
      // Nothing in the persistence layer validates an index against the
      // target's real port count, so a stale index survives a save/load
      // untouched. That is what the widget-level group below has to absorb.
      const wf = Workflow(
        version: '0.1.0',
        nodes: [
          WorkflowNode(id: 1, type: 'prompt_node', x: 0, y: 0),
          WorkflowNode(id: 2, type: 'segForgeNode', x: 100, y: 0),
        ],
        edges: [
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 9), // no such input port
          ),
        ],
      );
      await store.write('subject', 'Subject', wf);

      final back = await store.read('subject');
      expect(back!.edges.single.to.idx, 9);
    });
  });

  group('loading an edge to a port that does not exist', () {
    testWidgets('an edge to a nonexistent input index does not throw',
        (tester) async {
      const wf = Workflow(
        version: '0.1.0',
        nodes: [
          WorkflowNode(id: 1, type: 'load_file', x: 0, y: 0),
          WorkflowNode(id: 2, type: 'preview', x: 200, y: 0),
        ],
        edges: [
          // Preview has no input port 7.
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 7),
          ),
        ],
      );

      await _openSubject(tester, wf);

      // No exception escaped the load, and the graph is on the canvas.
      expect(tester.takeException(), isNull);
      expect(find.text('Loaded "subject"'), findsOneWidget);
    });

    testWidgets('a nonexistent-port edge does not stop the rest of the graph',
        (tester) async {
      const wf = Workflow(
        version: '0.1.0',
        nodes: [
          WorkflowNode(id: 1, type: 'load_file', x: 0, y: 0),
          WorkflowNode(id: 2, type: 'preview', x: 200, y: 0),
          WorkflowNode(id: 3, type: 'preview', x: 400, y: 0),
        ],
        edges: [
          // The dangling one comes FIRST: if binding threw, or if the loop
          // aborted on it, the good edge after it would be lost. Ordering
          // this way is the point of the test.
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 7),
          ),
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 3, idx: 0),
          ),
        ],
      );

      await _openSubject(tester, wf);

      expect(tester.takeException(), isNull);
      expect(find.text('Loaded "subject"'), findsOneWidget);
    });

    testWidgets('a Seg Forge node with a stale prompt-port edge loads',
        (tester) async {
      // The concrete rename case. An old file's edge into Seg Forge's prompt
      // port was saved as idx 1, which is now `segmentPromptInput` — so it
      // keeps working and means the same thing. idx 5 in the same file is the
      // genuinely dangling shape. Both must load.
      const wf = Workflow(
        version: '0.1.0',
        nodes: [
          WorkflowNode(id: 1, type: 'prompt_node', x: 0, y: 0),
          WorkflowNode(id: 2, type: 'segForgeNode', x: 200, y: 0),
        ],
        edges: [
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 1),
          ),
          WorkflowEdge(
            from: PortRef(nodeId: 1, idx: 0),
            to: PortRef(nodeId: 2, idx: 5),
          ),
        ],
      );

      await _openSubject(tester, wf);

      expect(tester.takeException(), isNull);
      expect(find.text('Loaded "subject"'), findsOneWidget);
    });
  });
}
