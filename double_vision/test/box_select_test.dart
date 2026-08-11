import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Add a node from the Node Catalog dropdown.
Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.text('Node Catalog'));
  await tester.pumpAndSettle();
  final item = find.text(name).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// Click a node's card. tapAt(getCenter(...)) rather than tap(finder): Flutter
/// 3.44's tap() resolves a view via _maybeViewOf, which fails inside the canvas
/// Transform.
Future<void> _click(WidgetTester tester, Finder node) async {
  await tester.tapAt(tester.getCenter(node));
  await tester.pump();
}

/// Drag on the canvas from [from] to [to], optionally holding Shift.
Future<void> _boxSelect(
  WidgetTester tester,
  Offset from,
  Offset to, {
  bool shift = false,
}) async {
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }
  final gesture = await tester.startGesture(from);
  // Several moves, not one: the pan recogniser needs to clear its slop before
  // onPanStart fires at all.
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveTo(to);
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }
}

/// Two nodes on a fresh canvas: a Prompt on the left, a Preview to its right.
Future<void> _twoNodes(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
  await _add(tester, 'Prompt Node');
  await _add(tester, 'Preview');
}

Rect _promptRect(WidgetTester tester) =>
    tester.getRect(find.byType(PromptNodeWidget));
Rect _previewRect(WidgetTester tester) =>
    tester.getRect(find.byType(PreviewNode));

/// Empty canvas below both cards — the marquee's start corner.
///
/// Positions are read live rather than hard-coded: selecting anything inserts
/// the selection bar into the page column, which shifts the canvas down.
Offset _emptyBelow(WidgetTester tester, {double inset = 10}) {
  final union = _promptRect(tester).expandToInclude(_previewRect(tester));
  return Offset(union.left + inset, union.bottom + 40);
}

void main() {
  testWidgets('a drag across empty canvas selects every node it touches',
      (tester) async {
    await _twoNodes(tester);
    final union = _promptRect(tester).expandToInclude(_previewRect(tester));

    await _boxSelect(
      tester,
      _emptyBelow(tester),
      Offset(union.right - 10, union.top + 40),
    );

    expect(find.text('2 nodes selected'), findsOneWidget);
  });

  testWidgets('a drag that reaches only one node selects only that one',
      (tester) async {
    await _twoNodes(tester);
    final prompt = _promptRect(tester);

    // Stops well short of the Preview's left edge.
    await _boxSelect(
      tester,
      _emptyBelow(tester),
      Offset(prompt.left + 60, prompt.top + 40),
    );

    expect(find.text('1 node selected'), findsOneWidget);
  });

  testWidgets('touching a node is enough — it need not be enclosed',
      (tester) async {
    await _twoNodes(tester);
    final prompt = _promptRect(tester);

    // A small box clipping the Prompt's bottom-left corner only.
    await _boxSelect(
      tester,
      Offset(prompt.left - 4, prompt.bottom + 30),
      Offset(prompt.left + 30, prompt.bottom - 6),
    );

    expect(find.text('1 node selected'), findsOneWidget);
  });

  testWidgets('a drag over bare canvas clears the selection', (tester) async {
    await _twoNodes(tester);
    await _click(tester, find.byType(PromptNodeWidget));
    expect(find.text('1 node selected'), findsOneWidget);

    final start = _emptyBelow(tester, inset: 40);
    await _boxSelect(tester, start, start + const Offset(120, 60));

    expect(find.text('1 node selected'), findsNothing);
    expect(find.text('2 nodes selected'), findsNothing);
  });

  testWidgets('shift-drag adds to the selection instead of replacing it',
      (tester) async {
    await _twoNodes(tester);
    await _click(tester, find.byType(PreviewNode));
    expect(find.text('1 node selected'), findsOneWidget);

    // A box over the Prompt alone: without Shift this would replace, leaving 1.
    final prompt = _promptRect(tester);
    await _boxSelect(
      tester,
      _emptyBelow(tester),
      Offset(prompt.left + 60, prompt.top + 40),
      shift: true,
    );

    expect(find.text('2 nodes selected'), findsOneWidget);
  });

  testWidgets('a drag beginning on a node does not box-select', (tester) async {
    await _twoNodes(tester);

    // Prompt centre → Preview centre. A marquee here would catch both; a press
    // on a card belongs to that card, so only the pressed node ends up selected.
    await _boxSelect(
      tester,
      tester.getCenter(find.byType(PromptNodeWidget)),
      tester.getCenter(find.byType(PreviewNode)),
    );

    expect(find.text('2 nodes selected'), findsNothing);
    expect(find.text('1 node selected'), findsOneWidget);
  });

  testWidgets('the rectangle is drawn during the drag and gone after release',
      (tester) async {
    await _twoNodes(tester);
    expect(find.byKey(marqueeKey), findsNothing);

    final from = _emptyBelow(tester);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(from + const Offset(-80, -120));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byKey(marqueeKey), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(marqueeKey), findsNothing);
  });

  testWidgets('a box-selection can then be grouped with ⌘G', (tester) async {
    await _twoNodes(tester);
    final union = _promptRect(tester).expandToInclude(_previewRect(tester));

    await _boxSelect(
      tester,
      _emptyBelow(tester),
      Offset(union.right - 10, union.top + 40),
    );
    expect(find.text('2 nodes selected'), findsOneWidget);

    // The marquee leaves focus on the canvas, so the shortcut lands.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byType(GroupNodeWidget), findsOneWidget);
  });
}
