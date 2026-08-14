import 'dart:convert';

import 'package:double_vision/config/node_registry.dart';
import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/ast_extract_api.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The 7 columns the extractor emits.
const _schema = [
  'symbol_name',
  'kind',
  'file_path',
  'line_range',
  'docstring',
  'raw_code',
  'better_docstring',
];

/// A backend answering `/ast/extract/aa` with [definitions] — `(name, kind)`.
({AstExtractApi api, List<Map<String, dynamic>> requests}) _api({
  List<(String, String)> definitions = const [('add_one', 'function')],
  int filesScanned = 1,
  List<String> errors = const [],
  int httpStatus = 200,
}) {
  final requests = <Map<String, dynamic>>[];
  final api = AstExtractApi(
    client: MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (httpStatus != 200) {
        return http.Response('{"detail":"nope"}', httpStatus);
      }
      final rows = <String>[];
      final cols = <String>[];
      final vals = <String>[];
      for (var i = 0; i < definitions.length; i++) {
        final (name, kind) = definitions[i];
        final key = 'a.jl:$i:$i';
        for (final column in _schema) {
          rows.add(key);
          cols.add(column);
          vals.add(switch (column) {
            'symbol_name' => name,
            'kind' => kind,
            'file_path' => 'a.jl',
            'line_range' => '$i:$i',
            'raw_code' => '$name(x) = x',
            _ => '',
          });
        }
      }
      return http.Response(
        jsonEncode({
          'aa': {'rows': rows, 'cols': cols, 'vals': vals},
          'definitionCount': definitions.length,
          'filesScanned': filesScanned,
          'errors': errors,
          'root': '/tmp/src',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return (api: api, requests: requests);
}

Future<({InputPort input, List<AaPayload> emitted})> _pump(
  WidgetTester tester, {
  AstExtractApi? api,
  Map<String, String>? params,
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AstExtractNodeWidget(
            node: const WorkflowNode(id: 1, type: 'astExtractNode'),
            initialParams: params,
            api: api ?? _api().api,
            onInputPort: (p) => port = p,
            onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (input: port!, emitted: emitted);
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

/// What `Load File` emits for a source file, now that it publishes the path.
AaPayload _loadFileAa(String path) => AaPayload(
      rows: const ['0', '0'],
      cols: const ['text', 'file_path'],
      vals: ['f(x) = x', path],
    );

void main() {
  group('catalog registration', () {
    test('AST Extract is registered under AST & Code Analysis', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'astExtractNode');
      expect(entry.name, 'AST Extract');
      expect(entry.category, NodeCategory.code);
      // The category was empty until now.
      expect(
        nodeTypes.where((t) => t.category == NodeCategory.code),
        isNotEmpty,
      );
    });

    test('it is findable by the words someone would type', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'astExtractNode');
      for (final query in ['ast', 'macro', 'parse', 'definitions', 'symbols']) {
        expect(entry.matches(query), isTrue, reason: query);
      }
    });
  });

  group('path resolution', () {
    testWidgets('starts disabled, asking for a path', (tester) async {
      await _pump(tester);

      expect(find.text('AST Extract'), findsOneWidget);
      expect(find.textContaining('Wire a Load File node'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('takes the path from in_aa and enables Extract', (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));

      // Shown as the hint, with a note that it came from upstream.
      expect(find.text('/tmp/src/a.jl'), findsOneWidget);
      expect(find.text('from in_aa'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('a typed path wins over the upstream one', (tester) async {
      final backend = _api();
      final h = await _pump(tester, api: backend.api);
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));

      await tester.enterText(find.byType(TextField), '/other/tree');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      expect(backend.requests.single['rootPath'], '/other/tree');
    });

    testWidgets('a typed path alone is enough — nothing wired', (tester) async {
      final backend = _api();
      await _pump(tester, api: backend.api);

      await tester.enterText(find.byType(TextField), '/tmp/src');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      expect(backend.requests.single['rootPath'], '/tmp/src');
    });

    testWidgets('a payload with no path leaves the node waiting', (tester) async {
      final h = await _pump(tester);
      // Text but no `file_path` — an older Load File payload.
      await _send(
        tester,
        h.input,
        const AaPayload(rows: ['0'], cols: ['text'], vals: ['f(x) = x']),
      );

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('the saved path is restored', (tester) async {
      await _pump(tester, params: const {'rootPath': '/saved/tree'});
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/saved/tree',
      );
    });
  });

  group('extraction', () {
    testWidgets('emits the 7-column index and reports the counts',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(
          definitions: const [
            ('add_one', 'function'),
            ('@shout', 'macro'),
            ('_resolve', 'function'),
          ],
          filesScanned: 2,
        ).api,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src'));

      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      // The count is the status row's; the summary adds the shape of it.
      expect(find.textContaining('complete · 3 definitions'), findsOneWidget);
      expect(find.text('2 files scanned'), findsOneWidget);
      // The breakdown answers "did it see my macros?" without opening the panel.
      expect(find.textContaining('2 function'), findsOneWidget);
      expect(find.textContaining('1 macro'), findsOneWidget);

      expect(h.emitted, hasLength(1));
      final out = h.emitted.single;
      expect(out.cols.toSet(), _schema.toSet());
      expect(out.distinctRows(), hasLength(3), reason: 'one row per definition');
    });

    testWidgets('the emitted index carries the macro rows', (tester) async {
      final h = await _pump(
        tester,
        api: _api(definitions: const [('@sw_str', 'macro')]).api,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      final out = h.emitted.single.toSparse();
      final names = [
        for (var i = 0; i < out.cols.length; i++)
          if (out.cols[i] == 'symbol_name') '${out.vals[i]}',
      ];
      expect(names, ['@sw_str']);
    });

    testWidgets('an empty index is surfaced, not emitted', (tester) async {
      final h = await _pump(tester, api: _api(definitions: const []).api);
      await _send(tester, h.input, _loadFileAa('/tmp/empty.jl'));

      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No definitions found'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets('skipped files are reported alongside the count',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(errors: const ['broken.jl: parse failed']).api,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src'));
      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 file(s) skipped'), findsOneWidget);
      // A broken file does not stop the rest from flowing.
      expect(h.emitted, hasLength(1));
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(tester, api: _api(httpStatus: 500).api);
      await _send(tester, h.input, _loadFileAa('/tmp/src'));

      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('500'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets('a fresh payload clears the previous index', (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      await tester.tap(find.text('Extract Definitions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('complete · 1 definitions'), findsOneWidget);

      h.input.disconnect();
      await _send(tester, h.input, _loadFileAa('/tmp/src/b.jl'));

      expect(find.textContaining('definitions'), findsNothing);
    });
  });

  group('AstExtractResult', () {
    test('counts definitions by kind', () {
      const result = AstExtractResult(
        aa: AaPayload(
          rows: ['a', 'b', 'c'],
          cols: ['kind', 'kind', 'kind'],
          vals: ['function', 'macro', 'function'],
        ),
        definitionCount: 3,
        filesScanned: 1,
      );
      expect(result.kindCounts, {'function': 2, 'macro': 1});
    });
  });

  testWidgets('the Node Catalog instantiates it onto the canvas',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();

    final item = find.text('AST Extract').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(AstExtractNodeWidget), findsOneWidget);
    expect(find.textContaining('Wire a Load File node'), findsOneWidget);
  });
}
