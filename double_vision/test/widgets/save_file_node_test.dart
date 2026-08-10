import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/widgets/nodes/implementations/save_file_node.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The current text of the node's destination field. Read from the controller
/// rather than via find.text(), and scoped by label since the Format
/// DropdownMenu is a TextField too.
String _pathField(WidgetTester tester) => tester
    .widget<TextField>(find.ancestor(
      of: find.text('File Path (storage/out/ or absolute)'),
      matching: find.byType(TextField),
    ))
    .controller!
    .text;

/// The Format dropdown's current selection label.
String _formatField(WidgetTester tester) => tester
    .widget<TextField>(find.ancestor(
      of: find.text('Format'),
      matching: find.byType(TextField),
    ))
    .controller!
    .text;

/// Pump a Save File node whose save dialog resolves to [path] (null = cancel),
/// recording the suggested name the node asked the dialog for.
Future<List<String>> _pump(WidgetTester tester, String? path) async {
  final suggested = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SaveFileNode(
        node: const WorkflowNode(id: 1, type: 'save_file'),
        pickSaveLocation: (name) async {
          suggested.add(name);
          return path == null ? null : FileSaveLocation(path);
        },
      ),
    ),
  ));
  return suggested;
}

Future<void> _tapIcon(WidgetTester tester) async {
  // tapAt(getCenter(...)) rather than tap(finder): Flutter 3.44's tap()
  // resolves a view via _maybeViewOf, which fails inside the node card.
  await tester.tapAt(tester.getCenter(find.byTooltip('Choose location…')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the icon replaces the old full-width Browse... button',
      (tester) async {
    await _pump(tester, null);

    expect(find.text('Browse...'), findsNothing);
    expect(find.byTooltip('Choose location…'), findsOneWidget);
  });

  testWidgets('a chosen location fills the field and suggests a name',
      (tester) async {
    final suggested = await _pump(tester, '/tmp/out/report.parquet');
    expect(_pathField(tester), 'storage/out/export');

    await _tapIcon(tester);

    // Suggested name comes from the current field + selected format.
    expect(suggested, ['export.parquet']);
    // Extension stripped — the backend appends it for the chosen format.
    expect(_pathField(tester), '/tmp/out/report');
    expect(find.text('Saving to /tmp/out/report.parquet'), findsOneWidget);
  });

  testWidgets('the picked extension selects the format', (tester) async {
    await _pump(tester, '/tmp/out/report.csv');
    await _tapIcon(tester);

    expect(_pathField(tester), '/tmp/out/report');
    expect(find.text('Saving to /tmp/out/report.csv'), findsOneWidget);
    // The Format dropdown followed the extension.
    expect(_formatField(tester), 'CSV');
  });

  testWidgets('an unrecognised extension is left on the path', (tester) async {
    await _pump(tester, '/tmp/out/report.dat');
    await _tapIcon(tester);

    // No known format matches .dat, so the path is kept verbatim and the
    // format stays as it was.
    expect(_pathField(tester), '/tmp/out/report.dat');
    expect(find.text('Saving to /tmp/out/report.dat.parquet'), findsOneWidget);
  });

  testWidgets('a cancelled dialog leaves the field untouched', (tester) async {
    await _pump(tester, null);
    await _tapIcon(tester);

    expect(_pathField(tester), 'storage/out/export');
    expect(find.text('Ready to save'), findsOneWidget);
  });
}
