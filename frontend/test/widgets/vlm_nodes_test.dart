import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/vlm_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> _tick(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('trainer: Execute starts a run, polls it, shows the adapter',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = VlmApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'runId': 'r1', 'adapter': '/lora/a.safetensors'}), 200);
        }
        return http.Response(
            jsonEncode({
              'status': 'done', 'step': 9, 'total': 9,
              'adapter': '/lora/a.safetensors', 'error': null, 'lines': [],
            }),
            200);
      }),
    );
    InputPort? dataset;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VlmTrainerNodeWidget(
            node: const WorkflowNode(id: 1, type: 'vlmTrainerNode'),
            api: api,
            poll: const Duration(milliseconds: 20),
            inputConnected: true,
            onInputPort: (p) => dataset = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    // Nothing runs until Execute.
    dataset!.connect(OutputPort('up')
      ..emit(AaPayload(rows: const ['collected'], cols: const ['path'], vals: const ['/s/_collected/train'])));
    await t.pumpAndSettle();
    expect(posts, isEmpty);

    await t.tap(find.text('Execute'));
    await _tick(t);
    expect(posts.single['dataset'], '/s/_collected/train');
    expect(posts.single['model'], VlmApi.defaultModel);
    expect(posts.single['epochs'], 3);
    expect(find.byKey(const ValueKey('vlm-adapter')), findsOneWidget);
    expect(find.text('/lora/a.safetensors'), findsOneWidget);
  });

  testWidgets('trainer: a failed run shows the reason', (t) async {
    final api = VlmApi(
      client: MockClient((r) async => r.method == 'POST'
          ? http.Response(jsonEncode({'runId': 'r1', 'adapter': '/x'}), 200)
          : http.Response(
              jsonEncode({
                'status': 'failed', 'step': 0, 'total': 0, 'adapter': '/x',
                'error': 'trainer exited with code 3: out of memory', 'lines': [],
              }),
              200)),
    );
    InputPort? dataset;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VlmTrainerNodeWidget(
            node: const WorkflowNode(id: 1, type: 'vlmTrainerNode'),
            api: api,
            poll: const Duration(milliseconds: 20),
            inputConnected: true,
            onInputPort: (p) => dataset = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    dataset!.connect(OutputPort('up')
      ..emit(AaPayload(rows: const ['collected'], cols: const ['path'], vals: const ['/d'])));
    await t.pumpAndSettle();
    await t.tap(find.text('Execute'));
    await _tick(t);
    expect(find.textContaining('out of memory'), findsOneWidget);
  });

  testWidgets('caption: base model without a lora, adapter once one arrives',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = VlmApi(
      client: MockClient((r) async {
        posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'text': 'A dream bed.'}), 200);
      }),
    );
    InputPort? image;
    InputPort? lora;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VlmCaptionNodeWidget(
            node: const WorkflowNode(id: 2, type: 'vlmCaptionNode'),
            api: api,
            inputConnected: true,
            onInputPort: (p) => image = p,
            onLoraInputPort: (p) => lora = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    image!.connect(OutputPort('up')
      ..emit(AaPayload(
        rows: const ['seg:1', 'seg:1', 'seg:2', 'page'],
        cols: const ['image_b64', 'file_name', 'image_b64', 'caption'],
        vals: const ['QUJD', 'images/a.png', 'REVG', 'ignored: no image'],
      )));
    await t.pumpAndSettle();

    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts.length, 2, reason: 'only rows with an image are captioned');
    expect(posts.first['adapter'], '');
    expect(posts.first['prompt'], VlmApi.defaultPrompt);
    expect(find.textContaining('base model'), findsWidgets);

    posts.clear();
    lora!.connect(OutputPort('tr')
      ..emit(AaPayload(rows: const ['adapter'], cols: const ['path'], vals: const ['/lora/a.safetensors'])));
    await t.pumpAndSettle();
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts.first['adapter'], '/lora/a.safetensors');
  });
}
