import 'package:double_vision/models/node_group.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
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
Future<void> _clickNode(WidgetTester tester, Finder node,
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

/// Press ⌘G, optionally with Shift (ungroup) or Alt (regroup).
Future<void> _pressGroupKey(
  WidgetTester tester, {
  bool shift = false,
  bool alt = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

/// Two selected nodes on a fresh canvas.
Future<void> _twoSelectedNodes(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
  await _add(tester, 'Prompt');
  await _add(tester, 'Preview');
  await _clickNode(tester, find.byType(PromptNodeWidget));
  await _clickNode(tester, find.byType(PreviewNode), shift: true);
}

void main() {
  testWidgets('⌘G collapses the selection into a group card', (tester) async {
    await _twoSelectedNodes(tester);
    expect(find.byType(GroupNodeWidget), findsNothing);

    await _pressGroupKey(tester);

    expect(find.byType(GroupNodeWidget), findsOneWidget);
    // The members' own cards are gone — they live inside the container now.
    expect(find.byType(PromptNodeWidget), findsNothing);
    expect(find.byType(PreviewNode), findsNothing);
    // The card says what it holds and that it will not run while packed.
    expect(find.textContaining('2 nodes'), findsOneWidget);
    expect(find.textContaining('ungroup to run'), findsOneWidget);
  });

  testWidgets('⌘⇧G unpacks it and leaves the children selected',
      (tester) async {
    await _twoSelectedNodes(tester);
    await _pressGroupKey(tester);
    expect(find.byType(GroupNodeWidget), findsOneWidget);

    await _pressGroupKey(tester, shift: true);

    expect(find.byType(GroupNodeWidget), findsNothing);
    expect(find.byType(PromptNodeWidget), findsOneWidget);
    expect(find.byType(PreviewNode), findsOneWidget);
    // Both come back selected, so the next ⌘⌥G can act on them.
    expect(find.text('2 nodes selected'), findsOneWidget);
  });

  testWidgets('⌘⌥G rebuilds the group it was unpacked from', (tester) async {
    await _twoSelectedNodes(tester);
    await _pressGroupKey(tester);
    await _pressGroupKey(tester, shift: true);
    expect(find.byType(GroupNodeWidget), findsNothing);

    await _pressGroupKey(tester, alt: true);

    expect(find.byType(GroupNodeWidget), findsOneWidget);
    expect(find.textContaining('2 nodes'), findsOneWidget);
  });

  testWidgets('a group survives a full group → ungroup → regroup cycle',
      (tester) async {
    await _twoSelectedNodes(tester);

    for (var i = 0; i < 3; i++) {
      await _pressGroupKey(tester, shift: i > 0); // group, then ungroup…
      if (i > 0) {
        await _pressGroupKey(tester, alt: true); // …then regroup
      }
      expect(find.byType(GroupNodeWidget), findsOneWidget,
          reason: 'cycle $i left no group');
      expect(find.textContaining('2 nodes'), findsOneWidget);
    }
  });

  testWidgets('⌘G on a single node does nothing', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await _add(tester, 'Preview');
    await _clickNode(tester, find.byType(PreviewNode));

    await _pressGroupKey(tester);

    // A group of one is just a node.
    expect(find.byType(GroupNodeWidget), findsNothing);
    expect(find.byType(PreviewNode), findsOneWidget);
  });

  testWidgets('the node menu offers Ungroup on a group and Group on a multi-selection',
      (tester) async {
    await _twoSelectedNodes(tester);

    // Multi-selection: Group is offered, Ungroup is not.
    await tester.tapAt(
      tester.getCenter(find.byType(PromptNodeWidget)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Group  ⌘G'), findsOneWidget);
    expect(find.text('Ungroup  ⌘⇧G'), findsNothing);

    await tester.tap(find.text('Group  ⌘G'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupNodeWidget), findsOneWidget);

    // On the container: Ungroup is offered instead.
    await tester.tapAt(
      tester.getCenter(find.byType(GroupNodeWidget)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Ungroup  ⌘⇧G'), findsOneWidget);
    expect(find.text('Group  ⌘G'), findsNothing);

    await tester.tap(find.text('Ungroup  ⌘⇧G'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupNodeWidget), findsNothing);
  });

  testWidgets('Regroup is disabled until something has been unpacked',
      (tester) async {
    await _twoSelectedNodes(tester);

    await tester.tapAt(
      tester.getCenter(find.byType(PromptNodeWidget)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Regroup  ⌘⌥G'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(item.enabled, isFalse);
  });

  testWidgets('the group node type is not offered in the Node Catalog',
      (tester) async {
    // A group is made by grouping, never placed empty from the catalogue.
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();
    expect(find.text(NodeGroup.type), findsNothing);
    expect(find.text('Group'), findsNothing);
  });
}
