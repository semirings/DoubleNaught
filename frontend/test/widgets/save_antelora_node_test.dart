import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/antelora_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AaPayload _captions() => AaPayload(
      rows: ['seg:1', 'seg:1', 'seg:1', 'seg:1'],
      cols: ['file_name', 'improved_caption', 'page_name', 'image_b64'],
      vals: ['images/s_1.png', 'better', 'nemo_1', 'AAAA'],
    );

Future<({InputPort input, OutputPort Function() output, List<Map<String, dynamic>> requests})> _pump(
  WidgetTester tester, {
  int status = 200,
  Map<String, String>? initialParams,
}) async {
  InputPort? port;
  OutputPort? outPort;
  final requests = <Map<String, dynamic>>[];
  final api = AnteloraApi(
    client: MockClient((r) async {
      requests.add(jsonDecode(r.body) as Map<String, dynamic>);
      if (status != 200) return http.Response('{"detail":"nope"}', status);
      return http.Response(
        jsonEncode({
          'antelora': 'mccay',
          'pages': [
            {'page': 'nemo_1', 'images': 1, 'path': '/s/antelora/mccay/nemo_1'}
          ],
          'images': 1,
          'skipped': 0,
          'path': '/s/antelora/mccay',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SaveAnteloraNodeWidget(
          node: const WorkflowNode(id: 1, type: 'saveAnteloraNode'),
          api: api,
          initialParams: initialParams,
          inputConnected: true,
          onInputPort: (p) => port = p,
          onOutputPort: (p) => outPort = p,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (input: port!, output: () => outPort!, requests: requests);
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a caption payload is saved under the antelora name, reactively',
      (tester) async {
    final h = await _pump(tester);
    await _send(tester, h.input, _captions());

    expect(h.requests.single['antelora'], 'mccay');
    expect(h.requests.single['captions'], isNotNull);
    expect(find.textContaining('1 images'), findsOneWidget);
    expect(find.byKey(const ValueKey('antelora-result')), findsOneWidget);
  });

  testWidgets('the saved antelora name is restored and sent', (tester) async {
    final h = await _pump(tester, initialParams: {'antelora': 'nemo'});
    await _send(tester, h.input, _captions());
    expect(h.requests.single['antelora'], 'nemo');
  });

  testWidgets('a backend failure is reported, not swallowed', (tester) async {
    final h = await _pump(tester, status: 422);
    await _send(tester, h.input, _captions());
    expect(find.textContaining('422'), findsOneWidget);
  });

  testWidgets('a path in the name is refused and nothing is sent',
      (tester) async {
    final h = await _pump(
      tester,
      initialParams: {'antelora': 'mccay/page_000/metadata.jsonl'},
    );
    await _send(tester, h.input, _captions());

    expect(h.requests, isEmpty);
    expect(find.textContaining('Just a name'), findsOneWidget);
  });

  testWidgets('a saved antelora is announced on the dir port', (tester) async {
    final h = await _pump(tester);
    final probe = InputPort('probe');
    final got = <AaPayload>[];
    probe.onDataArrived.listen(got.add);
    await _send(tester, h.input, _captions());
    probe.connect(h.output());
    await tester.pumpAndSettle();

    expect(got, isNotEmpty);
    final aa = got.last;
    expect(aa.cols, containsAll(['antelora', 'path']));
    expect(aa.vals, containsAll(['mccay', '/s/antelora/mccay']));
  });
}
