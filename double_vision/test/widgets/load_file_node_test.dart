import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/nodes/implementations/load_file_node.dart';
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

  testWidgets('contents and aa register as separate indexed ports',
      (tester) async {
    final ports = <int, OutputPort>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoadFileNode(
          node: const WorkflowNode(id: 1, type: 'load_file'),
          onContentsOutputPort: (p) => ports[0] = p,
          onAaOutputPort: (p) => ports[1] = p,
        ),
      ),
    ));

    expect(ports[0]?.id, 'contents');
    expect(ports[1]?.id, 'aa');
    expect(ports[0], isNot(same(ports[1])));
  });
}
