import 'dart:convert';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/jsonl_formatter_api.dart';
import 'package:double_vision/widgets/nodes/implementations/jsonl_formatter_node_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A backend that answers `/jsonl/format/aa` with a fixed result.
JsonlFormatterApi _api({
  int lineCount = 2,
  int skippedNoDoc = 0,
  int skippedNoCode = 0,
  int httpStatus = 200,
  String firstLine = '{"messages":[{"role":"system","content":"You are…"}]}',
  void Function(Map<String, dynamic> body)? onRequest,
}) {
  return JsonlFormatterApi(
    client: MockClient((request) async {
      onRequest?.call(jsonDecode(request.body) as Map<String, dynamic>);
      if (httpStatus != 200) {
        return http.Response('{"detail":"nope"}', httpStatus);
      }
      final rows = <String>[];
      final cols = <String>[];
      final vals = <String>[];
      for (var i = 0; i < lineCount; i++) {
        final key = 'line:${i.toString().padLeft(4, '0')}';
        rows.addAll([key, key]);
        cols.addAll(['json_line', 'symbol_name']);
        vals.addAll([i == 0 ? firstLine : '{"messages":[]}', 'sym$i']);
      }
      return http.Response(
        jsonEncode({
          'aa': {'rows': rows, 'cols': cols, 'vals': vals},
          'lineCount': lineCount,
          'skippedNoDoc': skippedNoDoc,
          'skippedNoCode': skippedNoCode,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
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
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JsonlFormatterNodeWidget(
            node: const WorkflowNode(id: 1, type: 'jsonlFormatterNode'),
            api: api ?? _api(),
            onCopy: onCopy,
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

void main() {
  group('IndexTally', () {
    test('counts definitions and how many are documented', () {
      final tally = IndexTally.of(_index(rows: 5, documented: 2));
      expect(tally.rows, 5);
      expect(tally.documented, 2);
      expect(tally.undocumented, 3);
    });

    test('whitespace-only docstrings do not count as documented', () {
      const aa = AaPayload(
        rows: ['a', 'a'],
        cols: ['raw_code', 'better_docstring'],
        vals: ['f(x) = x', '   \n '],
      );
      expect(IndexTally.of(aa).documented, 0);
      expect(IndexTally.of(aa).rows, 1);
    });

    test('accepts the camelCase spelling of the column', () {
      const aa = AaPayload(
        rows: ['a'],
        cols: ['betterDocstring'],
        vals: ['Docs.'],
      );
      expect(IndexTally.of(aa).documented, 1);
    });

    test('an empty payload tallies to nothing', () {
      expect(IndexTally.of(const AaPayload()).isEmpty, isTrue);
    });
  });

  group('JsonlFormatterNodeWidget', () {
    testWidgets('starts idle with Format disabled and nothing to show',
        (tester) async {
      await _pump(tester);

      expect(find.text('JSONL Formatter'), findsOneWidget);
      expect(find.text('No index'), findsOneWidget);
      expect(find.textContaining('Waiting for in_aa'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('shows the tally of what arrived', (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _index(rows: 5, documented: 2));

      expect(find.textContaining('5 definitions'), findsOneWidget);
      expect(find.textContaining('2 documented'), findsOneWidget);
      expect(find.textContaining('3 pending'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('an index with no docstrings keeps Format disabled and says why',
        (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _index(rows: 3, documented: 0));

      expect(find.textContaining('No rows carry a better_docstring'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('formatting emits the two-column result and reports the count',
        (tester) async {
      final h = await _pump(tester, api: _api(lineCount: 2));
      await _send(tester, h.input, _index());

      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 training lines'), findsOneWidget);
      expect(find.textContaining('complete'), findsOneWidget);

      expect(h.emitted, hasLength(1));
      final out = h.emitted.single;
      expect(out.cols.toSet(), {'json_line', 'symbol_name'});
      expect(out.distinctRows(), hasLength(2));
    });

    testWidgets('the emitted payload is what Save File needs for .jsonl',
        (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _index());
      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      // Save File auto-detects JSONL from exactly this column.
      expect(h.emitted.single.cols, contains('json_line'));
      // Row keys are zero-padded so line order survives a lexical sort.
      expect(h.emitted.single.distinctRows().first, 'line:0000');
    });

    testWidgets('the first line is previewed and can be copied', (tester) async {
      final copied = <String>[];
      final h = await _pump(
        tester,
        api: _api(firstLine: '{"messages":[{"role":"system"}]}'),
        onCopy: (text) async => copied.add(text),
      );
      await _send(tester, h.input, _index());
      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

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
        api: _api(lineCount: 1, skippedNoDoc: 4, skippedNoCode: 2),
      );
      await _send(tester, h.input, _index());

      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      expect(find.textContaining('4 undocumented'), findsOneWidget);
      expect(find.textContaining('2 without code'), findsOneWidget);
    });

    testWidgets('a result of zero lines is surfaced as an error, not a success',
        (tester) async {
      final h = await _pump(tester, api: _api(lineCount: 0, skippedNoDoc: 3));
      await _send(tester, h.input, _index());

      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No documented rows'), findsOneWidget);
      expect(h.emitted, isEmpty,
          reason: 'nothing useful to send downstream');
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(tester, api: _api(httpStatus: 500));
      await _send(tester, h.input, _index());

      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('500'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets('the whole index is sent to the backend', (tester) async {
      Map<String, dynamic>? sent;
      final h = await _pump(tester, api: _api(onRequest: (b) => sent = b));
      await _send(tester, h.input, _index(rows: 3, documented: 2));

      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();

      // Filtering is the backend's job — it owns the contract.
      final aa = sent!['aa'] as Map<String, dynamic>;
      expect((aa['cols'] as List), contains('better_docstring'));
      expect((aa['rows'] as List).length, 9);
    });

    testWidgets('a fresh index clears the previous result', (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _index());
      await tester.tap(find.text('Format ChatML'));
      await tester.pumpAndSettle();
      expect(find.text('First line'), findsOneWidget);

      // A second index arrives — the old preview must not linger.
      h.input.disconnect();
      await _send(tester, h.input, _index(rows: 4, documented: 1));

      expect(find.text('First line'), findsNothing);
      expect(find.textContaining('4 definitions'), findsOneWidget);
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
      expect(find.textContaining('Waiting for in_aa'), findsOneWidget);
    });
  });
}
