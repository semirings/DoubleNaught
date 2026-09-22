import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/widgets/aa_dataframe.dart';
import 'package:double_vision/widgets/nodes/base/base_node.dart';
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

    testWidgets('the caption colors the row key and column key with the '
        'same constants the grid view uses, and the value uses the value '
        'color', (tester) async {
      const source = 'first\nsecond\nthird';
      await _pump(tester, const AaPayload(rows: ['r1'], cols: ['note'], vals: [source]));

      final caption = tester.widget<Text>(find.textContaining('r1 · note'));
      final spans = (caption.textSpan as TextSpan).children!.cast<TextSpan>();
      expect(spans[0].text, 'r1');
      expect(spans[0].style?.color, kAaRowHeaderColor);
      expect(spans[2].text, 'note');
      expect(spans[2].style?.color, kAaColumnHeaderColor);

      final value = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(value.style?.color, kAaValueColor);
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

  group('the three grid roles are colored distinctly', () {
    testWidgets('row header, column header, and value cell each use their '
        'own fixed color', (tester) async {
      await _pump(tester, const AaPayload(
        rows: ['r1'],
        cols: ['score'],
        vals: ['0.91'],
      ));

      final table = tester.widget<DataTable>(find.byType(DataTable));

      final columnLabel =
          (table.columns.last.label as ConstrainedBox).child as Text;
      expect(columnLabel.data, 'score');
      expect(table.headingTextStyle?.color, kAaColumnHeaderColor);

      final rowHeaderText =
          tester.widget<Text>(find.text('r1'));
      expect(rowHeaderText.style?.color, kAaRowHeaderColor);

      final valueText = tester.widget<Text>(find.text('0.91'));
      expect(valueText.style?.color, kAaValueColor);

      // The three roles are not all the same color as each other.
      expect(kAaRowHeaderColor, isNot(kAaColumnHeaderColor));
      expect(kAaColumnHeaderColor, isNot(kAaValueColor));
      expect(kAaRowHeaderColor, isNot(kAaValueColor));
    });

    testWidgets('the top-left corner is blank, not labeled "row"',
        (tester) async {
      await _pump(tester, const AaPayload(rows: ['r1'], cols: ['score'], vals: ['0.91']));

      expect(find.text('row'), findsNothing);

      final table = tester.widget<DataTable>(find.byType(DataTable));
      final corner = (table.columns.first.label as ConstrainedBox).child;
      expect(corner, isA<SizedBox>());
    });
  });
}
