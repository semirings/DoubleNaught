import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/widgets/aa_dataframe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, AaPayload aa) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 600, height: 400, child: AaDataFrame(aa: aa))),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('single-cell text payloads', () {
    testWidgets('a multi-line cell renders in full, not in a table cell',
        (tester) async {
      // A `Load File` source payload: one triple, the whole file in it.
      final source = List.generate(40, (i) => 'line $i of the source file').join('\n');
      await _pump(tester, AaPayload(rows: const ['0'], cols: const ['text'], vals: [source]));

      // No DataTable — a table cell clips at six lines, which looked like a
      // truncated load.
      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);

      // The whole value is present, first line to last.
      final shown = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(shown.data, source);
      expect(shown.data, contains('line 0 of'));
      expect(shown.data, contains('line 39 of'));
    });

    testWidgets('the caption names the cell and its size', (tester) async {
      const source = 'first\nsecond\nthird';
      await _pump(tester, const AaPayload(rows: ['0'], cols: ['text'], vals: [source]));

      expect(find.text('0 · text — 18 chars, 3 lines'), findsOneWidget);
    });

    testWidgets('a long single-line cell also renders as text', (tester) async {
      final long = 'x' * 500;
      await _pump(tester, AaPayload(rows: const ['0'], cols: const ['text'], vals: [long]));

      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(DataTable), findsNothing);
    });
  });

  group('everything else still renders as a table', () {
    testWidgets('a short single cell stays a table', (tester) async {
      await _pump(tester, const AaPayload(rows: ['r1'], cols: ['score'], vals: ['0.91']));

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('0.91'), findsOneWidget);
    });

    testWidgets('a multi-row AA with long text stays a table', (tester) async {
      // Two rows: not the single-cell case, so the table is still right.
      final long = 'a very long value ' * 20;
      await _pump(tester, AaPayload(
        rows: const ['r1', 'r2'],
        cols: const ['text', 'text'],
        vals: [long, long],
      ));

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('a multi-column single row stays a table', (tester) async {
      await _pump(tester, const AaPayload(
        rows: ['0', '0'],
        cols: ['symbol_name', 'raw_code'],
        vals: ['add_one', 'function add_one(x)\n    x + 1\nend'],
      ));

      expect(find.byType(DataTable), findsOneWidget);
    });

    testWidgets('an empty AA says so', (tester) async {
      await _pump(tester, const AaPayload());
      expect(find.text('Empty associative array'), findsOneWidget);
    });
  });
}
