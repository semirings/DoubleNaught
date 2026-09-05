import 'dart:io' show SocketException;

import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/workflow_api.dart';
import 'package:double_vision/services/workflow_store.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A backend that answers DELETE /workflows/{id} with a fixed status.
///
/// Records what it was asked to delete, so a test can prove the API was invoked
/// rather than inferring it from the UI.
({WorkflowApi api, List<String> deleted}) _api({
  int status = 200,
  String detail = 'nope',
  bool throwTransport = false,
}) {
  final deleted = <String>[];
  final api = WorkflowApi(
    client: MockClient((request) async {
      expect(request.method, 'DELETE');
      deleted.add(Uri.decodeComponent(request.url.pathSegments.last));
      if (throwTransport) throw const SocketException('refused');
      if (status == 200) {
        return http.Response(
          '{"status":"SUCCESS","workflowId":"${deleted.last}"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"detail":"$detail"}', status,
          headers: {'content-type': 'application/json'});
    }),
  );
  return (api: api, deleted: deleted);
}

/// An in-memory [WorkflowStore].
///
/// Not a temp directory: real file I/O inside `testWidgets` runs in a fake-async
/// zone where the future never completes, so `pumpAndSettle` sits there until its
/// ten-minute timeout. Overriding the store keeps the whole flow synchronous.
class _FakeStore extends WorkflowStore {
  _FakeStore(Iterable<String> slugs) {
    for (final slug in slugs) {
      saved[slug] = const Workflow(
        version: '0.1.0',
        nodes: [WorkflowNode(id: 1, type: 'preview', x: 10, y: 20)],
      );
    }
  }

  final Map<String, Workflow> saved = {};

  /// Slugs this store was asked to delete, in order.
  final List<String> deleteCalls = [];

  @override
  Future<bool> exists(String slug) async => saved.containsKey(slug);

  @override
  Future<List<WorkflowMeta>> list() async => [
        for (final entry in saved.entries)
          WorkflowMeta(
            slug: entry.key,
            name: entry.key,
            nodeCount: entry.value.nodes.length,
            edgeCount: entry.value.edges.length,
          ),
      ];

  @override
  Future<Workflow?> read(String slug) async => saved[slug];

  @override
  Future<void> write(String slug, String name, Workflow workflow) async {
    saved[slug] = workflow;
  }

  @override
  Future<bool> delete(String slug) async {
    deleteCalls.add(slug);
    return saved.remove(slug) != null;
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required WorkflowApi api,
  required WorkflowStore store,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: WorkflowPage(workflowApi: api, workflowStore: store)),
  );
  await tester.pumpAndSettle();
}

/// Open the Workflows menu and press the trash icon on the first entry.
Future<void> _tapDelete(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open a saved workflow'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Delete').first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the workflow entry offers a trash icon', (tester) async {
    final s = _FakeStore(['alpha']);
    await _pumpPage(tester, api: _api().api, store: s);

    await tester.tap(find.byTooltip('Open a saved workflow'));
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('Delete'),
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsOneWidget,
    );
  });

  group('confirmation dialog', () {
    testWidgets('shows the specified title, body and actions', (tester) async {
      final s = _FakeStore(['alpha']);
      await _pumpPage(tester, api: _api().api, store: s);

      await _tapDelete(tester);

      expect(find.text('Delete Workflow'), findsOneWidget);
      expect(
        find.text(
          "Are you sure you want to delete 'alpha'? "
          'This action cannot be undone.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
    });

    testWidgets('the Delete action is styled destructively', (tester) async {
      final s = _FakeStore(['alpha']);
      await _pumpPage(tester, api: _api().api, store: s);
      await _tapDelete(tester);

      final button =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'));
      final background = button.style?.backgroundColor?.resolve({});
      final scheme = Theme.of(tester.element(find.byType(AlertDialog)))
          .colorScheme;
      expect(background, scheme.error);
    });

    testWidgets('Cancel calls nothing and keeps the workflow', (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api();
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(backend.deleted, isEmpty, reason: 'no request may be made');
      expect(s.saved.containsKey('alpha'), isTrue);
      expect(find.text('Delete Workflow'), findsNothing);
    });
  });

  group('confirmed delete', () {
    testWidgets('calls the API with the workflow id', (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api();
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(backend.deleted, ['alpha']);
    });

    testWidgets('removes it from the list and shows a success SnackBar',
        (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api();
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Deleted "alpha"'), findsOneWidget);

      // The entry is gone from the menu — the backend deleted nothing on disk
      // here (it is a mock), so the local store still has the file; the list is
      // rebuilt from the store, which is what the user sees.
      await tester.tap(find.byTooltip('Open a saved workflow'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete'), findsOneWidget);
    });

    testWidgets('a 409 conflict refuses, keeps the file, and says why',
        (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api(status: 409, detail: '2 task(s) in flight');
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cannot delete "alpha"'), findsOneWidget);
      expect(find.textContaining('in flight'), findsOneWidget);
      // The refusal must not be worked around locally.
      expect(s.saved.containsKey('alpha'), isTrue);
    });

    testWidgets('an unreachable backend falls back to the local store',
        (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api(throwTransport: true);
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Workflows are local files; a dead server must not make them undeletable.
      expect(s.saved.containsKey('alpha'), isFalse);
      expect(find.text('Deleted "alpha"'), findsOneWidget);
    });

    testWidgets('a 404 also falls back — the file is local either way',
        (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api(status: 404, detail: 'no such workflow');
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(s.saved.containsKey('alpha'), isFalse);
      expect(find.text('Deleted "alpha"'), findsOneWidget);
    });

    testWidgets('a 500 reports the failure and deletes nothing', (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api(status: 500, detail: 'disk on fire');
      await _pumpPage(tester, api: backend.api, store: s);
      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Delete failed'), findsOneWidget);
      expect(s.saved.containsKey('alpha'), isTrue);
    });
  });

  group('the open workflow', () {
    testWidgets('deleting it resets the canvas', (tester) async {
      final s = _FakeStore(['alpha']);
      final backend = _api();
      await _pumpPage(tester, api: backend.api, store: s);

      // Open it, so the canvas holds its graph and its name.
      await tester.tap(find.byTooltip('Open a saved workflow'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(PreviewNode), findsOneWidget);

      await _tapDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Graph cleared, so Save cannot recreate it under the deleted name.
      expect(find.byType(PreviewNode), findsNothing);
      expect(find.textContaining('Use the Node Catalog menu'), findsOneWidget);
    });

    testWidgets('deleting a different workflow leaves the canvas alone',
        (tester) async {
      final s = _FakeStore(['alpha']);
      s.saved['beta'] = const Workflow(version: '0.1.0');
      final backend = _api();
      await _pumpPage(tester, api: backend.api, store: s);

      // Open alpha…
      await tester.tap(find.byTooltip('Open a saved workflow'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(PreviewNode), findsOneWidget);

      // …then delete beta.
      await tester.tap(find.byTooltip('Open a saved workflow'));
      await tester.pumpAndSettle();
      final betaRow = find.ancestor(of: find.text('beta'), matching: find.byType(Row));
      await tester.tap(
        find.descendant(of: betaRow.first, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(backend.deleted, ['beta']);
      // alpha's graph is untouched.
      expect(find.byType(PreviewNode), findsOneWidget);
    });
  });

  group('WorkflowApi', () {
    test('a 200 resolves true', () async {
      final backend = _api();
      expect(await backend.api.deleteWorkflow('alpha'), isTrue);
      expect(backend.deleted, ['alpha']);
    });

    test('a 404 raises notFound', () async {
      final backend = _api(status: 404, detail: 'no such workflow');
      await expectLater(
        backend.api.deleteWorkflow('ghost'),
        throwsA(isA<WorkflowDeleteException>().having(
          (e) => e.reason,
          'reason',
          WorkflowDeleteFailure.notFound,
        )),
      );
    });

    test('a 409 raises conflict, and refuses a local fallback', () async {
      final backend = _api(status: 409, detail: 'in flight');
      try {
        await backend.api.deleteWorkflow('alpha');
        fail('should have thrown');
      } on WorkflowDeleteException catch (e) {
        expect(e.reason, WorkflowDeleteFailure.conflict);
        expect(e.message, 'in flight');
        expect(e.allowsLocalFallback, isFalse);
      }
    });

    test('a transport failure raises unreachable and allows a fallback',
        () async {
      final backend = _api(throwTransport: true);
      try {
        await backend.api.deleteWorkflow('alpha');
        fail('should have thrown');
      } on WorkflowDeleteException catch (e) {
        expect(e.reason, WorkflowDeleteFailure.unreachable);
        expect(e.allowsLocalFallback, isTrue);
        // The message names the exception type, never the host and port.
        expect(e.message, contains('unreachable'));
        expect(e.message, isNot(contains('127.0.0.1')));
      }
    });

    test('an id with awkward characters is percent-encoded', () async {
      final deleted = <String>[];
      final api = WorkflowApi(
        client: MockClient((request) async {
          deleted.add(request.url.path);
          return http.Response('{"status":"SUCCESS"}', 200);
        }),
      );

      await api.deleteWorkflow('my workflow');
      expect(deleted.single, '/workflows/my%20workflow');
    });
  });
}
