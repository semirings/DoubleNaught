import 'package:flutter/material.dart';

import '../models/aa_payload.dart';
import '../services/aa_preview_worker.dart';

const double _kRowKeyWidth  = 160.0;
const double _kDataColWidth = 200.0;
const double _kRowHeight    = 36.0;
const double _kHeaderHeight = 36.0;
const double _kStatsHeight  = 36.0;
const double _kPagerHeight  = 44.0;

enum _TableState { idle, loading, ready, error }

/// High-performance, paginated preview table for large [AaPayload] objects.
///
/// Wide-table construction is offloaded to a background [Isolate] via
/// [AaPreviewWorker].  Only the current page is materialised; row rendering
/// uses [ListView.builder] so the widget tree is O(visible rows), not
/// O(total rows), regardless of payload size.
///
/// Inject a custom [worker] for testing.
class AaPreviewTableWidget extends StatefulWidget {
  final AaPayload aa;
  final int pageSize;
  final AaPreviewWorker worker;

  const AaPreviewTableWidget({
    super.key,
    required this.aa,
    this.pageSize = 50,
    this.worker = const AaPreviewWorker(),
  });

  @override
  State<AaPreviewTableWidget> createState() => _AaPreviewTableWidgetState();
}

class _AaPreviewTableWidgetState extends State<AaPreviewTableWidget> {
  late int _pageSize;
  final ScrollController _hScroll = ScrollController();
  final ScrollController _vScroll = ScrollController();

  _TableState _state = _TableState.idle;
  AaPreviewPage? _page;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _pageSize = widget.pageSize;
    _loadPage(0);
  }

  @override
  void didUpdateWidget(AaPreviewTableWidget old) {
    super.didUpdateWidget(old);
    if (!identical(old.aa, widget.aa)) {
      _loadPage(0);
    }
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  Future<void> _loadPage(int offset) async {
    if (!mounted) return;
    setState(() => _state = _TableState.loading);
    try {
      final page = await widget.worker.processPreviewPage(
        widget.aa,
        offset: offset,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _state = _TableState.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _TableState.error;
        _errorMsg = e.toString();
      });
    }
  }

  void _goToPage(int pageIndex) => _loadPage(pageIndex * _pageSize);

  void _changePageSize(int size) {
    _pageSize = size;
    _loadPage(0);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.aa.cols.isEmpty) {
      return Center(
        child: Text(
          'Empty associative array',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStatsBar(theme),
        Expanded(child: _buildTableArea(theme)),
        _buildPaginationBar(theme),
      ],
    );
  }

  // ── Stats bar ────────────────────────────────────────────────────────────

  Widget _buildStatsBar(ThemeData theme) {
    final page = _page;
    final label = page == null
        ? '…'
        : '${_fmt(page.totalRowCount)} rows'
          ' × ${page.columns.length} cols'
          ' — page ${_fmt(page.currentPage + 1)} of ${_fmt(page.pageCount)}';
    return Container(
      height: _kStatsHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  // ── Table area ───────────────────────────────────────────────────────────

  Widget _buildTableArea(ThemeData theme) {
    if (_page == null) {
      if (_state == _TableState.error) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Error loading preview:\n${_errorMsg ?? 'unknown error'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        LayoutBuilder(
          builder: (ctx, constraints) =>
              _buildScrollableTable(theme, constraints.maxHeight),
        ),
        if (_state == _TableState.loading)
          const Positioned(
            top: 0, left: 0, right: 0,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _buildScrollableTable(ThemeData theme, double availableHeight) {
    final page = _page!;
    final tableWidth = _kRowKeyWidth + page.columns.length * _kDataColWidth;
    final bodyHeight = (availableHeight - _kHeaderHeight).clamp(0.0, double.infinity);

    return Scrollbar(
      controller: _hScroll,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: SingleChildScrollView(
        controller: _hScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: tableWidth,
          child: Column(
            children: [
              _buildColumnHeader(theme, page.columns),
              SizedBox(
                height: bodyHeight,
                child: Scrollbar(
                  controller: _vScroll,
                  child: ListView.builder(
                    controller: _vScroll,
                    itemCount: page.rows.length,
                    itemExtent: _kRowHeight,
                    itemBuilder: (ctx, i) =>
                        _buildDataRow(theme, page.rows[i], page.columns, i),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Column header ────────────────────────────────────────────────────────

  Widget _buildColumnHeader(ThemeData theme, List<String> columns) {
    return SizedBox(
      height: _kHeaderHeight,
      child: Row(
        children: [
          _headerCell(theme, 'row', _kRowKeyWidth),
          for (final col in columns) _headerCell(theme, col, _kDataColWidth),
        ],
      ),
    );
  }

  Widget _headerCell(ThemeData theme, String label, double width) {
    return Container(
      width: width,
      height: _kHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          right: BorderSide(color: theme.dividerColor),
          bottom: BorderSide(color: theme.dividerColor, width: 1.5),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  // ── Data rows ────────────────────────────────────────────────────────────

  Widget _buildDataRow(
    ThemeData theme,
    AaRowViewModel row,
    List<String> columns,
    int index,
  ) {
    final bg = index.isOdd
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surface;
    return Container(
      height: _kRowHeight,
      color: bg,
      child: Row(
        children: [
          _dataCell(theme, row.rowKey, _kRowKeyWidth, bold: true),
          for (final col in columns)
            _dataCell(theme, row.cells[col] ?? '', _kDataColWidth),
        ],
      ),
    );
  }

  Widget _dataCell(
    ThemeData theme,
    String value,
    double width, {
    bool bold = false,
  }) {
    return Container(
      width: width,
      height: _kRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: bold ? FontWeight.w600 : null,
        ),
      ),
    );
  }

  // ── Pagination bar ───────────────────────────────────────────────────────

  Widget _buildPaginationBar(ThemeData theme) {
    final page = _page;
    final currentPage = page?.currentPage ?? 0;
    final pageCount = page?.pageCount ?? 1;
    final isLoading = _state == _TableState.loading;
    final hasPrev = currentPage > 0 && !isLoading;
    final hasNext = page != null && currentPage < pageCount - 1 && !isLoading;

    return Container(
      height: _kPagerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                iconSize: 20,
                onPressed: hasPrev ? () => _goToPage(currentPage - 1) : null,
                tooltip: 'Previous page',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              Text(
                'Page ${_fmt(currentPage + 1)} of ${_fmt(pageCount)}',
                style: theme.textTheme.bodySmall,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                iconSize: 20,
                onPressed: hasNext ? () => _goToPage(currentPage + 1) : null,
                tooltip: 'Next page',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          Row(
            children: [
              Text('Per page: ', style: theme.textTheme.bodySmall),
              for (final size in [25, 50, 100])
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: Text('$size'),
                    selected: _pageSize == size,
                    onSelected: !isLoading ? (_) => _changePageSize(size) : null,
                    labelStyle: theme.textTheme.labelSmall,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// Thousands separator formatting — avoids a dependency on `intl`.
String _fmt(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
