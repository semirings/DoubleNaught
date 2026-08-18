import 'package:flutter/material.dart';

import '../config/node_registry.dart';

/// The Node Catalog: a searchable, category-grouped palette of node primitives.
///
/// Self-contained and injectable — it takes its [catalog] and reports a choice
/// through [onSelected], so it can be mounted directly in a test without a canvas.
/// [showNodeCatalog] is what the workflow header actually opens.
///
/// Three behaviours are deliberate rather than incidental:
///
/// * **Categories start expanded.** A palette whose contents are hidden behind
///   six closed headers is worse than a long list — the point of the grouping is
///   to give the eye somewhere to land, not to hide things.
/// * **A search overrides collapse.** Typing expands every category that has a
///   hit, so a match can never be hidden inside a section that happens to be
///   shut. Clearing the query restores whatever was collapsed by hand.
/// * **Empty categories are not rendered.** `AST & Code Analysis` currently has
///   no canvas widgets (Extract AST and Patch Docstrings are backend-only), and a
///   header reading "(0)" invites a click that does nothing. Its chip still
///   exists, and selecting it shows the empty state — which is the honest answer.
class NodeCatalogWidget extends StatefulWidget {
  /// Called with the chosen node. The caller closes the surface.
  final ValueChanged<NodeType> onSelected;

  /// Defaults to the registry; injected in tests.
  final List<NodeType> catalog;

  /// Autofocus the search field. On by default — the palette is search-first —
  /// but off in tests that then need keyboard focus elsewhere.
  final bool autofocusSearch;

  const NodeCatalogWidget({
    super.key,
    required this.onSelected,
    this.catalog = nodeTypes,
    this.autofocusSearch = true,
  });

  @override
  State<NodeCatalogWidget> createState() => _NodeCatalogWidgetState();
}

class _NodeCatalogWidgetState extends State<NodeCatalogWidget> {
  final TextEditingController _search = TextEditingController();

  /// Null means "All".
  NodeCategory? _category;

  /// Categories the user has collapsed. Empty at first — everything is open.
  final Set<NodeCategory> _collapsed = {};

  String get _query => _search.text.trim();
  bool get _searching => _query.isNotEmpty;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Nodes matching the query, grouped by category in registry order.
  ///
  /// The chip filter is applied here too, so the counts in the headers are the
  /// counts of what is actually on screen rather than of the whole registry.
  Map<NodeCategory, List<NodeType>> get _grouped {
    final grouped = <NodeCategory, List<NodeType>>{};
    for (final category in NodeCategory.values) {
      if (_category != null && category != _category) continue;
      final matches = [
        for (final node in widget.catalog)
          if (node.category == category && node.matches(_query)) node,
      ];
      if (matches.isNotEmpty) grouped[category] = matches;
    }
    return grouped;
  }

  int get _matchCount =>
      _grouped.values.fold(0, (total, nodes) => total + nodes.length);

  bool _isExpanded(NodeCategory category) =>
      _searching || !_collapsed.contains(category);

  void _toggle(NodeCategory category) {
    setState(() {
      if (!_collapsed.remove(category)) _collapsed.add(category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grouped = _grouped;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(theme, scheme),
        const SizedBox(height: 8),
        _chips(theme),
        const SizedBox(height: 4),
        Divider(height: 9, color: scheme.outlineVariant),
        Flexible(
          child: grouped.isEmpty
              ? _emptyState(theme, scheme)
              // A Column in a scroll view rather than a ListView: the catalog is
              // ~30 items, and a lazy list would leave off-screen tiles unbuilt —
              // invisible to `ensureVisible` and to anything else that expects the
              // whole palette to exist once it is open.
              : SingleChildScrollView(
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in grouped.entries) ...[
                        _categoryHeader(
                            theme, scheme, entry.key, entry.value.length),
                        if (_isExpanded(entry.key))
                          for (final node in entry.value)
                            _nodeTile(theme, scheme, node),
                      ],
                    ],
                  ),
                ),
        ),
        if (_matchCount > 0) ...[
          Divider(height: 9, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _searching
                  ? '$_matchCount of ${widget.catalog.length} nodes'
                  : '${widget.catalog.length} nodes',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ],
    );
  }

  Widget _searchField(ThemeData theme, ColorScheme scheme) {
    return TextField(
      controller: _search,
      autofocus: widget.autofocusSearch,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Search nodes',
        prefixIcon: const Icon(Icons.search, size: 18),
        // Only offered once there is something to clear.
        suffixIcon: _searching
            ? IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(_search.clear),
              )
            : null,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  /// `All` plus one chip per category — including categories with no nodes, so
  /// the taxonomy is visible even where it is not yet populated.
  Widget _chips(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilterChip(
            label: const Text('All'),
            selected: _category == null,
            onSelected: (_) => setState(() => _category = null),
            visualDensity: VisualDensity.compact,
          ),
          for (final category in NodeCategory.values) ...[
            const SizedBox(width: 6),
            FilterChip(
              label: Text(category.chip),
              selected: _category == category,
              // Tapping the selected chip returns to All, so the filter can be
              // cleared without hunting for the All chip.
              onSelected: (_) => setState(
                () => _category = _category == category ? null : category,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  Widget _categoryHeader(
    ThemeData theme,
    ColorScheme scheme,
    NodeCategory category,
    int count,
  ) {
    final expanded = _isExpanded(category);
    return InkWell(
      // A search forces expansion, so the header is inert while one is active.
      onTap: _searching ? null : () => _toggle(category),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 16,
              color: _searching ? scheme.outline : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                '${category.label} ($count)',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nodeTile(ThemeData theme, ColorScheme scheme, NodeType node) {
    return InkWell(
      onTap: () => widget.onSelected(node),
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 8, top: 5, bottom: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(node.name, style: theme.textTheme.bodyMedium),
            if (node.description.isNotEmpty)
              Text(
                node.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme, ColorScheme scheme) {
    // Two ways to get here: a query that matches nothing, or a chip whose
    // category has no nodes yet. They need different wording — "No nodes match
    // ''" would be nonsense for the second.
    final message = _searching
        ? 'No nodes match "$_query"'
        : 'No nodes in ${_category?.label ?? 'the catalog'} yet';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 22, color: scheme.outline),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (_searching || _category != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _search.clear();
                _category = null;
              }),
              child: const Text('Reset filters'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Open the catalog as a palette anchored under the header, resolving to the
/// chosen node — or null if dismissed.
///
/// A dialog rather than a `PopupMenuButton`: the search field needs focus and the
/// chips need taps, and a menu route closes on any tap inside it.
Future<NodeType?> showNodeCatalog(
  BuildContext context, {
  List<NodeType> catalog = nodeTypes,
  bool autofocusSearch = true,
}) {
  return showDialog<NodeType>(
    context: context,
    barrierColor: Colors.black26,
    builder: (context) => Align(
      alignment: Alignment.topLeft,
      child: Padding(
        // Clears the header strip, so the palette reads as hanging from the
        // Node Catalog button rather than floating over the canvas.
        padding: const EdgeInsets.only(left: 8, top: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 560),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: NodeCatalogWidget(
                catalog: catalog,
                autofocusSearch: autofocusSearch,
                onSelected: (node) => Navigator.of(context).pop(node),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
