import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:double_vision/services/load_file_api.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The current text of the node's path field. Read from the controller rather
/// than via find.text(), which also matches the identical hintText — and scoped
/// by label, since the Schema Mode DropdownMenu is a TextField too.
String _pathField(WidgetTester tester) => tester
    .widget<TextField>(find.ancestor(
      of: find.text('File Path (backend storage)'),
      matching: find.byType(TextField),
    ))
    .controller!
    .text;

/// The triple `(row, col)` → val, for order-independent assertions.
Map<String, Object> _cells(AaPayload aa) => {
      for (var k = 0; k < aa.cols.length; k++)
        '${aa.rows[k]}|${aa.cols[k]}': aa.vals[k],
    };

void main() {
  _portRoutingTests();
  _portMigrationTests();

  group('contentsToAa', () {
    test('column-major table (parquet/arrow to_pydict) keys rows by index', () {
      final aa = LoadFileNode.contentsToAa({
        'rowKey': ['r1', 'r2'],
        'colKey': ['c1', 'c1'],
        'val': [10, 20],
      })!;

      expect(aa.length, 6);
      expect(aa.distinctRows(), ['0', '1']);
      expect(_cells(aa), {
        '0|rowKey': 'r1',
        '1|rowKey': 'r2',
        '0|colKey': 'c1',
        '1|colKey': 'c1',
        '0|val': 10,
        '1|val': 20,
      });
    });

    test('csv DictReader shape keys rows by index and cols by dict key', () {
      final aa = LoadFileNode.contentsToAa({
        'rows': [
          {'ID': 'p1', 'GENDER': 'F'},
          {'ID': 'p2', 'GENDER': 'M'},
        ],
      })!;

      expect(aa.distinctRows(), ['0', '1']);
      expect(_cells(aa), {
        '0|ID': 'p1',
        '0|GENDER': 'F',
        '1|ID': 'p2',
        '1|GENDER': 'M',
      });
    });

    test('flat scalar object (a .txt payload) becomes a single row', () {
      final aa = LoadFileNode.contentsToAa({'text': 'hello'})!;
      expect(_cells(aa), {'0|text': 'hello'});
    });

    test('non-scalar cells are JSON-encoded', () {
      final aa = LoadFileNode.contentsToAa({
        'meta': {'a': 1},
        'tags': [
          ['x']
        ],
      })!;
      expect(_cells(aa), {'0|meta': '{"a":1}', '0|tags': '["x"]'});
    });

    test('nulls are skipped, empty data emits nothing', () {
      final aa = LoadFileNode.contentsToAa({
        'a': ['keep', null],
      })!;
      expect(_cells(aa), {'0|a': 'keep'});

      expect(LoadFileNode.contentsToAa(const {}), isNull);
      expect(LoadFileNode.contentsToAa(const {'a': null}), isNull);
    });
  });

  group('Browse…', () {
    testWidgets('fills the path field with the picked file', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => XFile('/tmp/picked/export.parquet'),
          ),
        ),
      ));

      expect(_pathField(tester), 'storage/out/export.parquet');

      // tapAt(getCenter(...)) rather than tap(finder): Flutter 3.44's tap()
      // resolves a view via _maybeViewOf, which fails inside the node card.
      final browse = find.byTooltip('Browse…');
      await tester.tapAt(tester.getCenter(browse));
      await tester.pumpAndSettle();

      expect(_pathField(tester), '/tmp/picked/export.parquet');
    });

    testWidgets('a cancelled dialog leaves the path untouched', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => null,
          ),
        ),
      ));

      await tester.tapAt(tester.getCenter(find.byTooltip('Browse…')));
      await tester.pumpAndSettle();

      expect(_pathField(tester), 'storage/out/export.parquet');
    });
  });

  group('file-type filter', () {
    test('extensionOf reads the last segment only, lowercased', () {
      expect(LoadFileNode.extensionOf('/tmp/model.JL'), '.jl');
      expect(LoadFileNode.extensionOf('/tmp/notes.md'), '.md');
      // A dot in a directory name is not an extension.
      expect(LoadFileNode.extensionOf('/tmp/v1.2/model'), '');
      // Nor is a leading dot on an extension-less dotfile.
      expect(LoadFileNode.extensionOf('/tmp/.gitignore'), '');
      // Windows separators too — the helper avoids dart:io for the web build.
      expect(LoadFileNode.extensionOf(r'C:\data\export.parquet'), '.parquet');
      expect(LoadFileNode.extensionOf('bare'), '');
      // Only the final extension counts.
      expect(LoadFileNode.extensionOf('/tmp/archive.tar.gz'), '.gz');
    });

    test('the allow-list is the whole filter', () {
      for (final ext in LoadFileNode.allowedExtensions) {
        expect(LoadFileNode.isAllowedPath('/tmp/file$ext'), isTrue,
            reason: '$ext should be allowed');
      }
      // .csv stays allowed: the backend reconstructs an AA from one.
      expect(LoadFileNode.isAllowedPath('/tmp/data.csv'), isTrue);
      for (final path in [
        '/tmp/image.png',
        '/tmp/archive.zip',
        '/tmp/binary',
        '/tmp/.gitignore',
      ]) {
        expect(LoadFileNode.isAllowedPath(path), isFalse, reason: path);
      }
    });

    testWidgets('a .jl pick is accepted — the case the UTI filter blocked',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => XFile('/Users/me/src/model.jl'),
          ),
        ),
      ));

      await tester.tapAt(tester.getCenter(find.byTooltip('Browse…')));
      await tester.pumpAndSettle();

      expect(_pathField(tester), '/Users/me/src/model.jl');
      expect(find.textContaining('Unsupported file type'), findsNothing);
    });

    testWidgets('an unsupported pick shows a badge and keeps the path',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => XFile('/Users/me/pictures/cat.png'),
          ),
        ),
      ));

      await tester.tapAt(tester.getCenter(find.byTooltip('Browse…')));
      await tester.pumpAndSettle();

      // Reported, not thrown — and the previous path is untouched.
      expect(find.text('Unsupported file type: .png'), findsOneWidget);
      expect(find.textContaining('Allowed: .jl .md'), findsOneWidget);
      expect(_pathField(tester), 'storage/out/export.parquet');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a file with no extension names the file instead',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => XFile('/Users/me/Makefile'),
          ),
        ),
      ));

      await tester.tapAt(tester.getCenter(find.byTooltip('Browse…')));
      await tester.pumpAndSettle();

      expect(find.text('Unsupported file: Makefile'), findsOneWidget);
    });

    testWidgets('the badge is dismissible', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadFileNode(
            node: const WorkflowNode(id: 1, type: 'load_file'),
            pickFile: () async => XFile('/Users/me/pictures/cat.png'),
          ),
        ),
      ));

      await tester.tapAt(tester.getCenter(find.byTooltip('Browse…')));
      await tester.pumpAndSettle();
      expect(find.text('Unsupported file type: .png'), findsOneWidget);

      await tester.tapAt(tester.getCenter(find.byTooltip('Dismiss')));
      await tester.pumpAndSettle();
      expect(find.text('Unsupported file type: .png'), findsNothing);
    });
  });

  testWidgets('exposes exactly one output port, `aa` at idx 0', (tester) async {
    final ports = <int, OutputPort>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoadFileNode(
          node: const WorkflowNode(id: 1, type: 'load_file'),
          onAaOutputPort: (p) => ports[0] = p,
        ),
      ),
    ));

    expect(ports[0]?.id, 'aa');
    // `contents` is gone: one connector, and it is the AA.
    expect(find.text('contents'), findsNothing);
    expect(find.text('aa'), findsOneWidget);
    expect(find.byType(OutputConnector), findsOneWidget);
  });
}

/// What lands on the single `aa` output port.
///
/// The backend sends an AA for tabular files and for source files alike; the
/// fallbacks below cover an older backend that sends none, so the port cannot go
/// silent — the failure that started this.
void _portRoutingTests() {
  group('output port routing', () {
    test('a text response carries the source in a one-cell AA', () {
      final response = LoadFileResponse(
        aa: const AaPayload(rows: ['0'], cols: ['text'], vals: ['f(x) = x']),
        contents: 'f(x) = x',
        data: const {'text': 'f(x) = x'},
        payloadType: 'text',
        message: 'Loaded text from a.jl',
      );

      // The AA the port emits: one `text` cell, the shape Polyglot Exec reads.
      expect(response.aa!.cols, ['text']);
      expect(response.aa!.value('text'), 'f(x) = x');
    });

    test('a tabular response emits the reconstructed AA', () {
      final response = LoadFileResponse(
        aa: const AaPayload(rows: ['r1'], cols: ['val'], vals: [42]),
        contents: null,
        data: const {'rowKey': ['r1'], 'colKey': ['val'], 'val': [42]},
        payloadType: 'associative_array',
        message: 'Loaded associative_array from t.parquet',
      );

      // No raw string for a Parquet file, and none is needed: `aa` carries the
      // reconstructed AA unchanged.
      expect(response.contents, isNull);
      expect(response.aa!.value('val'), '42');
    });

    test('an older backend that sends no AA still populates the aa port', () {
      // `aa: response.aa ?? contents` — the fallback in the node.
      final response = LoadFileResponse(
        contents: 'f(x) = x',
        data: const {'text': 'f(x) = x'},
        payloadType: 'text',
        message: 'Loaded text from a.jl',
      );

      final contents = LoadFileNode.contentsToAa({'text': response.contents});
      final parsed = response.aa ?? contents;

      expect(parsed, isNotNull, reason: 'the aa port must not go silent');
      expect(parsed!.value('text'), 'f(x) = x');
    });

    test('the response parses the contents field from the wire', () {
      final parsed = LoadFileResponse.fromJson({
        'aa': {'rows': ['0'], 'cols': ['text'], 'vals': ['x = 1']},
        'contents': 'x = 1',
        'data': {'text': 'x = 1'},
        'payloadType': 'text',
        'message': 'Loaded text from a.jl',
      });

      expect(parsed.contents, 'x = 1');
      expect(parsed.aa!.value('text'), 'x = 1');
    });
  });
}

/// Saved workflows wired the old `contents`/`aa` indices; loading must re-point
/// them at the single port that remains.
void _portMigrationTests() {
  group('legacy port migration', () {
    WorkflowEdge edge(int fromNode, int fromIdx) => WorkflowEdge(
          from: PortRef(nodeId: fromNode, idx: fromIdx),
          to: const PortRef(nodeId: 9, idx: 1),
        );

    test('an edge saved from the old aa index (1) is re-pointed to 0', () {
      // Exactly what classifier.json / d4m.json / remote.json carry.
      final migrated = migrateLoadFilePorts(
        const [WorkflowNode(id: 1, type: 'load_file')],
        [edge(1, 1)],
      );

      expect(migrated.single.from.idx, 0);
      expect(migrated.single.to.idx, 1, reason: 'the target end is untouched');
    });

    test('an edge already on idx 0 is left alone', () {
      final original = [edge(1, 0)];
      final migrated = migrateLoadFilePorts(
        const [WorkflowNode(id: 1, type: 'load_file')],
        original,
      );
      expect(migrated.single.from.idx, 0);
    });

    test('it is idempotent', () {
      const nodes = [WorkflowNode(id: 1, type: 'load_file')];
      final once = migrateLoadFilePorts(nodes, [edge(1, 1)]);
      final twice = migrateLoadFilePorts(nodes, once);
      expect(twice.single.from.idx, 0);
    });

    test('the file_source alias is migrated too', () {
      final migrated = migrateLoadFilePorts(
        const [WorkflowNode(id: 1, type: 'file_source')],
        [edge(1, 1)],
      );
      expect(migrated.single.from.idx, 0);
    });

    test('idx 1 on another node type is preserved', () {
      // Split's `val` really is the second output — rewriting it would silently
      // swap a train set for a validation set.
      final migrated = migrateLoadFilePorts(
        const [WorkflowNode(id: 1, type: 'split')],
        [edge(1, 1)],
      );
      expect(migrated.single.from.idx, 1);
    });

    test('a graph with no loader is returned unchanged', () {
      final original = [edge(1, 1)];
      final migrated = migrateLoadFilePorts(
        const [WorkflowNode(id: 1, type: 'chunk')],
        original,
      );
      expect(migrated, same(original), reason: 'no copy when there is no work');
    });

    test('only the loader\'s own edges move', () {
      final migrated = migrateLoadFilePorts(
        const [
          WorkflowNode(id: 1, type: 'load_file'),
          WorkflowNode(id: 2, type: 'split'),
        ],
        [edge(1, 1), edge(2, 1)],
      );

      expect(migrated[0].from.idx, 0, reason: 'the loader');
      expect(migrated[1].from.idx, 1, reason: 'the split');
    });
  });
}
