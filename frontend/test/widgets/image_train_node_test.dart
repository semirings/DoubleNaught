import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/image_train_api.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _status(String s, {int step = 0, int cps = 0, String? error}) => {
      'status': s, 'step': step, 'total': 40, 'adapter': '/lora/mccay/r/r.safetensors',
      'iteration': cps * 10, 'checkpoints': cps, 'error': error, 'lines': [],
    };

void main() {
  testWidgets('Image LoRA Trainer: needs a dataset, sends the settings, emits the adapter',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = ImageTrainApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode({
                'runId': 'r1', 'adapter': '/lora/mccay/r/r.safetensors',
                'images': 27, 'total': 40, 'runDir': '/lora/mccay/r',
              }),
              200);
        }
        return http.Response(jsonEncode(_status('done', step: 40, cps: 2)), 200);
      }),
    );
    InputPort? dataset;
    OutputPort? out;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageTrainNodeWidget(
            node: const WorkflowNode(id: 5, type: 'imageTrainNode'),
            api: api,
            poll: const Duration(milliseconds: 20),
            onInputPort: (p) => dataset = p,
            onOutputPort: (p) => out = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    // No dataset wired: Execute does nothing.
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts, isEmpty);

    final emitted = <AaPayload>[];
    final sink = InputPort('probe');
    sink.onDataArrived.listen(emitted.add);
    sink.connect(out!);

    dataset!.connect(OutputPort('collect')
      ..emit(AaPayload(
        rows: const ['collection', 'collection', 'collection'],
        cols: const ['path', 'images', 'pages'],
        vals: const ['/s/loraset/mccay/_collected/train', '27', '6'],
      )));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('imgtrain-epochs')), '10');
    await t.enterText(find.byKey(const ValueKey('imgtrain-trigger')), 'mccaystyle');
    await t.pumpAndSettle();

    await t.tap(find.text('Execute'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 30));
    }
    final body = posts.single;
    expect(body['dataset'], '/s/loraset/mccay/_collected/train');
    expect(body['epochs'], 10);
    expect(body['rank'], 16);
    expect(body['resolution'], 768);
    expect(body['trigger'], 'mccaystyle');

    expect(find.byKey(const ValueKey('imgtrain-adapter')), findsOneWidget);
    final row = emitted.last;
    String col(String c) => row.vals[row.cols.indexOf(c)] as String;
    expect(col('path'), '/lora/mccay/r/r.safetensors');
    expect(col('family'), 'z-image');
  });

  testWidgets('Image LoRA Trainer: a resolution that is not a multiple of 16 blocks Execute',
      (t) async {
    final posts = <String>[];
    final api = ImageTrainApi(
      client: MockClient((r) async {
        posts.add(r.url.path);
        return http.Response('{}', 200);
      }),
    );
    InputPort? dataset;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageTrainNodeWidget(
            node: const WorkflowNode(id: 5, type: 'imageTrainNode'),
            api: api,
            onInputPort: (p) => dataset = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    dataset!.connect(OutputPort('c')
      ..emit(AaPayload(rows: const ['c'], cols: const ['path'], vals: const ['/d'])));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('imgtrain-resolution')), '770');
    await t.pumpAndSettle();
    expect(find.text('×16'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts, isEmpty);
  });

  testWidgets('Image LoRA Trainer: a failure is shown, not swallowed', (t) async {
    final api = ImageTrainApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          return http.Response(jsonEncode({'detail': 'mflux-train was not found.'}), 422);
        }
        return http.Response('{}', 200);
      }),
    );
    InputPort? dataset;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageTrainNodeWidget(
            node: const WorkflowNode(id: 5, type: 'imageTrainNode'),
            api: api,
            onInputPort: (p) => dataset = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    dataset!.connect(OutputPort('c')
      ..emit(AaPayload(rows: const ['c'], cols: const ['path'], vals: const ['/d'])));
    await t.pumpAndSettle();
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(find.textContaining('mflux-train was not found'), findsOneWidget);
  });
}
