import 'package:flutter/material.dart';

import '../models/aa_payload.dart';

/// Maximum rows/columns rendered in the table.  Beyond these limits a
/// truncation banner is shown and the rest is omitted so the widget tree stays
/// inside Flutter's per-frame budget even for very large AAs.
const int _kMaxRows = 200;
const int _kMaxCols = 100;

/// Renders a D4M/AA [AaPayload] as a dataframe-style table: distinct rows down
/// the side, distinct columns across the top, and the value at each `(row, col)`
/// triple in the cell (blank where the sparse array has no entry).
///
/// The table scrolls in both directions so a wide/tall AA stays readable inside
/// the Focus Panel.  Rows beyond [_kMaxRows] and columns beyond [_kMaxCols] are
/// omitted; a truncation notice is shown at the bottom when the AA is clipped.
class AaDataFrame extends StatefulWidget {
  final AaPayload aa;

  const AaDataFrame({super.key, required this.aa});

  @override
  State<AaDataFrame> createState() => _AaDataFrameState();
}

class _AaDataFrameState extends State<AaDataFrame> {
  final ScrollController _vController = ScrollController();
  final ScrollController _hController = ScrollController();

  @override
  void dispose() {
    _vController.dispose();
    _hController.dispose();
    super.dispose();
  }

  /// Whether this AA is one cell whose value is prose or source rather than a
  /// datum — multi-line, or long enough that a table cell would clip it.
  static bool _isSingleTextCell(
    List<String> rowKeys,
    List<String> colKeys,
    Map<String, String> cellOf,
  ) {
    if (rowKeys.length != 1 || colKeys.length != 1 || cellOf.length != 1) {
      return false;
    }
    final value = cellOf.values.first;
    return value.contains('\n') || value.length > 120;
  }

  /// The one-cell view: a caption naming the `(row, col)` it came from, then the
  /// whole value, scrollable and selectable.
  Widget _singleCellText(
    ThemeData theme,
    String rowKey,
    String colKey,
    String value,
  ) {
    final lines = value.split('\n').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '$rowKey · $colKey — ${value.length} chars, $lines lines',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _vController,
            child: SingleChildScrollView(
              controller: _vController,
              child: SelectableText(
                value,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.aa.cols.isEmpty) {
      return Center(
        child: Text('Empty associative array',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }

    final aa = widget.aa.toSparse();

    // Row keys in first-appearance order; column keys likewise.
    final allRowKeys = aa.distinctRows();
    final allColKeys = <String>[];
    for (final c in aa.cols) {
      if (!allColKeys.contains(c)) allColKeys.add(c);
    }

    // Apply display caps before building any widgets.
    final rowKeys = allRowKeys;
    final colKeys = allColKeys;

    debugPrint("AaDataFrame Received colKeys (${colKeys.length}): $colKeys");

    final rowsClipped = false;
    final colsClipped = false;

    // (row, col) -> value lookup — only index cells that will be displayed.
    final rowSet = rowKeys.toSet();
    final colSet = colKeys.toSet();
    const sep = '\x00';
    final cellOf = <String, String>{};
    for (var i = 0; i < aa.cols.length; i++) {
      final r = aa.rows[i];
      final c = aa.cols[i];
      if (rowSet.contains(r) && colSet.contains(c)) {
        cellOf['$r$sep$c'] = aa.vals[i].toString();
      }
    }

    // A whole file in one cell is not a table. A `Load File` source payload is a
    // single `text` triple holding thousands of characters, and a DataCell clips
    // at six lines — which reads exactly like a truncated load. Render it as the
    // text it is: complete, scrollable, selectable.
    if (_isSingleTextCell(rowKeys, colKeys, cellOf)) {
      return _singleCellText(
        theme,
        rowKeys.first,
        colKeys.first,
        cellOf.values.first,
      );
    }

    return Scrollbar(
      controller: _hController,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: SingleChildScrollView(
        controller: _hController,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Scrollbar(
          controller: _vController,
          scrollbarOrientation: ScrollbarOrientation.right,
          child: SingleChildScrollView(
            controller: _vController,
            scrollDirection: Axis.vertical,
            clipBehavior: Clip.none,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 28,
                  dataRowMaxHeight: 120,
                  columnSpacing: 16.0,
                  headingTextStyle: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                  columns: [
                    DataColumn(
                      label: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: 80),
                        child: Text('row'),
                      ),
                    ),
                    for (final c in colKeys)
                      DataColumn(
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 80),
                          child: Text(c),
                        ),
                      ),
                  ],
                  rows: [
                    for (final r in rowKeys)
                      DataRow(
                        cells: [
                          DataCell(Text(r,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                          for (final c in colKeys)
                            DataCell(
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 360),
                                child: Text(
                                  cellOf['$r$sep$c'] ?? '',
                                  maxLines: 6,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
                if (rowsClipped || colsClipped)
                  _TruncationBanner(
                    theme: theme,
                    totalRows: allRowKeys.length,
                    shownRows: rowKeys.length,
                    totalCols: allColKeys.length,
                    shownCols: colKeys.length,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TruncationBanner extends StatelessWidget {
  final ThemeData theme;
  final int totalRows;
  final int shownRows;
  final int totalCols;
  final int shownCols;

  const _TruncationBanner({
    required this.theme,
    required this.totalRows,
    required this.shownRows,
    required this.totalCols,
    required this.shownCols,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (shownRows < totalRows) {
      parts.add('$shownRows of $totalRows rows');
    }
    if (shownCols < totalCols) {
      parts.add('$shownCols of $totalCols columns');
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        'Showing ${parts.join(', ')} — resize or export to see all',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
