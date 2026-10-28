import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:double_vision/models/workflow.dart';
import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/antelora_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';

void main() {
  late List<http.Request> calls;

  Widget host(Map<String, String>? params, {void Function(InputPort)? onInput}) {
    calls = [];
    final client = MockClient((req) async {
      calls.add(req);
      if (req.url.path == '/antelora/pages') {
        return http.Response(
            jsonEncode({
              'antelora': 'mccay',
              'pages': [
                {'page': 'Page_006', 'images': 3, 'path': 'x'},
                {'page': 'Page_007', 'images': 2, 'path': 'y'},
              ]
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'antelora': 'mccay',
            'output': 'train',
            'path': 'storage/antelora/mccay/_collected/train',
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
          child: CollectAnteloraNodeWidget(
            node: const WorkflowNode(id: 1, type: 'collectAnteloraNode'),
            initialParams: params,
            inputConnected: onInput != null,
            onInputPort: onInput,
            api: AnteloraApi(client: client),
          ),
        ),
      ),
    );
  }

  testWidgets('lists pages, holds one out, collects without it', (t) async {
    await t.pumpWidget(host({'antelora': 'mccay', 'exclude': 'Page_007'}));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('collect-page-Page_006')), findsOneWidget);
    expect(find.text('2 images · held out'), findsOneWidget);

    await t.tap(find.text('Execute'));
    await t.pumpAndSettle();
    final post = calls.last;
    expect(post.url.path, '/antelora/collect');
    final body = jsonDecode(post.body) as Map;
    expect(body['exclude'], ['Page_007']);
    expect(body['output'], 'train');
    expect(find.byKey(const ValueKey('collect-result')), findsOneWidget);
  });

  testWidgets('starts empty: no antelora is assumed until a dir arrives',
      (t) async {
    await t.pumpWidget(host(null));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/antelora/pages'), isEmpty);
    expect(find.text('Enter the antelora name'), findsWidgets);
  });

  testWidgets('does not collect by itself', (t) async {
    await t.pumpWidget(host({'antelora': 'mccay'}));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/antelora/collect'), isEmpty);
  });

  testWidgets('a dir row names the antelora and the pages are re-listed',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();

    dir!.connect(OutputPort('save')
      ..emit(AaPayload(
        rows: const ['antelora', 'antelora'],
        cols: const ['antelora', 'path'],
        vals: const ['nemo', '/s/antelora/nemo'],
      )));
    await t.pumpAndSettle();

    final listed = calls.where((c) => c.url.path == '/antelora/pages').last;
    expect(listed.url.queryParameters['antelora'], 'nemo');
    expect(find.text('from the dir port'), findsOneWidget);
  });

  testWidgets('with only a path, the last folder name is the antelora',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();
    dir!.connect(OutputPort('x')
      ..emit(AaPayload(rows: const ['d'], cols: const ['path'], vals: const ['/a/storage/antelora/mccay/'])));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.url.path == '/antelora/pages').last.url.queryParameters['antelora'], 'mccay');
  });

  testWidgets('Load File on a folder names the antelora by its source_dir',
      (t) async {
    InputPort? dir;
    await t.pumpWidget(host(null, onInput: (p) => dir = p));
    await t.pumpAndSettle();
    dir!.connect(OutputPort('load')
      ..emit(AaPayload(
        rows: const ['file:00000', 'file:00000', 'file:00001', 'file:00001'],
        cols: const ['file_path', 'source_dir', 'file_path', 'source_dir'],
        vals: const [
          'Page_002/metadata.jsonl', '/Users/g/storage/antelora/mccay',
          'Page_003/metadata.jsonl', '/Users/g/storage/antelora/mccay',
        ],
      )));
    await t.pumpAndSettle();
    expect(
        calls.where((c) => c.url.path == '/antelora/pages').last.url.queryParameters['antelora'],
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
          vals: const ['/s/antelora/nemo/Page_002'])));
    await t.pumpAndSettle();
    expect(
        calls.where((c) => c.url.path == '/antelora/pages').last.url.queryParameters['antelora'],
        'nemo');
  });
}
