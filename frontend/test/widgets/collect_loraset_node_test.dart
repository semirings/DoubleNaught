import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:double_vision/models/workflow.dart';
import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/loraset_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';

void main() {
  late List<http.Request> calls;

  Widget host(Map<String, String>? params, {void Function(InputPort)? onInput}) {
    calls = [];
    final client = MockClient((req) async {
      calls.add(req);
      if (req.url.path == '/loraset/pages') {
        return http.Response(
            jsonEncode({
              'loraset': 'mccay',
              'pages': [
                {'page': 'Page_006', 'images': 3, 'path': 'x'},
                {'page': 'Page_007', 'images': 2, 'path': 'y'},
              ]
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'loraset': 'mccay',
            'output': 'train',
            'path': 'storage/loraset/mccay/_collected/train',
            'pages': ['Page_006'],
            'excluded': ['Page_007'],
            'images': 3,
            'skipped': 0,
            'problems': [],
          }),
          200);
    });
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CollectLorasetNodeWidget(
            node: const WorkflowNode(id: 1, type: 'collectLorasetNode'),
            initialParams: params,
            inputConnected: onInput != null,
            onInputPort: onInput,
            api: LorasetApi(client: client),
          ),
        ),
      ),
    );
  }

  testWidgets('lists pages, holds one out, collects without it', (t) async {
    await t.pumpWidget(host({'loraset': 'mccay', 'exclude': 'Page_007'}));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('collect-page-Page_006')), findsOneWidget);
    expect(find.text('2 images · held out'), findsOneWidget);

    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    final post = calls.last;
    expect(post.url.path, '/loraset/collect');
    final body = jsonDecode(post.body) as Map;
    expect(body['exclude'], ['Page_007']);
    expect(body['output'], 'train');
    expect(find.byKey(const ValueKey('collect-result')), findsOneWidget);
  });

  testWidgets('starts empty: no loraset is assumed until a dir arrives',
      (t) async {
    await t.pumpWidget(host(null));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/loraset/pages'), isEmpty);
    expect(find.text('Enter the loraset name'), findsWidgets);
  });

  testWidgets('does not collect by itself', (t) async {
    await t.pumpWidget(host({'loraset': 'mccay'}));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/loraset/collect'), isEmpty);
  });

  testWidgets('a dir row names the loraset and the pages are re-listed',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();

    dir!.connect(OutputPort('save')
      ..emit(AaPayload(
        rows: const ['loraset', 'loraset'],
        cols: const ['loraset', 'path'],
        vals: const ['nemo', '/s/loraset/nemo'],
      )));
    await t.pumpAndSettle();

    final listed = calls.where((c) => c.url.path == '/loraset/pages').last;
    expect(listed.url.queryParameters['loraset'], 'nemo');
    expect(find.text('from the dir port'), findsOneWidget);
  });

  testWidgets('with only a path, the last folder name is the loraset',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();
    dir!.connect(OutputPort('x')
      ..emit(AaPayload(rows: const ['d'], cols: const ['path'], vals: const ['/a/storage/loraset/mccay/'])));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/loraset/pages').last.url.queryParameters['loraset'], 'mccay');
  });

  testWidgets('Load File on a folder names the loraset by its source_dir',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();
    dir!.connect(OutputPort('load')
      ..emit(AaPayload(
        rows: const ['file:00000', 'file:00000', 'file:00001', 'file:00001'],
        cols: const ['file_path', 'source_dir', 'file_path', 'source_dir'],
        vals: const [
          'Page_002/metadata.jsonl', '/Users/g/storage/loraset/mccay',
          'Page_003/metadata.jsonl', '/Users/g/storage/loraset/mccay',
        ],
      )));
    await t.pumpAndSettle();
    expect(
        calls.where((c) => c.url.path == '/loraset/pages').last.url.queryParameters['loraset'],
        'mccay');
  });

  testWidgets('a page folder inside a set still names the set', (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();
    dir!.connect(OutputPort('load')
      ..emit(AaPayload(
          rows: const ['a'],
          cols: const ['source_dir'],
          vals: const ['/s/loraset/nemo/Page_002'])));
    await t.pumpAndSettle();
    expect(
        calls.where((c) => c.url.path == '/loraset/pages').last.url.queryParameters['loraset'],
        'nemo');
  });
}
