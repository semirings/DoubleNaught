import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Add a node of the given menu name via the Node Catalog dropdown. Same
/// helper as workflow_page_test.dart.
Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.text('Node Catalog'));
  await tester.pumpAndSettle();
  final item = find.text(name).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Finder get _newButton => find.widgetWithText(OutlinedButton, 'New');

/// The toolbar row is already tight at flutter_test's default 800px
/// surface -- adding the New button overflows it by 5px there (confirmed
/// live). A real desktop window has far more width than that; this widens
/// only the TEST viewport, not any button's own layout/sizing/spacing.
Future<void> _pumpWide(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
}

void main() {
  testWidgets('New Workflow on an empty canvas resets immediately, no dialog',
      (tester) async {
    await _pumpWide(tester);

    // Canvas already starts empty.
    expect(find.byType(LoadFileNode), findsNothing);

    await tester.tap(_newButton);
    await tester.pumpAndSettle();

    // No confirm dialog appeared -- the reset just happened.
    expect(find.text('New Workflow'), findsNothing);
    expect(find.text('Use the Node Catalog menu to add a node.'),
        findsOneWidget);
  });

  testWidgets(
      'New Workflow on a non-empty canvas shows a confirm dialog; Cancel keeps the canvas',
      (tester) async {
    await _pumpWide(tester);
    await _add(tester, 'File Source');
    expect(find.byType(LoadFileNode), findsOneWidget);

    await tester.tap(_newButton);
    await tester.pumpAndSettle();

    expect(find.text('New Workflow'), findsOneWidget);
    expect(find.text('Discard unsaved changes and start a new workflow?'),
        findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Dialog gone, node untouched.
    expect(find.text('New Workflow'), findsNothing);
    expect(find.byType(LoadFileNode), findsOneWidget);
  });

  testWidgets('New Workflow: Discard clears the canvas', (tester) async {
    await _pumpWide(tester);
    await _add(tester, 'File Source');
    expect(find.byType(LoadFileNode), findsOneWidget);

    await tester.tap(_newButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(find.byType(LoadFileNode), findsNothing);
    expect(find.text('Use the Node Catalog menu to add a node.'),
        findsOneWidget);
  });
}
