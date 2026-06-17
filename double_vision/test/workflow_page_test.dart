import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/file_source_node.dart';
import 'package:double_vision/widgets/input_connector.dart';
import 'package:double_vision/widgets/preview_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Add a node of the given menu name via the Workflow dropdown.
Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.text('Workflow'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Workflow dropdown instantiates nodes onto the canvas',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));

    expect(find.text('Use the Workflow menu to add a node.'), findsOneWidget);

    await _add(tester, 'File Source');
    expect(find.byType(FileSourceNode), findsOneWidget);
    expect(find.text('Use the Workflow menu to add a node.'), findsNothing);

    await _add(tester, 'File Source');
    expect(find.byType(FileSourceNode), findsNWidgets(2));
  });

  testWidgets('dragging an output onto an input creates an edge',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));

    await _add(tester, 'File Source');
    await _add(tester, 'Preview');

    // Preview starts unwired.
    expect(find.text('Not connected.'), findsOneWidget);

    // Separate the two nodes so their connectors don't overlap.
    await tester.drag(
        find.byIcon(Icons.drag_indicator).at(1), const Offset(360, 140));
    await tester.pumpAndSettle();

    // Drag from the output connector (Draggable<PortRef>) to the input.
    final from = tester.getCenter(find.byType(Draggable<PortRef>));
    final to = tester.getCenter(find.byType(InputConnector));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // The input is now wired: "Not connected." is replaced by a waiting state.
    expect(find.byType(PreviewNode), findsOneWidget);
    expect(find.text('Not connected.'), findsNothing);
  });
}
