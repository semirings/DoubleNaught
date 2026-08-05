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

/// Tap a node widget by its Finder, with optional Shift held down.
///
/// Uses tapAt(getCenter(...)) rather than tap(finder) because Flutter 3.44's
/// tap() calls _maybeViewOf which fails for widgets inside the canvas Transform.
Future<void> _tapNode(WidgetTester tester, Finder node,
    {bool shift = false}) async {
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

/// True when the selection bar shows "[n] node(s) selected".
Finder _selectionText(int n) =>
    find.text('$n node${n == 1 ? '' : 's'} selected');

void main() {
  testWidgets('plain click selects exactly one node', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    final first = find.byType(LoadFileNode).first;
    await _tapNode(tester, first);

    // Selection bar must appear with count = 1.
    expect(_selectionText(1), findsOneWidget);
  });

  testWidgets('Shift-click adds a second node to the selection', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    final first = find.byType(LoadFileNode).first;
    final second = find.byType(PreviewNode).first;

    await _tapNode(tester, first);
    await _tapNode(tester, second, shift: true);

    expect(_selectionText(2), findsOneWidget);
  });

  testWidgets('Shift-click on an already-selected node deselects it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    final first = find.byType(LoadFileNode).first;
    final second = find.byType(PreviewNode).first;

    // Select both.
    await _tapNode(tester, first);
    await _tapNode(tester, second, shift: true);
    expect(_selectionText(2), findsOneWidget);

    // Shift-click first again — toggles it back out.
    await _tapNode(tester, first, shift: true);
    expect(_selectionText(1), findsOneWidget);
  });

  testWidgets('canvas tap clears the selection', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');

    final node = find.byType(LoadFileNode).first;
    await _tapNode(tester, node);
    expect(_selectionText(1), findsOneWidget);

    // Tap empty canvas area (bottom-right corner, away from nodes).
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();

    expect(_selectionText(1), findsNothing);
    expect(_selectionText(2), findsNothing);
  });

  testWidgets('Delete key removes all selected nodes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    final first = find.byType(LoadFileNode).first;
    final second = find.byType(PreviewNode).first;

    await _tapNode(tester, first);
    await _tapNode(tester, second, shift: true);
    expect(_selectionText(2), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(find.byType(LoadFileNode), findsNothing);
    expect(find.byType(PreviewNode), findsNothing);
  });

  testWidgets('selection-bar Delete button removes selected nodes',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'File Source');

    // Capture centers BEFORE tapping: bringToFront() reorders the widget tree
    // so .first/.last on the same type would swap after the first tap.
    final c1 = tester.getCenter(find.byType(LoadFileNode).first);
    final c2 = tester.getCenter(find.byType(LoadFileNode).last);

    await tester.tapAt(c1);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.tapAt(c2);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(_selectionText(2), findsOneWidget);

    // The selection bar has a "Delete" button.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.byType(LoadFileNode), findsNothing);
  });

  testWidgets('plain click replaces a multi-selection with one node',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    // Pre-capture centers: the third node (column 2, canvas x=752) would have
    // its center at screen x=872, outside the 800px test surface.
    // Using only 2 nodes keeps everything visible.
    final c1 = tester.getCenter(find.byType(LoadFileNode).first);
    final c2 = tester.getCenter(find.byType(PreviewNode).first);

    // Build up a 2-node selection.
    await tester.tapAt(c1);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.tapAt(c2);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(_selectionText(2), findsOneWidget);

    // Plain click on node 1 replaces the 2-node set with just {node1}.
    await tester.tapAt(c1);
    await tester.pump();
    expect(_selectionText(1), findsOneWidget);
  });
}
