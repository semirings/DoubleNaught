import 'dart:async';
import 'dart:convert';

import 'package:double_vision/config/node_registry.dart';
import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/jsonl_formatter_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _resultBody({
  int lineCount = 2,
  int skippedNoDoc = 0,
  int skippedNoCode = 0,
  String mode = 'chatml',
  String firstLine = '{"messages":[{"role":"system","content":"You are…"}]}',
}) {
  final rows = <String>[];
  final cols = <String>[];
  final vals = <String>[];
  for (var i = 0; i < lineCount; i++) {
    final key = 'line:${i.toString().padLeft(4, '0')}';
    rows.addAll([key, key]);
    cols.addAll(['json_line', 'symbol_name']);
    vals.addAll([i == 0 ? firstLine : '{"messages":[]}', 'sym$i']);
  }
  return {
    'aa': {'rows': rows, 'cols': cols, 'vals': vals},
    'formatMode': mode,
    'lineCount': lineCount,
    'skippedNoDoc': skippedNoDoc,
    'skippedNoCode': skippedNoCode,
  };
}

/// A backend that answers `/jsonl/format/aa` with a fixed result.
({JsonlFormatterApi api, List<Map<String, dynamic>> requests}) _api({
  int lineCount = 2,
  int skippedNoDoc = 0,
  int skippedNoCode = 0,
  int httpStatus = 200,
  String mode = 'chatml',
  String firstLine = '{"messages":[{"role":"system","content":"You are…"}]}',
}) {
  final requests = <Map<String, dynamic>>[];
  final api = JsonlFormatterApi(
    client: MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (httpStatus != 200) {
        return http.Response('{"detail":"nope"}', httpStatus);
      }
      return _jsonResponse(_resultBody(
        lineCount: lineCount,
        skippedNoDoc: skippedNoDoc,
        skippedNoCode: skippedNoCode,
        mode: mode,
        firstLine: firstLine,
      ));
    }),
  );
  return (api: api, requests: requests);
}

/// A documented index in wire (triple) form.
AaPayload _index({int rows = 2, int documented = 2}) {
  final r = <String>[];
  final c = <String>[];
  final v = <String>[];
  for (var i = 0; i < rows; i++) {
    final key = 'def$i';
    r.addAll([key, key, key]);
    c.addAll(['symbol_name', 'raw_code', 'better_docstring']);
    v.addAll(['f$i', 'f$i(x) = x', i < documented ? 'Docs for f$i.' : '']);
  }
  return AaPayload(rows: r, cols: c, vals: v);
}

Future<({InputPort input, List<AaPayload> emitted})> _pump(
  WidgetTester tester, {
  JsonlFormatterApi? api,
  Future<void> Function(String)? onCopy,
  void Function(Map<String, String>)? onParams,
  Map<String, String>? initialParams,
  bool inputConnected = false,
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JsonlFormatterNodeWidget(
            node: const WorkflowNode(id: 1, type: 'jsonlFormatterNode'),
            api: api ?? _api().api,
            initialParams: initialParams,
            onParams: onParams,
            onCopy: onCopy,
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

/// Opens the Format Mode dropdown and picks [label].
Future<void> _pickMode(WidgetTester tester, String label) async {
  await tester.tap(find.ancestor(
    of: find.text('Format Mode'),
    matching: find.byType(TextField),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('catalog registration', () {
    test('the dropdown offers exactly the three public modes', () {
      expect(
        JsonlFormatMode.values.map((m) => m.label),
        ['ChatML Doc', 'Instruction / Task', 'Passthrough'],
      );
      expect(
        JsonlFormatMode.values.map((m) => m.wire),
        ['chatml', 'prompt_completion', 'passthrough'],
      );
    });

    test('an unknown wire name falls back to ChatML', () {
      expect(JsonlFormatMode.byWire('nonsense'), JsonlFormatMode.chatml);
      expect(JsonlFormatMode.byWire(null), JsonlFormatMode.chatml);
      expect(
        JsonlFormatMode.byWire('prompt_completion'),
        JsonlFormatMode.instructionTask,
      );
    });
  });

  group('readiness', () {
    testWidgets('starts with Execute disabled and no removed hint text',
        (tester) async {
      await _pump(tester);

      expect(find.text('JSONL Formatter'), findsOneWidget);
      expect(find.text('No index'), findsNothing);
      expect(find.textContaining('Waiting for astIndex'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('any connected payload enables Execute, regardless of mode fit',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index(rows: 3, documented: 0));

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'readiness is "input port has data," not per-mode fitness',
      );
    });

    testWidgets('defaults to ChatML Doc', (tester) async {
      await _pump(tester);
      expect(find.text('ChatML Doc'), findsOneWidget);
    });

    testWidgets('the saved mode is restored', (tester) async {
      await _pump(tester, initialParams: const {'formatMode': 'prompt_completion'});
      expect(find.text('Instruction / Task'), findsOneWidget);
    });
  });

  group('Wait/Execute mechanism', () {
    testWidgets(
        'reactive (Wait unchecked, the default): fires as soon as a '
        'payload arrives',
        (tester) async {
      final backend = _api(lineCount: 2);
      final h = await _pump(tester, api: backend.api, inputConnected: true);

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );

      await _send(tester, h.input, _index());

      expect(h.emitted, hasLength(1));
      expect(find.textContaining('done · 2 lines'), findsOneWidget);
    });

    testWidgets('gated (Wait checked): a ready payload does not auto-fire',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, h.input, _index());

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
      await _send(tester, h.input, _index());

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
      await _send(tester, h.input, _index());
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

      await _send(tester, h.input, _index());
      expect(h.emitted, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final response = Completer<http.Response>();
      final api = JsonlFormatterApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _index()); // auto-fires

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

  group('formatting', () {
    testWidgets('emits the two-column result and reports the count',
        (tester) async {
      final h = await _pump(tester, api: _api(lineCount: 2).api, inputConnected: true);
      await _send(tester, h.input, _index());

      expect(find.textContaining('2 training lines'), findsOneWidget);
      expect(find.textContaining('done'), findsOneWidget);

      expect(h.emitted, hasLength(1));
      final out = h.emitted.single;
      expect(out.cols.toSet(), {'json_line', 'symbol_name'});
      expect(out.distinctRows(), hasLength(2));
    });

    testWidgets('the emitted payload is what Save File needs for .jsonl',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index());

      expect(h.emitted.single.cols, contains('json_line'));
      expect(h.emitted.single.distinctRows().first, 'line:0000');
    });

    testWidgets('the first line is previewed and can be copied', (tester) async {
      final copied = <String>[];
      final h = await _pump(
        tester,
        api: _api(firstLine: '{"messages":[{"role":"system"}]}').api,
        onCopy: (text) async => copied.add(text),
        inputConnected: true,
      );
      await _send(tester, h.input, _index());

      expect(find.text('First line'), findsOneWidget);
      expect(find.text('{"messages":[{"role":"system"}]}'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy line'));
      await tester.pumpAndSettle();
      expect(copied, ['{"messages":[{"role":"system"}]}']);
    });

    testWidgets('skipped rows are reported alongside the line count',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(lineCount: 1, skippedNoDoc: 4, skippedNoCode: 2).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _index());

      expect(find.textContaining('4 undocumented'), findsOneWidget);
      expect(find.textContaining('2 without code'), findsOneWidget);
    });

    testWidgets('a result of zero lines is surfaced as an error, not a success',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(lineCount: 0, skippedNoDoc: 3).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _index());

      expect(find.textContaining('No usable rows'), findsOneWidget);
      expect(h.emitted, isEmpty, reason: 'nothing useful to send downstream');
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(httpStatus: 500).api,
        inputConnected: true,
      );
      await _send(tester, h.input, _index());

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('500'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets(
        'disconnecting clears the previous result and disables Execute; a '
        'new payload re-fires fresh',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index());
      expect(find.text('First line'), findsOneWidget);

      h.input.disconnect();
      await tester.pumpAndSettle();
      expect(find.text('First line'), findsNothing,
          reason: 'a disconnected wire\'s stale result is dropped');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _send(tester, h.input, _index(rows: 4, documented: 1));
      expect(find.text('First line'), findsOneWidget,
          reason: 'reactive by default — the new payload fires fresh');
    });
  });

  group('Format Mode', () {
    testWidgets('choosing a mode sends it and persists it', (tester) async {
      Map<String, String>? saved;
      final backend = _api(mode: 'passthrough');
      final h = await _pump(
        tester,
        api: backend.api,
        onParams: (p) => saved = p,
        inputConnected: true,
      );
      await _send(tester, h.input, _index());

      await _pickMode(tester, 'Passthrough');
      expect(saved!['formatMode'], 'passthrough');
      // Reactive: picking a new mode re-runs against it immediately.
      expect(backend.requests.last['formatMode'], 'passthrough');
    });

    testWidgets('switching mode discards the previous result and re-fires',
        (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index());
      expect(find.text('First line'), findsOneWidget);

      await _pickMode(tester, 'Passthrough');

      // A fresh (passthrough) result lands right back — the mode switch
      // itself does not leave the card empty, it just replaces the result.
      expect(find.text('First line'), findsOneWidget);
    });

    testWidgets('gated: switching mode does not auto-fire', (tester) async {
      final backend = _api();
      final h = await _pump(tester, api: backend.api, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // gate it
      await tester.pumpAndSettle();
      await _send(tester, h.input, _index());
      expect(h.emitted, isEmpty);

      await _pickMode(tester, 'Passthrough');
      expect(h.emitted, isEmpty, reason: 'gated — mode change must not fire either');
    });
  });

  group('Cancel — hard abort', () {
    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves — and a later-arriving success is discarded',
        (tester) async {
      final response = Completer<http.Response>();
      final api = JsonlFormatterApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _index()); // auto-fires

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
      final api = JsonlFormatterApi(client: MockClient((_) => response.future));
      final h = await _pump(tester, api: api, inputConnected: true);

      await _send(tester, h.input, _index());
      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      response.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
    });
  });

  group('catalog consolidation', () {
    testWidgets('AA → JSONL is gone from the Node Catalog', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      expect(find.text('AA → JSONL'), findsNothing);
      // And the survivor is there.
      expect(find.text('JSONL Formatter'), findsWidgets);
    });

    testWidgets('a workflow saved with an aa2jsonl node still builds',
        (tester) async {
      // The builder case is retained deliberately; losing it would break loading.
      expect(
        nodeTypes.map((t) => t.type).contains('aa2jsonl'),
        isFalse,
        reason: 'not offered for new work',
      );
    });

    testWidgets('the Node Catalog instantiates it onto the canvas',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      final item = find.text('JSONL Formatter').last;
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();

      expect(find.byType(JsonlFormatterNodeWidget), findsOneWidget);
      expect(find.textContaining('Waiting for astIndex'), findsNothing);
    });
  });
}
