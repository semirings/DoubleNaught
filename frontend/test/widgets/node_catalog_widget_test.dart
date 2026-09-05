import 'package:double_vision/config/node_registry.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/node_catalog_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A small, fixed catalog so assertions do not shift when the registry grows.
const List<NodeType> _fixture = [
  NodeType(
    name: 'File Source',
    type: 'file_source',
    category: NodeCategory.data,
    description: 'Read a local file and stream its raw contents.',
    tags: ['ingest', 'disk'],
  ),
  NodeType(
    name: 'Save File',
    type: 'save_file',
    category: NodeCategory.data,
    description: 'Write an AA, text or image to disk.',
    tags: ['export', 'jsonl'],
  ),
  NodeType(
    name: 'JSONL Formatter',
    type: 'jsonlFormatterNode',
    category: NodeCategory.formatting,
    description: 'Build ChatML training lines.',
    tags: ['chatml', 'dataset'],
  ),
  NodeType(
    name: 'Remote Service',
    type: 'remoteServiceNode',
    category: NodeCategory.ai,
    description: 'Send a payload to Gemini or Claude.',
    tags: ['gemini', 'llm'],
  ),
  NodeType(
    name: 'Polyglot Exec',
    type: 'polyglotExecNode',
    category: NodeCategory.compute,
    description: 'Run Julia or Python source in a subprocess.',
    tags: ['julia', 'shell'],
  ),
];

Future<List<NodeType>> _pump(
  WidgetTester tester, {
  List<NodeType> catalog = _fixture,
}) async {
  final chosen = <NodeType>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 520,
          child: NodeCatalogWidget(
            catalog: catalog,
            autofocusSearch: false,
            onSelected: chosen.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return chosen;
}

/// Tap a filter chip, scrolling the chip row if it sits off the right edge.
Future<void> _tapChip(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(FilterChip, label);
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

/// Text inside the node list, excluding the search field's own content — which
/// `find.text` would otherwise match.
Finder _inList(String text) => find.descendant(
      of: find.byType(SingleChildScrollView).last,
      matching: find.text(text),
    );

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pumpAndSettle();
}

void main() {
  group('registry taxonomy', () {
    test('every catalog entry has a category', () {
      // A node without one would never be rendered, so this is a hard contract.
      expect(nodeTypes, isNotEmpty);
      for (final node in nodeTypes) {
        expect(NodeCategory.values, contains(node.category), reason: node.name);
      }
    });

    test('every node carries a description for the list and the search', () {
      for (final node in nodeTypes) {
        expect(node.description, isNotEmpty, reason: node.name);
      }
    });

    test('node names are unique, so a search result is unambiguous', () {
      final names = nodeTypes.map((n) => n.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('matches() searches name, description and tags', () {
      const node = NodeType(
        name: 'Polyglot Exec',
        type: 'polyglotExecNode',
        category: NodeCategory.compute,
        description: 'Run Julia or Python source in a subprocess.',
        tags: ['bash', 'shell'],
      );

      expect(node.matches('polyglot'), isTrue, reason: 'name');
      expect(node.matches('POLYGLOT'), isTrue, reason: 'case-insensitive');
      expect(node.matches('subprocess'), isTrue, reason: 'description');
      expect(node.matches('bash'), isTrue, reason: 'tag');
      expect(node.matches(''), isTrue, reason: 'a blank query matches all');
      expect(node.matches('   '), isTrue, reason: 'whitespace is blank');
      expect(node.matches('kubernetes'), isFalse);
    });
  });

  group('layout', () {
    testWidgets('shows a search field, an All chip and one chip per category',
        (tester) async {
      await _pump(tester);

      expect(find.text('Search nodes'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'All'), findsOneWidget);
      for (final category in NodeCategory.values) {
        expect(
          find.widgetWithText(FilterChip, category.chip),
          findsOneWidget,
          reason: category.label,
        );
      }
    });

    testWidgets('groups nodes under category headers with counts',
        (tester) async {
      await _pump(tester);

      expect(find.text('Data & Ingestion (2)'), findsOneWidget);
      expect(find.text('Formatting & Serialization (1)'), findsOneWidget);
      expect(find.text('AI & Teacher Models (1)'), findsOneWidget);
      expect(find.text('Execution & Compute (1)'), findsOneWidget);
    });

    testWidgets('a category with no nodes gets no header', (tester) async {
      await _pump(tester);
      // The fixture has nothing under AST & Code Analysis.
      expect(find.textContaining('AST & Code Analysis'), findsNothing);
      // …but its chip is still offered.
      expect(find.widgetWithText(FilterChip, 'Code'), findsOneWidget);
    });

    testWidgets('categories start expanded, so every node is visible',
        (tester) async {
      await _pump(tester);
      for (final node in _fixture) {
        expect(find.text(node.name), findsOneWidget, reason: node.name);
      }
    });

    testWidgets('descriptions are shown under the names', (tester) async {
      await _pump(tester);
      expect(find.text('Build ChatML training lines.'), findsOneWidget);
    });

    testWidgets('tapping a node reports it', (tester) async {
      final chosen = await _pump(tester);

      await tester.tap(find.text('Polyglot Exec'));
      await tester.pumpAndSettle();

      expect(chosen, hasLength(1));
      expect(chosen.single.type, 'polyglotExecNode');
    });
  });

  group('search filtering', () {
    testWidgets('filters by name as you type', (tester) async {
      await _pump(tester);
      await _search(tester, 'polyglot');

      expect(find.text('Polyglot Exec'), findsOneWidget);
      expect(find.text('File Source'), findsNothing);
      expect(find.text('JSONL Formatter'), findsNothing);
    });

    testWidgets('filters by description', (tester) async {
      await _pump(tester);
      await _search(tester, 'subprocess');

      expect(find.text('Polyglot Exec'), findsOneWidget);
      expect(find.text('Save File'), findsNothing);
    });

    testWidgets('filters by tag, which is never displayed', (tester) async {
      await _pump(tester);
      await _search(tester, 'gemini');

      expect(find.text('Remote Service'), findsOneWidget);
      // The tag is a search term only — it is never rendered as a label. (Scoped
      // to the list: `find.text` would otherwise match the search field itself.)
      expect(_inList('gemini'), findsNothing);
      expect(find.text('File Source'), findsNothing);
    });

    testWidgets('is case-insensitive', (tester) async {
      await _pump(tester);
      await _search(tester, 'JULIA');
      expect(find.text('Polyglot Exec'), findsOneWidget);
    });

    testWidgets('a tag match can pull a node out of another category',
        (tester) async {
      await _pump(tester);
      // 'jsonl' is a tag on Save File and appears in JSONL Formatter's name.
      await _search(tester, 'jsonl');

      expect(find.text('Save File'), findsOneWidget);
      expect(find.text('JSONL Formatter'), findsOneWidget);
      expect(find.text('Data & Ingestion (1)'), findsOneWidget);
      expect(find.text('Formatting & Serialization (1)'), findsOneWidget);
    });

    testWidgets('headers count only what survives the filter', (tester) async {
      await _pump(tester);
      expect(find.text('Data & Ingestion (2)'), findsOneWidget);

      await _search(tester, 'disk');
      // Both data nodes mention disk — one in its description, one in a tag.
      expect(find.text('Data & Ingestion (2)'), findsOneWidget);

      await _search(tester, 'stream');
      expect(find.text('Data & Ingestion (1)'), findsOneWidget);
    });

    testWidgets('the footer reports how many of the total matched',
        (tester) async {
      await _pump(tester);
      expect(find.text('5 nodes'), findsOneWidget);

      await _search(tester, 'julia');
      expect(find.text('1 of 5 nodes'), findsOneWidget);
    });

    testWidgets('clearing the search restores everything', (tester) async {
      await _pump(tester);
      await _search(tester, 'polyglot');
      expect(find.text('File Source'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(find.text('File Source'), findsOneWidget);
      expect(find.text('5 nodes'), findsOneWidget);
    });

    testWidgets('the clear button only appears once there is a query',
        (tester) async {
      await _pump(tester);
      expect(find.byTooltip('Clear search'), findsNothing);

      await _search(tester, 'a');
      expect(find.byTooltip('Clear search'), findsOneWidget);
    });
  });

  group('category expansion', () {
    testWidgets('tapping a header collapses its nodes', (tester) async {
      await _pump(tester);
      expect(find.text('File Source'), findsOneWidget);

      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();

      expect(find.text('File Source'), findsNothing);
      expect(find.text('Save File'), findsNothing);
      // The header stays, with its count — that is how you find it again.
      expect(find.text('Data & Ingestion (2)'), findsOneWidget);
      // Other categories are unaffected.
      expect(find.text('Polyglot Exec'), findsOneWidget);
    });

    testWidgets('tapping again expands it', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();
      expect(find.text('File Source'), findsNothing);

      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();
      expect(find.text('File Source'), findsOneWidget);
    });

    testWidgets('the chevron reflects the state', (tester) async {
      await _pump(tester);
      expect(find.byIcon(Icons.expand_more), findsNWidgets(4));

      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNWidgets(3));
    });

    testWidgets('a search overrides a collapsed category', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Save File'), findsNothing);

      // A match must never hide inside a section that happens to be shut.
      await _search(tester, 'save');
      expect(find.text('Save File'), findsOneWidget);
    });

    testWidgets('clearing the search restores the hand-collapsed state',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Data & Ingestion (2)'));
      await tester.pumpAndSettle();

      await _search(tester, 'save');
      expect(find.text('Save File'), findsOneWidget);

      await _search(tester, '');
      expect(find.text('Save File'), findsNothing, reason: 'still collapsed');
    });
  });

  group('filter chips', () {
    testWidgets('a chip narrows the list to its category', (tester) async {
      await _pump(tester);

      await _tapChip(tester, 'Compute');

      expect(find.text('Polyglot Exec'), findsOneWidget);
      expect(find.text('File Source'), findsNothing);
      expect(find.textContaining('Data & Ingestion'), findsNothing);
    });

    testWidgets('All restores every category', (tester) async {
      await _pump(tester);
      await _tapChip(tester, 'Compute');
      await _tapChip(tester, 'All');

      expect(find.text('File Source'), findsOneWidget);
      expect(find.text('Polyglot Exec'), findsOneWidget);
    });

    testWidgets('tapping the selected chip clears it', (tester) async {
      await _pump(tester);
      await _tapChip(tester, 'Compute');
      expect(find.text('File Source'), findsNothing);

      await _tapChip(tester, 'Compute');

      expect(find.text('File Source'), findsOneWidget);
    });

    testWidgets('a chip and a search compose', (tester) async {
      await _pump(tester);
      await _tapChip(tester, 'Data');

      // 'jsonl' matches Save File (tag) and JSONL Formatter (name), but the chip
      // keeps the result inside Data & Ingestion.
      await _search(tester, 'jsonl');

      expect(find.text('Save File'), findsOneWidget);
      expect(find.text('JSONL Formatter'), findsNothing);
    });
  });

  group('empty state', () {
    testWidgets('names the query that matched nothing', (tester) async {
      await _pump(tester);
      await _search(tester, 'kubernetes');

      expect(find.text('No nodes match "kubernetes"'), findsOneWidget);
      expect(find.text('File Source'), findsNothing);
      // No category headers linger behind the message.
      expect(find.textContaining('Data & Ingestion'), findsNothing);
    });

    testWidgets('offers a reset that restores the list', (tester) async {
      await _pump(tester);
      await _search(tester, 'kubernetes');

      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();

      expect(find.text('File Source'), findsOneWidget);
      expect(find.textContaining('No nodes match'), findsNothing);
    });

    testWidgets('an empty category says so instead of quoting a blank query',
        (tester) async {
      await _pump(tester);

      await _tapChip(tester, 'Code');

      // '"No nodes match """ would be nonsense here.
      expect(find.text('No nodes in AST & Code Analysis yet'), findsOneWidget);
      expect(find.textContaining('No nodes match'), findsNothing);
    });

    testWidgets('the footer count is hidden when nothing matches',
        (tester) async {
      await _pump(tester);
      await _search(tester, 'kubernetes');
      // The running total is gone; only the hint and the message mention "nodes".
      expect(find.textContaining('of 5 nodes'), findsNothing);
      expect(find.text('5 nodes'), findsNothing);
    });
  });

  group('in the workflow header', () {
    testWidgets('the Node Catalog button opens the palette', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.pumpAndSettle();
      expect(find.byType(NodeCatalogWidget), findsNothing);

      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      expect(find.byType(NodeCatalogWidget), findsOneWidget);
      expect(find.text('Search nodes'), findsOneWidget);
    });

    testWidgets('searching and picking adds that node to the canvas',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'polyglot');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Polyglot Exec'));
      await tester.pumpAndSettle();

      // The palette closed and the node landed.
      expect(find.byType(NodeCatalogWidget), findsNothing);
      expect(find.text('Polyglot Exec'), findsOneWidget); // now a card title
    });

    testWidgets('dismissing without choosing adds nothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      // Tap the barrier.
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();

      expect(find.byType(NodeCatalogWidget), findsNothing);
      expect(find.textContaining('Use the Node Catalog menu'), findsOneWidget);
    });

    testWidgets('the deprecated and backend-only types are not offered',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node Catalog'));
      await tester.pumpAndSettle();

      expect(find.text('AA → JSONL'), findsNothing);
      expect(find.text('AA Binary Normalizer'), findsNothing);
    });
  });
}
