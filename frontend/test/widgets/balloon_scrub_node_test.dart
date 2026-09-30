import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/seg_forge_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A one-row image AA, the shape `Load File` emits for an image file.
AaPayload _imageAa() => AaPayload(
      rows: const ['0', '0', '0'],
      cols: const ['bytes_b64', 'format', 'file_path'],
      vals: [base64Encode(Uint8List.fromList([1, 2, 3])), 'png', '/tmp/page.png'],
    );

String _responseBody({
  required bool scrubbed,
  List<Map<String, dynamic>> detections = const [],
}) =>
    jsonEncode({
      'session_id': 'sess-abc',
      'image_b64': base64Encode(Uint8List.fromList([9, 9, 9])),
      'width': 100,
      'height': 200,
      'confidence_threshold': 0.25,
      'scrubbed': scrubbed,
      'detections': detections,
      'scrubbed_mask_ids': [
        for (final d in detections)
          if (d['mask_id'] != null) d['mask_id'],
      ],
    });

Future<void> _pumpNode(
  WidgetTester tester, {
  required http.Client client,
  void Function(AaPayload)? onEmit,
  AaPayload? incoming,
}) async {
  final upstream = OutputPort('upstream');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: BalloonScrubNode(
        node: const WorkflowNode(id: 1, type: 'balloon_scrub'),
        api: SegForgeApi(client: client),
        onInputPort: (port) => port.connect(upstream),
        onOutputPort: (port) =>
            port.connect(onEmit ?? (_) {}, emitCurrentState: false),
      ),
    ),
  ));
  if (incoming != null) {
    upstream.emit(incoming);
    await tester.pump();
  }
}

void main() {
  testWidgets('an unreachable SegForge backend is reported visibly',
      (tester) async {
    final client = MockClient(
      (_) async => throw const SocketException('Connection refused'),
    );

    await _pumpNode(tester, client: client, incoming: _imageAa());

    await tester.tapAt(tester.getCenter(find.text('Scrub balloons')));
    await tester.pumpAndSettle();

    // Named on the card, not folded into a generic failure — SF being simply
    // down is a confirmed recurring condition in this project.
    expect(find.text('SegForge backend unreachable'), findsOneWidget);
    // Both the panel and the status row name it — the point is that it is
    // visible, not that it appears exactly once.
    expect(find.textContaining('127.0.0.1:8401'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero detections reports an unchanged image, not an error',
      (tester) async {
    final client = MockClient((_) async => http.Response(
          _responseBody(scrubbed: false),
          200,
          headers: {'content-type': 'application/json'},
        ));

    await _pumpNode(tester, client: client, incoming: _imageAa());

    await tester.tapAt(tester.getCenter(find.text('Scrub balloons')));
    await tester.pumpAndSettle();

    expect(find.textContaining('No detections'), findsOneWidget);
    expect(find.textContaining('error'), findsNothing);
  });

  testWidgets('a successful scrub emits the image and the audit rows',
      (tester) async {
    final emitted = <AaPayload>[];
    final client = MockClient((_) async => http.Response(
          _responseBody(scrubbed: true, detections: [
            {
              'box': [10, 10, 30, 30],
              'confidence': 0.91,
              'cls': 'text_bubble',
              'mask_id': 'm1',
            },
            {
              'box': [50, 50, 70, 70],
              'confidence': 0.62,
              'cls': 'text_free',
              'mask_id': 'm2',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        ));

    await _pumpNode(
      tester,
      client: client,
      incoming: _imageAa(),
      onEmit: emitted.add,
    );

    await tester.tapAt(tester.getCenter(find.text('Scrub balloons')));
    await tester.pumpAndSettle();

    expect(emitted, hasLength(1));
    final aa = emitted.single;

    expect(aa.value('bytes_b64'), isNotNull, reason: 'the scrubbed image');
    expect(aa.value('session_id'), 'sess-abc');
    expect(aa.value('detection_count'), '2');

    expect(aa.distinctRows(), containsAll(<String>['0', 'det_0', 'det_1']));
    expect(find.textContaining('Scrubbed 2 of 2'), findsOneWidget);
    expect(find.textContaining('(unsaved)'), findsOneWidget);
  });

  test('a detection with no mask still appears in the emitted audit', () {
    final aa = BalloonScrubNode.resultToAa(BalloonScrubResult(
      sessionId: 'sess-abc',
      imageBytes: Uint8List.fromList([1]),
      width: 10,
      height: 10,
      confidenceThreshold: 0.25,
      scrubbed: false,
      detections: const [
        {
          'box': [1, 2, 3, 4],
          'confidence': 0.5,
          'cls': 'text_bubble',
          'mask_id': null,
          'note': 'detector box produced no SAM3 mask',
        },
      ],
    ));

    // The audit is the only record of what happened, so a detection that
    // produced nothing must not silently vanish from it.
    expect(aa.distinctRows(), contains('det_0'));
    final cells = {
      for (var i = 0; i < aa.cols.length; i++)
        '${aa.rows[i]}|${aa.cols[i]}': aa.vals[i],
    };
    expect(cells['det_0|confidence'], 0.5);
    expect(cells['det_0|note'], 'detector box produced no SAM3 mask');
    expect(cells.containsKey('det_0|mask_id'), isFalse,
        reason: 'a null mask_id is absent, never an empty-string cell');
  });
}
