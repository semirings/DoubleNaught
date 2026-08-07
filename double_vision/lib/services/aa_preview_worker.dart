import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/aa_payload.dart';

/// Immutable view model for one visible row in the paginated preview table.
@immutable
class AaRowViewModel {
  final String rowKey;
  final Map<String, String> cells;
  const AaRowViewModel({required this.rowKey, required this.cells});
}

/// Result of a [AaPreviewWorker.processPreviewPage] call.  Carries the full
/// row/column counts for pagination controls and the per-page slice for
/// rendering.
@immutable
class AaPreviewPage {
  final int totalRowCount;
  final List<String> columns;
  final List<AaRowViewModel> rows;
  final int pageOffset;
  final int pageLimit;

  const AaPreviewPage({
    required this.totalRowCount,
    required this.columns,
    required this.rows,
    required this.pageOffset,
    required this.pageLimit,
  });

  int get pageCount =>
      totalRowCount == 0 ? 1 : (totalRowCount + pageLimit - 1) ~/ pageLimit;

  int get currentPage => pageLimit > 0 ? pageOffset ~/ pageLimit : 0;
}

// Top-level function — required so the closure passed to Isolate.run() only
// captures primitive/sendable values (List<String>, List<Object>, int).
Map<String, dynamic> _computeSlice(
  List<String> rows,
  List<String> cols,
  List<Object> vals,
  int offset,
  int limit,
) {
  // Distinct row keys and column keys in first-appearance order.
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

  // Cell lookup: 'rowKey\x00colKey' → value string.
  final cellOf = <String, String>{};
  for (var i = 0; i < cols.length; i++) {
    cellOf['${rows[i]}\x00${cols[i]}'] = vals[i].toString();
  }

  // Paginate row keys.
  final safeOffset = offset.clamp(0, allRowKeys.length);
  final end = (safeOffset + limit).clamp(0, allRowKeys.length);
  final pageKeys = allRowKeys.sublist(safeOffset, end);

  // Build a cell-map per row in the slice.
  final pageCells = <Map<String, String>>[
    for (final rk in pageKeys)
      <String, String>{
        for (final ck in allColKeys)
          if (cellOf.containsKey('$rk\x00$ck')) ck: cellOf['$rk\x00$ck']!,
      },
  ];

  return {
    'totalRowCount': allRowKeys.length,
    'columns': allColKeys,
    'pageRowKeys': pageKeys,
    'pageCells': pageCells,
  };
}

/// Offloads AA wide-table construction to a background [Isolate] via
/// [Isolate.run], keeping the UI thread free during large-payload processing.
class AaPreviewWorker {
  const AaPreviewWorker();

  Future<AaPreviewPage> processPreviewPage(
    AaPayload aa, {
    int offset = 0,
    int limit = 50,
  }) async {
    final rows = aa.rows;
    final cols = aa.cols;
    final vals = aa.vals;

    final raw = await Isolate.run(
      () => _computeSlice(rows, cols, vals, offset, limit),
    );

    final pageRowKeys = (raw['pageRowKeys']! as List).cast<String>();
    final pageCells = (raw['pageCells']! as List)
        .map((e) => Map<String, String>.from(e as Map))
        .toList();

    return AaPreviewPage(
      totalRowCount: raw['totalRowCount']! as int,
      columns: (raw['columns']! as List).cast<String>(),
      rows: [
        for (var i = 0; i < pageRowKeys.length; i++)
          AaRowViewModel(rowKey: pageRowKeys[i], cells: pageCells[i]),
      ],
      pageOffset: offset,
      pageLimit: limit,
    );
  }
}
