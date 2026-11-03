// Preview shows a table for an AA that is data about pictures, and a picture
// only for an AA that IS one picture. Regression for the 2026-10-27 shortcut
// (commit 8acedf0) that turned any AA with an `image_b64` column into the
// first image in it — the full page, for Seg Forge's llmPayload.

import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/aa_dataframe.dart';
import 'package:double_vision/widgets/focus_panel.dart' show FocusContent, FocusContentKind;
import 'package:double_vision/widgets/nodes/implementations/preview_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A real 1x1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Future<FocusContent> _previewOf(WidgetTester tester, AaPayload aa) async {
  final out = OutputPort('aaOut');
  InputPort? port;
  FocusContent? got;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PreviewNode(
        node: const WorkflowNode(id: 1, type: 'preview'),
        inputConnected: true,
        onInputPort: (p) => port = p,
        onContent: (_, c) => got = c,
        onContentCleared: (_) {},
      ),
    ),
  ));
  port!.connect(out);
  out.emit(aa);
  await tester.pumpAndSettle();
  return got!;
}

void main() {
  testWidgets('Seg Forge llmPayload shape (page, panel, segments) is a table',
      (tester) async {
    final c = await _previewOf(
      tester,
      const AaPayload(
        rows: ['page', 'page', 'panel:1', 'panel:1', 'seg:a', 'seg:a'],
        cols: ['kind', 'image_b64', 'kind', 'image_b64', 'kind', 'image_b64'],
        vals: ['page', _png, 'panel', _png, 'segment', _png],
      ),
    );
    expect(c.kind, FocusContentKind.aa);
    expect(c.imageBytes, isNull);
  });

  testWidgets('Documenter output with one captioned row is still a table',
      (tester) async {
    final c = await _previewOf(
      tester,
      const AaPayload(
        rows: ['seg:a', 'seg:a', 'seg:a'],
        cols: ['best_caption', 'good_caption', 'image_b64'],
        vals: ['a boy', 'boy', _png],
      ),
    );
    expect(c.kind, FocusContentKind.aa);
  });

  testWidgets('Generate output (one image row + path) is still a picture',
      (tester) async {
    final c = await _previewOf(
      tester,
      const AaPayload(
        rows: ['image', 'image'],
        cols: ['image_b64', 'path'],
        vals: [_png, '/tmp/out.png'],
      ),
    );
    expect(c.kind, FocusContentKind.image);
    expect(c.imageBytes, base64Decode(_png));
    expect(c.subtitle, '/tmp/out.png');
  });

  testWidgets('Load File image (bytes + file metadata, one row) is a picture',
      (tester) async {
    final c = await _previewOf(
      tester,
      const AaPayload(
        rows: ['0', '0', '0'],
        cols: ['bytes', 'file_path', 'format'],
        vals: [_png, '/x/a.png', 'PNG'],
      ),
    );
    expect(c.kind, FocusContentKind.image);
  });

  testWidgets('the table draws image_b64 cells as images, not base64 text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AaDataFrame(
          aa: AaPayload(
            rows: ['page', 'page', 'seg:a', 'seg:a'],
            cols: ['kind', 'image_b64', 'kind', 'image_b64'],
            vals: ['page', _png, 'segment', _png],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text(_png), findsNothing);
    expect(find.text('page'), findsWidgets); // row/col names still shown
  });

  testWidgets('a non-base64 value in an image column stays readable text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AaDataFrame(
          aa: AaPayload(
            rows: ['r1', 'r2'],
            cols: ['image_b64', 'image_b64'],
            vals: ['not base64 !!', 'also not'],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.text('not base64 !!'), findsOneWidget);
  });
}
