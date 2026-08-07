import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/services/aa_preview_worker.dart';
import 'package:double_vision/widgets/aa_preview_table_widget.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Generates a synthetic sparse AA with [rowCount] × [colCount] filled cells.
AaPayload _syntheticPayload({required int rowCount, int colCount = 3}) {
  final rows = <String>[];
  final cols = <String>[];
  final vals = <Object>[];
  for (var i = 0; i < rowCount; i++) {
    for (var j = 0; j < colCount; j++) {
      rows.add('r$i');
      cols.add('c$j');
      vals.add('v${i}_$j');
    }
  }
  return AaPayload(rows: rows, cols: cols, vals: vals);
}

/// Synchronous worker — bypasses Isolate.run() for fast, deterministic tests.
class _MockWorker extends AaPreviewWorker {
  const _MockWorker();

  @override
  Future<AaPreviewPage> processPreviewPage(
    AaPayload aa, {
    int offset = 0,
    int limit = 50,
  }) async {
    final rows = aa.rows;
    final cols = aa.cols;
    final vals = aa.vals;

    final seenRows = <String>{};
    final allRowKeys = <String>[];
    for (final r in rows) {
      if (seenRows.add(r)) allRowKeys.add(r);
    }

    final seenCols = <String>{};
    final allColKeys = <String>[];
    for (final c in cols) {
      if (seenCols.add(c)) allColKeys.add(c);
    }

    final cellOf = <String, String>{};
    for (var i = 0; i < cols.length; i++) {
      cellOf['${rows[i]}\x00${cols[i]}'] = vals[i].toString();
    }

    final safeOffset = offset.clamp(0, allRowKeys.length);
    final end = (safeOffset + limit).clamp(0, allRowKeys.length);
    final pageKeys = allRowKeys.sublist(safeOffset, end);

    return AaPreviewPage(
      totalRowCount: allRowKeys.length,
      columns: allColKeys,
      rows: [
        for (final rk in pageKeys)
          AaRowViewModel(
            rowKey: rk,
            cells: {
              for (final ck in allColKeys)
                if (cellOf.containsKey('$rk\x00$ck')) ck: cellOf['$rk\x00$ck']!,
            },
          ),
      ],
      pageOffset: offset,
      pageLimit: limit,
    );
  }
}

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('AaPreviewTableWidget', () {
    testWidgets('empty payload shows empty-state label', (tester) async {
      await tester.pumpWidget(
        _wrap(const AaPreviewTableWidget(aa: AaPayload(), worker: _MockWorker())),
      );
      await tester.pump();
      expect(find.textContaining('Empty associative array'), findsOneWidget);
    });

    testWidgets('shows loading indicator on initial mount', (tester) async {
      final aa = _syntheticPayload(rowCount: 100);
      await tester.pumpWidget(
        _wrap(AaPreviewTableWidget(aa: aa, worker: const _MockWorker())),
      );
      // Before the mock Future resolves, the widget shows a spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders total row count in stats bar', (tester) async {
      final aa = _syntheticPayload(rowCount: 200, colCount: 4);
      await tester.pumpWidget(
        _wrap(AaPreviewTableWidget(aa: aa, worker: const _MockWorker())),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('200 rows'), findsOneWidget);
      expect(find.textContaining('4 cols'), findsOneWidget);
    });

    testWidgets('stats bar shows page 1 of N on first load', (tester) async {
      // 200 rows ÷ 50 per page = 4 pages.
      final aa = _syntheticPayload(rowCount: 200);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('page 1 of 4'), findsOneWidget);
    });

    testWidgets('next page button advances to page 2', (tester) async {
      final aa = _syntheticPayload(rowCount: 200);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Page 1 of 4'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.textContaining('Page 2 of 4'), findsOneWidget);
    });

    testWidgets('previous page button goes back to page 1', (tester) async {
      final aa = _syntheticPayload(rowCount: 200);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.textContaining('Page 2 of 4'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.textContaining('Page 1 of 4'), findsOneWidget);
    });

    testWidgets('page size chip changes rows per page', (tester) async {
      // 200 rows ÷ 25 per page = 8 pages.
      final aa = _syntheticPayload(rowCount: 200);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();
      expect(find.textContaining('page 1 of 8'), findsOneWidget);
    });

    testWidgets('ListView.builder renders O(viewport) rows, not O(total rows)',
        (tester) async {
      // 10,000-row payload; default test viewport is ~600 px tall.
      // With _kRowHeight = 36 px, at most ~15 data rows fit in the viewport.
      final aa = _syntheticPayload(rowCount: 10000, colCount: 3);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();

      // Find all Text widgets inside the ListView (data cells).  A naive
      // DataTable implementation would produce 10,000 row-key texts; the
      // virtualized ListView.builder produces only as many as fit in the
      // visible viewport.
      final listView = find.byType(ListView);
      expect(listView, findsOneWidget);

      final cellTexts = tester
          .widgetList<Text>(
            find.descendant(of: listView, matching: find.byType(Text)),
          )
          .length;
      // With 50 rows per page, up to 50 × (1 + 3) = 200 cells maximum.
      // But the viewport only materialises ~15 rows, so ≤ 60 cells in tree.
      expect(cellTexts, lessThan(200),
          reason: 'ListView.builder should only materialise visible rows');
    });

    testWidgets('column header row renders all column names', (tester) async {
      final aa = _syntheticPayload(rowCount: 10, colCount: 4);
      await tester.pumpWidget(
        _wrap(AaPreviewTableWidget(aa: aa, worker: const _MockWorker())),
      );
      await tester.pumpAndSettle();
      // Header row always includes the synthetic column names c0..c3 and 'row'.
      expect(find.text('row'), findsOneWidget);
      for (final col in ['c0', 'c1', 'c2', 'c3']) {
        expect(find.text(col), findsOneWidget);
      }
    });

    // ── Widget stress test (mock worker, 100k rows) ──────────────────────────
    //
    // Verifies that the widget itself stays O(viewport) even with a 100k-row
    // payload.  Uses _MockWorker to stay inside Flutter's fake-async test
    // environment (real Isolate.run() is validated in the worker unit tests
    // below, outside of testWidgets).

    testWidgets('100k-row payload: O(1) rendering with mock worker',
        (tester) async {
      final aa = _syntheticPayload(rowCount: 100000, colCount: 5);
      await tester.pumpWidget(
        _wrap(
          AaPreviewTableWidget(aa: aa, worker: const _MockWorker(), pageSize: 50),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('100,000 rows'), findsOneWidget);

      final listView = find.byType(ListView);
      expect(listView, findsOneWidget);
      final cellTexts = tester
          .widgetList<Text>(
            find.descendant(of: listView, matching: find.byType(Text)),
          )
          .length;
      // Viewport renders ~15 rows × 6 cells max — far fewer than 100,000 rows.
      expect(cellTexts, lessThan(500),
          reason: 'ListView.builder must not materialise all 100k rows');
    });
  });

  // ── Worker unit tests (real Isolate.run()) ───────────────────────────────
  //
  // These run as plain `test()` calls, outside Flutter's fake-async binding,
  // so real isolate message delivery works correctly.

  group('AaPreviewWorker', () {
    test('100k-row payload: completes with correct slice', () async {
      final aa = _syntheticPayload(rowCount: 100000, colCount: 5);
      const worker = AaPreviewWorker();

      final page = await worker.processPreviewPage(aa, offset: 0, limit: 50);

      expect(page.totalRowCount, 100000);
      expect(page.columns.length, 5);
      expect(page.rows.length, 50);
      expect(page.pageOffset, 0);
      expect(page.currentPage, 0);
      expect(page.pageCount, 2000); // 100000 ÷ 50
      expect(page.rows.first.rowKey, 'r0');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('respects offset and limit for mid-table pages', () async {
      final aa = _syntheticPayload(rowCount: 200, colCount: 3);
      const worker = AaPreviewWorker();

      final page = await worker.processPreviewPage(aa, offset: 100, limit: 25);

      expect(page.totalRowCount, 200);
      expect(page.rows.length, 25);
      expect(page.pageOffset, 100);
      expect(page.rows.first.rowKey, 'r100');
      expect(page.rows.last.rowKey, 'r124');
    });

    test('empty payload returns zero-row page without error', () async {
      const worker = AaPreviewWorker();

      final page = await worker.processPreviewPage(const AaPayload());

      expect(page.totalRowCount, 0);
      expect(page.columns, isEmpty);
      expect(page.rows, isEmpty);
    });

    test('cell values are populated correctly in the slice', () async {
      final aa = _syntheticPayload(rowCount: 10, colCount: 3);
      const worker = AaPreviewWorker();

      final page = await worker.processPreviewPage(aa, offset: 0, limit: 10);

      expect(page.rows.first.cells['c0'], 'v0_0');
      expect(page.rows.first.cells['c1'], 'v0_1');
      expect(page.rows.first.cells['c2'], 'v0_2');
    });
  });
}
