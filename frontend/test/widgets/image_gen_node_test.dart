import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/generate_api.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 1x1 transparent PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  testWidgets('Generate: prompt + lora go out, the image comes back',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = GenerateApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'runId': 'g1', 'path': '/g/a.png'}), 200);
        }
        if (r.url.path.endsWith('/image')) return http.Response.bytes(_png, 200);
        return http.Response(
            jsonEncode({
              'status': 'done', 'step': 4, 'total': 4, 'path': '/g/a.png',
              'seconds': 12.0, 'error': null, 'lines': [],
            }),
            200);
      }),
    );
    InputPort? model;
    InputPort? lora;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            api: api,
            poll: const Duration(milliseconds: 20),
            onModelInputPort: (p) => model = p,
            onLoraInputPort: (p) => lora = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    // No prompt, nothing to run.
    expect(find.text('Execute'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts, isEmpty);

    model!.connect(OutputPort('m')
      ..emit(AaPayload(rows: const ['model:q'], cols: const ['pathOrUrl'], vals: const ['Qwen/Qwen-Image-2.1'])));
    lora!.connect(OutputPort('l')
      ..emit(AaPayload(rows: const ['lora'], cols: const ['path'], vals: const ['/lora/a.safetensors'])));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('gen-prompt')), 'a bed');
    await t.enterText(find.byKey(const ValueKey('gen-steps')), '4');
    await t.enterText(find.byKey(const ValueKey('gen-size')), '512');
    await t.pumpAndSettle();

    await t.tap(find.text('Execute'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 30));
    }
    final body = posts.single;
    expect(body['prompt'], 'a bed');
    expect(body['steps'], 4);
    expect(body['width'], 512);
    expect(body['lora'], '/lora/a.safetensors');
    expect(body['loraScale'], 1.0);
    expect(find.byKey(const ValueKey('gen-image')), findsOneWidget);
  });

  testWidgets('Generate: a size that is not a multiple of 16 blocks Execute',
      (t) async {
    final posts = <String>[];
    final api = GenerateApi(
      client: MockClient((r) async {
        posts.add(r.url.path);
        return http.Response('{}', 200);
      }),
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            api: api,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('gen-prompt')), 'x');
    await t.enterText(find.byKey(const ValueKey('gen-size')), '500');
    await t.pumpAndSettle();
    expect(find.text('×16'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts, isEmpty);
  });

  testWidgets('Generate: a wired prompt replaces the field and is what is sent',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = GenerateApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'runId': 'g2', 'path': '/g/b.png'}), 200);
        }
        if (r.url.path.endsWith('/image')) return http.Response.bytes(_png, 200);
        return http.Response(
            jsonEncode({
              'status': 'done', 'step': 4, 'total': 4, 'path': '/g/b.png',
              'seconds': 1.0, 'error': null, 'lines': [],
            }),
            200);
      }),
    );
    InputPort? prompt;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            api: api,
            poll: const Duration(milliseconds: 20),
            onPromptInputPort: (p) => prompt = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    prompt!.connect(OutputPort('file')
      ..emit(AaPayload(
        rows: const ['0', '0'],
        cols: const ['text', 'file_path'],
        vals: const ['a boy asleep, Winsor McCay style\n', '/p/prompt.txt'],
      )));
    await t.pumpAndSettle();

    expect(find.text('from the prompt port'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts.single['prompt'], 'a boy asleep, Winsor McCay style');
  });

  testWidgets('Generate: Load File picture (bytes column) is the start image',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = GenerateApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'runId': 'g3', 'path': '/g/c.png'}), 200);
        }
        if (r.url.path.endsWith('/image')) return http.Response.bytes(_png, 200);
        return http.Response(
            jsonEncode({
              'status': 'done', 'step': 4, 'total': 4, 'path': '/g/c.png',
              'seconds': 1.0, 'error': null, 'lines': [],
            }),
            200);
      }),
    );
    InputPort? image;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            initialParams: const {'prompt': 'a boy', 'imageStrength': '0.4'},
            api: api,
            poll: const Duration(milliseconds: 20),
            onImageInputPort: (p) => image = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    image!.connect(OutputPort('file')
      ..emit(AaPayload(
        rows: const ['0', '0'],
        cols: const ['bytes', 'format'],
        vals: [base64Encode(_png), 'png'],
      )));
    await t.pumpAndSettle();

    expect(find.text('no LoRA · start image'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts.single['imageB64'], base64Encode(_png));
    expect(posts.single['imageStrength'], 0.4);
  });

  testWidgets('Generate: an image row with no picture is reported, not ignored',
      (t) async {
    InputPort? image;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            initialParams: const {'prompt': 'a boy'},
            onImageInputPort: (p) => image = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    image!.connect(OutputPort('x')
      ..emit(AaPayload(rows: const ['0'], cols: const ['text'], vals: const ['hi'])));
    await t.pumpAndSettle();
    expect(find.textContaining('has no picture'), findsOneWidget);
  });

  testWidgets('Generate: Edit mode sends mode and the edit strength; needs a picture',
      (t) async {
    final posts = <Map<String, dynamic>>[];
    final api = GenerateApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'runId': 'g4', 'path': '/g/d.png'}), 200);
        }
        if (r.url.path.endsWith('/image')) return http.Response.bytes(_png, 200);
        return http.Response(
            jsonEncode({
              'status': 'done', 'step': 4, 'total': 4, 'path': '/g/d.png',
              'seconds': 1.0, 'error': null, 'lines': [],
            }),
            200);
      }),
    );
    InputPort? image;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            initialParams: const {
              'prompt': 'red shirt',
              'mode': 'edit',
              'editStrength': '0.5',
              'size': '512',
            },
            api: api,
            poll: const Duration(milliseconds: 20),
            onImageInputPort: (p) => image = p,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    // Edit with no picture: said out loud, and Execute does nothing.
    expect(find.text('Edit needs a start image on the image input.'), findsOneWidget);
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts, isEmpty);
    expect(find.byKey(const ValueKey('gen-edit-strength')), findsOneWidget);

    image!.connect(OutputPort('file')
      ..emit(AaPayload(
        rows: const ['0'], cols: const ['bytes'], vals: [base64Encode(_png)])));
    await t.pumpAndSettle();
    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    expect(posts.single['mode'], 'edit');
    expect(posts.single['editStrength'], 0.5);
    expect(posts.single['imageB64'], base64Encode(_png));
  });

  testWidgets('Generate: Edit wants a size that is a multiple of 32', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGenNodeWidget(
            node: const WorkflowNode(id: 3, type: 'imageGenNode'),
            initialParams: const {'prompt': 'x', 'mode': 'edit', 'size': '496'},
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('×32'), findsOneWidget);
  });
}

