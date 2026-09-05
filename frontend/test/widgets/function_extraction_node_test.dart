import 'dart:async';
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

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _resultBody({
  List<(String, String)> definitions = const [('add_one', 'function')],
  int filesScanned = 1,
  List<String> errors = const [],
}) {
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
  return {
    'aa': {'rows': rows, 'cols': cols, 'vals': vals},
    'definitionCount': definitions.length,
    'filesScanned': filesScanned,
    'errors': errors,
    'root': '/tmp/src',
  };
}

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
      return _jsonResponse(_resultBody(
        definitions: definitions,
        filesScanned: filesScanned,
        errors: errors,
      ));
    }),
  );
  return (api: api, requests: requests);
}

Future<({InputPort input, List<AaPayload> emitted})> _pump(
  WidgetTester tester, {
  AstExtractApi? api,
  bool inputConnected = false,
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FunctionExtractionNodeWidget(
            node: const WorkflowNode(id: 1, type: 'functionExtractionNode'),
            api: api ?? _api().api,
            inputConnected: inputConnected,
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
    test('Function Extraction is registered under AST & Code Analysis', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'functionExtractionNode');
      expect(entry.name, 'Function Extraction');
      expect(entry.category, NodeCategory.code);
      expect(
        nodeTypes.where((t) => t.category == NodeCategory.code),
        isNotEmpty,
      );
    });

    test('it is findable by the words someone would type', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'functionExtractionNode');
      for (final query in ['ast', 'macro', 'parse', 'definitions', 'symbols']) {
        expect(entry.matches(query), isTrue, reason: query);
      }
    });
  });

  group('readiness — no free-text field, wired port only', () {
    testWidgets('starts with Execute disabled and no error/hint text', (tester) async {
      await _pump(tester);

      expect(find.text('Function Extraction'), findsOneWidget);
      // No text box at all — the node has no free-text field of its own.
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Wire a Load File node'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('a payload with a recognized path column enables Execute',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('a payload with text but no path column also enables Execute',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(
        tester,
        h.input,
        const AaPayload(rows: ['0'], cols: ['text'], vals: ['f(x) = x']),
      );

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('a payload with neither a path nor text leaves Execute disabled',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(
        tester,
        h.input,
        const AaPayload(rows: ['0'], cols: ['unrelated'], vals: ['x']),
      );

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });
  });

  group('Wait/Execute mechanism', () {
    testWidgets(
        'reactive (Wait unchecked, the default): fires as soon as a usable '
        'payload arrives',
        (tester) async {
      final backend = _api(definitions: const [('test_func', 'function')]);
      final h = await _pump(tester, api: backend.api, inputConnected: true);

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );

      await _send(tester, h.input, _loadFileAa('/tmp/src/model.jl'));

      expect(h.emitted, hasLength(1));
      expect(find.textContaining('done · 1 definitions'), findsOneWidget);
    });

    testWidgets('gated (Wait checked): a ready payload does not auto-fire',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));

      expect(h.emitted, isEmpty, reason: 'gated — nothing fires until Execute');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'Execute enablement is independent of Wait',
      );
    });

    testWidgets('clicking Execute fires immediately and unchecks Wait',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // gate it
      await tester.pumpAndSettle();
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      expect(h.emitted, hasLength(1));
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );
    });

    testWidgets(
        'manually unchecking Wait fires immediately when already ready',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      expect(h.emitted, isEmpty);

      await tester.tap(find.byType(WaitCheckbox)); // uncheck while ready
      await tester.pumpAndSettle();
      expect(h.emitted, hasLength(1));
    });

    testWidgets(
        'unchecking Wait while NOT ready just becomes reactive — fires '
        'later once ready, not immediately',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WaitCheckbox)); // uncheck — not ready yet
      await tester.pumpAndSettle();
      expect(h.emitted, isEmpty);

      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      expect(h.emitted, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final response = Completer<http.Response>();
      final api = AstExtractApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl')); // auto-fires

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).locked,
        isTrue,
      );
      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
        reason: 'locked — the tap must not have toggled it',
      );

      response.complete(_jsonResponse(_resultBody()));
      await tester.pumpAndSettle();
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
        inputConnected: true,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src'));

      expect(find.textContaining('done · 3 definitions'), findsOneWidget);
      expect(find.text('2 files scanned'), findsOneWidget);
      expect(find.textContaining('2 function'), findsOneWidget);
      expect(find.textContaining('1 macro'), findsOneWidget);

      expect(h.emitted, hasLength(1));
      final out = h.emitted.single;
      expect(out.cols.toSet(), _schema.toSet());
      expect(out.distinctRows(), hasLength(3), reason: 'one row per definition');
    });

    testWidgets('an empty index is surfaced, not emitted', (tester) async {
      final h = await _pump(
        tester,
        api: _api(definitions: const []).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/empty.jl'));

      expect(find.textContaining('No definitions found'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets('skipped files are reported alongside the count',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(errors: const ['broken.jl: parse failed']).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src'));

      expect(find.textContaining('1 file(s) skipped'), findsOneWidget);
      // A broken file does not stop the rest from flowing.
      expect(h.emitted, hasLength(1));
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(httpStatus: 500).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _loadFileAa('/tmp/src'));

      expect(find.textContaining('error'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets(
        'disconnecting clears the previous result and disables Execute; a '
        'new payload re-fires fresh',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      expect(find.textContaining('done · 1 definitions'), findsOneWidget);

      h.input.disconnect();
      await tester.pumpAndSettle();
      expect(find.textContaining('definitions'), findsNothing,
          reason: 'a disconnected wire\'s stale result is dropped');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _send(tester, h.input, _loadFileAa('/tmp/src/b.jl'));
      expect(find.textContaining('done · 1 definitions'), findsOneWidget,
          reason: 'reactive by default — the new payload fires fresh');
    });
  });

  group('Cancel — hard abort', () {
    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves — and a later-arriving success is discarded',
        (tester) async {
      final response = Completer<http.Response>();
      final api = AstExtractApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl')); // auto-fires

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isTrue,
      );
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      expect(find.textContaining('idle'), findsOneWidget);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isFalse,
      );

      response.complete(_jsonResponse(_resultBody()));
      await tester.pumpAndSettle();

      expect(h.emitted, isEmpty, reason: 'the cancelled run\'s result must not emit');
      expect(find.textContaining('idle'), findsOneWidget);
    });

    testWidgets('cancelling never surfaces error status', (tester) async {
      final response = Completer<http.Response>();
      final api = AstExtractApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _loadFileAa('/tmp/src/a.jl'));
      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      response.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
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

    final item = find.text('Function Extraction').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(FunctionExtractionNodeWidget), findsOneWidget);
  });
}
