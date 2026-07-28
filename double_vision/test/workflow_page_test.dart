import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Add a node of the given menu name via the Node Catalog dropdown.
Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.text('Node Catalog'));
  await tester.pumpAndSettle();
  // `.last` targets the menu item in the popup overlay, not an on-canvas node
  // whose title bar may show the same text. The catalog is taller than the
  // test surface, so scroll the target into view before tapping it.
  final item = find.text(name).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Node Catalog dropdown instantiates nodes onto the canvas',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));

    expect(
        find.text('Use the Node Catalog menu to add a node.'), findsOneWidget);

    await _add(tester, 'File Source');
    expect(find.byType(FileSourceNode), findsOneWidget);
    expect(
        find.text('Use the Node Catalog menu to add a node.'), findsNothing);

    await _add(tester, 'File Source');
    expect(find.byType(FileSourceNode), findsNWidgets(2));
  });

  testWidgets('dragging an output onto an input creates an edge',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));

    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    // Preview starts unwired.
    expect(find.text('Connect a source (bytes or AA)'), findsOneWidget);

    // Nodes are already 360 px apart horizontally (grid layout), so only move
    // Preview down to make sure its input port doesn't overlap the title bar.
    await tester.drag(
        find.byIcon(Icons.drag_indicator).at(1), const Offset(0, 100));
    await tester.pumpAndSettle();

    // Drag from File Source's first output (`contents`, idx 0 — the byte
    // stream) to Preview's first input (`bytes`, idx 0).
    final from = tester.getCenter(find.byType(Draggable<PortRef>).first);
    final to = tester.getCenter(find.byType(InputConnector).first);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // The input is now wired: the unconnected hint is gone.
    expect(find.byType(PreviewNode), findsOneWidget);
    expect(find.text('Connect a source (bytes or AA)'), findsNothing);
  });
}
