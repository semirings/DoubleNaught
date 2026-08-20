import 'dart:async';
import 'dart:convert';

import 'package:double_vision/config/node_registry.dart';
import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// This node was originally "Remote Service": a vault-backed node dispatching
// to a user-picked provider (Anthropic/OpenAI/Gemini/Ollama) via
// `RemoteRequest`, with a live `ModelCatalog` fetch for the model picker.
// That design was fully replaced by a from-scratch rewrite (the backend grew
// `llm_better_doc.py`, a local-model AST enricher) before the node was
// renamed to "LLM Documenter" — the two are unrelated beyond the name.
// `RemoteRequest` and `ModelCatalog` are still real, live code (used by other
// nodes and kept in their own test files at test/services/); this file only
// covers what LLMDocumenterNodeWidget actually does today.

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

Map<String, dynamic> _enrichBody({
  int rowsProcessed = 1,
  List<String> rows = const ['a.jl:0:0'],
}) {
  final outRows = <String>[];
  final outCols = <String>[];
  final outVals = <String>[];
  for (final key in rows) {
    for (final column in _schema) {
      outRows.add(key);
      outCols.add(column);
      outVals.add(column == 'better_docstring' ? 'Adds one to x.' : '');
    }
  }
  return {
    'enrichedIndex': {'rows': outRows, 'cols': outCols, 'vals': outVals},
    'rowsProcessed': rowsProcessed,
  };
}

/// A 7-column index in wire form, one row.
const _index = AaPayload(
  rows: ['a.jl:0:0', 'a.jl:0:0'],
  cols: ['symbol_name', 'raw_code'],
  vals: ['add_one', 'add_one(x) = x + 1'],
);

Future<
    ({
      InputPort input,
      List<AaPayload> emitted,
      List<Map<String, dynamic>> requests,
    })> _pump(
  WidgetTester tester, {
  http.Client Function()? clientFactory,
  Map<String, String>? initialParams,
  bool inputConnected = false,
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];
  final requests = <Map<String, dynamic>>[];

  final factory = clientFactory ??
      () => MockClient((request) async {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonResponse(_enrichBody());
          });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LLMDocumenterNodeWidget(
            node: const WorkflowNode(id: 1, type: 'llmDocumenterNode'),
            initialParams: initialParams,
            clientFactory: factory,
            inputConnected: inputConnected,
            onInputPort: (p) => port = p,
            onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (input: port!, emitted: emitted, requests: requests);
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

void main() {
  group('catalog registration', () {
    test('LLM Documenter is registered', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'llmDocumenterNode');
      expect(entry.name, 'LLM Documenter');
    });
  });

  group('readiness', () {
    testWidgets('starts with Execute disabled and no removed hint text',
        (tester) async {
      await _pump(tester);

      expect(find.text('LLM Documenter'), findsOneWidget);
      expect(find.textContaining('Waiting for astIndex'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('a connected payload enables Execute', (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('the Model field shows the only model this backend loads',
        (tester) async {
      await _pump(tester);
      expect(find.text('mlx-community/Phi-4-mini-instruct-4bit'), findsOneWidget);
    });
  });

  group('Wait/Execute mechanism', () {
    testWidgets(
        'reactive (Wait unchecked, the default): fires as soon as a '
        'payload arrives',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );

      await _send(tester, h.input, _index);

      expect(h.emitted, hasLength(1));
      expect(find.textContaining('done'), findsOneWidget);
    });

    testWidgets('gated (Wait checked): a ready payload does not auto-fire',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, h.input, _index);

      expect(h.emitted, isEmpty, reason: 'gated — nothing fires until Execute');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('clicking Execute fires immediately and unchecks Wait',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // gate it
      await tester.pumpAndSettle();
      await _send(tester, h.input, _index);

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
      await _send(tester, h.input, _index);
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

      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index); // auto-fires

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

      response.complete(_jsonResponse(_enrichBody()));
      await tester.pumpAndSettle();
    });
  });

  group('enrichment', () {
    testWidgets('emits the enriched index and reports counts', (tester) async {
      final h = await _pump(
        tester,
        inputConnected: true,
        clientFactory: () => MockClient(
          (request) async => _jsonResponse(_enrichBody(rowsProcessed: 3)),
        ),
      );
      await _send(tester, h.input, _index);

      expect(find.textContaining('done'), findsOneWidget);
      expect(find.textContaining('3 rows'), findsOneWidget);
      expect(h.emitted, hasLength(1));
      expect(h.emitted.single.cols, contains('better_docstring'));
    });

    testWidgets('sends the fixed model id and the numeric fields',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);

      final sent = h.requests.single;
      expect(sent['modelId'], 'mlx-community/Phi-4-mini-instruct-4bit');
      expect(sent['maxTokens'], 256);
      expect(sent['temperature'], 0.7);
    });

    testWidgets('unparseable Max Tokens / Temperature fall back to defaults '
        'rather than blocking Execute', (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);

      await tester.enterText(
        find.ancestor(
          of: find.text('Max Tokens'),
          matching: find.byType(TextField),
        ),
        'lots',
      );
      await tester.enterText(
        find.ancestor(
          of: find.text('Temperature'),
          matching: find.byType(TextField),
        ),
        'warm',
      );

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'invalid numeric text falls back to a default, like Polyglot '
            "Exec's Timeout field — it does not gate Execute",
      );

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      final sent = h.requests.last;
      expect(sent['maxTokens'], 256);
      expect(sent['temperature'], 0.7);
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(
        tester,
        inputConnected: true,
        clientFactory: () => MockClient(
          (request) async =>
              http.Response('{"detail":"model unavailable"}', 500),
        ),
      );
      await _send(tester, h.input, _index);

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('model unavailable'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets(
        'disconnecting clears the previous result and disables Execute; a '
        'new payload re-fires fresh',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(1));

      h.input.disconnect();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(2),
          reason: 'reactive by default — the new payload fires fresh');
    });
  });

  group('Cancel — hard abort', () {
    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves — and a later-arriving success is discarded',
        (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index); // auto-fires

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

      response.complete(_jsonResponse(_enrichBody()));
      await tester.pumpAndSettle();

      expect(h.emitted, isEmpty, reason: 'the cancelled run\'s result must not emit');
      expect(find.textContaining('idle'), findsOneWidget);
    });

    testWidgets('cancelling never surfaces error status', (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index);
      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      response.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
    });
  });

  testWidgets('the Node Catalog instantiates it onto the canvas',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();

    final item = find.text('LLM Documenter').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(LLMDocumenterNodeWidget), findsOneWidget);
    expect(find.textContaining('Waiting for astIndex'), findsNothing);
  });
}
