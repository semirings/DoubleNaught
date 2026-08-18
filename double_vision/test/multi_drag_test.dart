import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Add a node of the given menu name via the Node Catalog dropdown.
Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.text('Node Catalog'));
  await tester.pumpAndSettle();
  final item = find.text(name).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// Click a node's card, optionally extending the selection.
///
/// tapAt(getCenter(...)) rather than tap(finder): Flutter 3.44's tap() resolves a
/// view via _maybeViewOf, which fails for widgets inside the canvas Transform.
Future<void> _click(WidgetTester tester, Finder node, {bool shift = false}) async {
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }
  await tester.tapAt(tester.getCenter(node));
  await tester.pump();
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }
}

/// Drag a node by the grip in its title bar.
///
/// The grip is the reliable target: the page's drag handle is a sibling overlay
/// covering the title strip, so a drag at the grip's centre lands on it — the
/// same idiom `workflow_page_test.dart` uses.
Future<void> _dragTitleBar(
  WidgetTester tester,
  Finder node,
  Offset by,
) async {
  await tester.drag(
    find.descendant(of: node, matching: find.byIcon(Icons.drag_indicator)),
    by,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dragging one node of a multi-selection moves them all',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'Prompt');
    await _add(tester, 'Preview');

    await _click(tester, find.byType(PromptNodeWidget));
    await _click(tester, find.byType(PreviewNode), shift: true);
    expect(find.text('2 nodes selected'), findsOneWidget);

    final promptBefore = tester.getTopLeft(find.byType(PromptNodeWidget));
    final previewBefore = tester.getTopLeft(find.byType(PreviewNode));

    const by = Offset(60, 45);
    await _dragTitleBar(tester, find.byType(PromptNodeWidget), by);

    // Both moved, by the same amount — the arrangement is preserved.
    expect(tester.getTopLeft(find.byType(PromptNodeWidget)) - promptBefore, by);
    expect(tester.getTopLeft(find.byType(PreviewNode)) - previewBefore, by);
  });

  testWidgets('relative spacing is unchanged by the drag', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'Prompt');
    await _add(tester, 'Preview');
    await _click(tester, find.byType(PromptNodeWidget));
    await _click(tester, find.byType(PreviewNode), shift: true);

    final gapBefore = tester.getTopLeft(find.byType(PreviewNode)) -
        tester.getTopLeft(find.byType(PromptNodeWidget));

    await _dragTitleBar(
        tester, find.byType(PreviewNode), const Offset(-25, 30));

    final gapAfter = tester.getTopLeft(find.byType(PreviewNode)) -
        tester.getTopLeft(find.byType(PromptNodeWidget));
    expect(gapAfter, gapBefore);
  });

  testWidgets('dragging an unselected node moves only that node',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'Prompt');
    await _add(tester, 'Preview');

    // Select only the prompt; then drag the *other* one.
    await _click(tester, find.byType(PromptNodeWidget));

    final promptBefore = tester.getTopLeft(find.byType(PromptNodeWidget));
    await _dragTitleBar(
        tester, find.byType(PreviewNode), const Offset(40, 20));

    // The prompt stayed put — pointer-down retargeted the selection first.
    expect(tester.getTopLeft(find.byType(PromptNodeWidget)), promptBefore);
  });

  testWidgets('the canvas edge stops the whole selection together, unsheared',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'Prompt');
    await _add(tester, 'Preview');
    await _click(tester, find.byType(PromptNodeWidget));
    await _click(tester, find.byType(PreviewNode), shift: true);

    final gapBefore = tester.getTopLeft(find.byType(PreviewNode)) -
        tester.getTopLeft(find.byType(PromptNodeWidget));

    // Far past the left/top bound: one node hits x=0 well before the other.
    await _dragTitleBar(
        tester, find.byType(PreviewNode), const Offset(-4000, -4000));

    // Clamped as a unit: the spacing is identical, so nothing sheared.
    final gapAfter = tester.getTopLeft(find.byType(PreviewNode)) -
        tester.getTopLeft(find.byType(PromptNodeWidget));
    expect(gapAfter, gapBefore);
  });
}
