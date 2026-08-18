import 'dart:convert';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/polyglot_exec_api.dart';
import 'package:double_vision/widgets/nodes/implementations/polyglot_exec_node_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A backend that answers `/exec` with a fixed outcome.
PolyglotExecApi _api({
  String status = 'SUCCESS',
  String stdout = '',
  String stderr = '',
  int exitCode = 0,
  double ms = 12.5,
  String language = 'python',
  int httpStatus = 200,
  Map<String, dynamic>? mergedAa,
  void Function(Map<String, dynamic> body)? onRequest,
}) {
  return PolyglotExecApi(
    client: MockClient((request) async {
      onRequest?.call(jsonDecode(request.body) as Map<String, dynamic>);
      if (httpStatus != 200) {
        return http.Response('{"detail":"nope"}', httpStatus);
      }
      return http.Response(
        jsonEncode({
          'status': status,
          'language': language,
          'stdout': stdout,
          'stderr': stderr,
          'exitCode': exitCode,
          'executionTimeMs': ms,
          'code': 'x',
          'filePath': '',
          'executionResult': mergedAa ??
              {
            'rows': List.filled(8, 'exec:1'),
            'cols': const [
              'status',
              'language',
              'stdout',
              'stderr',
              'exit_code',
              'execution_time_ms',
              'code',
              'file_path',
            ],
            'vals': [status, language, stdout, stderr, exitCode, ms, 'x', ''],
              },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

/// Mount the node, returning its input port and a sink for whatever it emits.
Future<({InputPort input, List<AaPayload> emitted})> _pump(
  WidgetTester tester, {
  PolyglotExecApi? api,
  Map<String, String>? params,
}) async {
  InputPort? port;
  final emitted = <AaPayload>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PolyglotExecNodeWidget(
            node: const WorkflowNode(id: 1, type: 'polyglotExecNode'),
            initialParams: params,
            api: api ?? _api(),
            onInputPort: (p) => port = p,
            onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (input: port!, emitted: emitted);
}

/// Deliver a payload as the canvas would: wire an upstream port and emit.
Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

/// What `Load File` really emits for a source file: one row, one `text` column.
AaPayload _loadFileContents(String code, {String? path}) => AaPayload(
      rows: path == null ? const ['0'] : const ['0', '0'],
      cols: path == null ? const ['text'] : const ['text', 'filePath'],
      vals: path == null ? [code] : [code, path],
    );

/// Choose an entry from the Language dropdown.
///
/// Taps the field rather than the 'Language' label: the label lives inside the
/// input decoration, where a tap does not reliably land on the dropdown.
Future<void> _chooseLanguage(WidgetTester tester, String label) async {
  await tester.tap(find.ancestor(
    of: find.text('Language'),
    matching: find.byType(TextField),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  _passThroughTests();

  group('ExecSource.fromAa', () {
    test('reads a Load File contents payload', () {
      final s = ExecSource.fromAa(_loadFileContents('print(1)'));
      expect(s.code, 'print(1)');
      expect(s.hasCode, isTrue);
    });

    test('infers the language from the file name', () {
      final s = ExecSource.fromAa(
        _loadFileContents('println(1)', path: '/tmp/demo.jl'),
      );
      expect(s.language, 'julia');
      expect(s.fileName, 'demo.jl');
    });

    test('falls back to the shebang when there is no useful extension', () {
      final s = ExecSource.fromAa(
        _loadFileContents('#!/usr/bin/env julia\nprintln(1)', path: 'script'),
      );
      expect(s.language, 'julia');
    });

    test('an explicit language column wins over the extension', () {
      final s = ExecSource.fromAa(const AaPayload(
        rows: ['0', '0', '0'],
        cols: ['code', 'language', 'file_path'],
        vals: ['print(1)', 'python', 'thing.jl'],
      ));
      expect(s.language, 'python');
    });

    test('unknown everything leaves the language empty rather than guessing',
        () {
      final s = ExecSource.fromAa(_loadFileContents('x = 1', path: 'a.rtf'));
      expect(s.language, '');
      expect(s.hasCode, isTrue);
    });

    test('an empty payload is empty, not an error', () {
      const s = AaPayload();
      expect(ExecSource.fromAa(s).hasCode, isFalse);
    });
  });

  group('PolyglotExecNodeWidget', () {
    testWidgets('starts Idle, with Run disabled and no payload', (tester) async {
      await _pump(tester);

      expect(find.text('Polyglot Exec'), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('No payload'), findsOneWidget);
      expect(find.textContaining('Waiting for executionPayload'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('shows the incoming payload metadata and enables Run',
        (tester) async {
      final h = await _pump(tester);
      await _send(
        tester,
        h.input,
        _loadFileContents('println(1)\nprintln(2)', path: '/tmp/demo.jl'),
      );

      expect(find.textContaining('Lang: julia'), findsOneWidget);
      expect(find.textContaining('File: demo.jl'), findsOneWidget);
      expect(find.textContaining('2 lines'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('a payload of unknown language keeps Run disabled and says why',
        (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _loadFileContents('x = 1', path: 'a.rtf'));

      expect(find.textContaining('Pick a language'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('the language override unblocks an unrecognised payload',
        (tester) async {
      final h = await _pump(tester);
      await _send(tester, h.input, _loadFileContents('x = 1', path: 'a.rtf'));

      await _chooseLanguage(tester, 'Python');

      expect(find.textContaining('Lang: python'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('a successful run shows Success, the console output, and emits',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(stdout: 'hello from the snippet', ms: 42),
      );
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Success'), findsOneWidget);
      expect(find.text('hello from the snippet'), findsOneWidget);
      expect(find.text('SUCCESS'), findsOneWidget);
      expect(find.textContaining('exit 0'), findsOneWidget);

      // The result matrix went downstream.
      expect(h.emitted, hasLength(1));
      expect(h.emitted.single.value('status'), 'SUCCESS');
      expect(h.emitted.single.cols, contains('execution_time_ms'));
    });

    testWidgets('a failing snippet shows Error but still emits the result',
        (tester) async {
      final h = await _pump(
        tester,
        api: _api(
          status: 'FAILED',
          stderr: 'Traceback: boom',
          exitCode: 3,
        ),
      );
      await _send(tester, h.input, _loadFileContents('raise', path: 'a.py'));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Traceback: boom'), findsOneWidget);
      expect(find.textContaining('exit 3'), findsOneWidget);
      // A failure is data, not silence.
      expect(h.emitted, hasLength(1));
      expect(h.emitted.single.value('status'), 'FAILED');
    });

    testWidgets('a timeout is surfaced as its own status', (tester) async {
      final h = await _pump(
        tester,
        api: _api(
          status: 'TIMEOUT',
          stdout: 'partial',
          stderr: 'timed out after 30s — process killed',
          exitCode: -9,
        ),
      );
      await _send(tester, h.input, _loadFileContents('sleep 99', path: 'a.sh'));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('TIMEOUT'), findsOneWidget);
      // Partial output is kept — it is usually the useful part of a hung run.
      expect(find.text('partial'), findsOneWidget);
      expect(h.emitted.single.value('status'), 'TIMEOUT');
    });

    testWidgets('an unreachable backend reports the transport error, emits nothing',
        (tester) async {
      final h = await _pump(tester, api: _api(httpStatus: 500));
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
      // Shown twice by design: once beside the badge, once in the console.
      expect(find.textContaining('500'), findsWidgets);
      // No run happened, so there is no result to send downstream.
      expect(h.emitted, isEmpty);
    });

    testWidgets('the timeout box is sent to the backend', (tester) async {
      Map<String, dynamic>? sent;
      final h = await _pump(
        tester,
        api: _api(onRequest: (body) => sent = body),
      );
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));

      await tester.enterText(
        find.ancestor(
          of: find.text('Timeout (s)'),
          matching: find.byType(TextField),
        ),
        '5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(sent!['timeoutS'], 5);
    });

    testWidgets('a nonsense timeout falls back to the default rather than 0',
        (tester) async {
      Map<String, dynamic>? sent;
      final h = await _pump(
        tester,
        api: _api(onRequest: (body) => sent = body),
      );
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));

      await tester.enterText(
        find.ancestor(
          of: find.text('Timeout (s)'),
          matching: find.byType(TextField),
        ),
        'abc',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(sent!['timeoutS'], 30);
    });

    testWidgets('the override is sent as the wire name, auto as empty',
        (tester) async {
      Map<String, dynamic>? sent;
      final h = await _pump(
        tester,
        api: _api(onRequest: (body) => sent = body),
      );
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(sent!['language'], '', reason: 'Auto-detect defers to the backend');

      await _chooseLanguage(tester, 'JavaScript');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(sent!['language'], 'javascript');
    });

    testWidgets('the console collapses and reopens', (tester) async {
      final h = await _pump(tester, api: _api(stdout: 'visible output'));
      await _send(tester, h.input, _loadFileContents('print(1)', path: 'a.py'));
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('visible output'), findsOneWidget);

      await tester.tap(find.text('Console'));
      await tester.pumpAndSettle();
      expect(find.text('visible output'), findsNothing);

      await tester.tap(find.text('Console'));
      await tester.pumpAndSettle();
      expect(find.text('visible output'), findsOneWidget);
    });

    testWidgets('settings are restored from saved params', (tester) async {
      await _pump(
        tester,
        params: {
          'language': 'bash',
          'timeoutS': '7',
          'consoleOpen': 'false',
        },
      );

      expect(find.text('Bash'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.ancestor(
              of: find.text('Timeout (s)'),
              matching: find.byType(TextField),
            ))
            .controller!
            .text,
        '7',
      );
      // Collapsed, so the terminal area is not built.
      expect(find.text('no output yet'), findsNothing);
    });

    testWidgets('settings are persisted as they change', (tester) async {
      Map<String, String>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PolyglotExecNodeWidget(
                node: const WorkflowNode(id: 1, type: 'polyglotExecNode'),
                api: _api(),
                onParams: (p) => saved = p,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _chooseLanguage(tester, 'Julia');

      expect(saved!['language'], 'julia');
      expect(saved!['timeoutS'], '30.0');
    });
  });

  testWidgets('the Node Catalog instantiates it onto the canvas', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();

    final item = find.text('Polyglot Exec').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(PolyglotExecNodeWidget), findsOneWidget);
    // Wired: the card is live, waiting on its input port.
    expect(find.textContaining('Waiting for executionPayload'), findsOneWidget);
  });
}

/// Schema pass-through: the node must send the incoming AA so the backend can
/// merge into it. Without that, `executionResult` collapses to execution metadata and a
/// downstream Remote Service finds no `text`.
void _passThroughTests() {
  group('schema pass-through', () {
    testWidgets('the incoming AA is sent with the run', (tester) async {
      Map<String, dynamic>? sent;
      final h = await _pump(tester, api: _api(onRequest: (b) => sent = b));

      await _send(
        tester,
        h.input,
        // A file path so the language resolves; Run is disabled otherwise.
        const AaPayload(
          rows: ['r1', 'r1', 'r1'],
          cols: ['text', 'author', 'file_path'],
          vals: ["print('hi')", 'gcr', 'a.py'],
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      // Not just `code`: the whole payload, so the merge has something to keep.
      final aa = sent!['executionPayload'] as Map<String, dynamic>;
      expect(aa['cols'], containsAll(['text', 'author', 'file_path']));
      expect(aa['rows'], ['r1', 'r1', 'r1']);
      expect(sent!['code'], "print('hi')");
    });

    testWidgets('a merged result flows downstream with its original columns',
        (tester) async {
      // What the merging backend answers: input columns plus metadata, on the
      // input's own row key.
      final merged = JsonlLikeAa();
      final h = await _pump(tester, api: _api(mergedAa: merged.json));

      await _send(
        tester,
        h.input,
        const AaPayload(
          rows: ['r1', 'r1'],
          cols: ['text', 'file_path'],
          vals: ["print('hi')", 'a.py'],
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(h.emitted, hasLength(1));
      final out = h.emitted.single;
      // The downstream contract: `text` is still there, alongside the results.
      expect(out.cols, contains('text'));
      expect(out.cols, contains('status'));
      expect(out.value('text'), "print('hi')");
      expect(out.value('status'), 'SUCCESS');
      expect(out.distinctRows(), ['r1'], reason: 'the input row key is kept');
    });
  });
}

/// A merged output AA, as the backend now returns it.
class JsonlLikeAa {
  Map<String, dynamic> get json => {
        'rows': ['r1', 'r1', 'r1'],
        'cols': ['text', 'status', 'transformed_text'],
        'vals': ["print('hi')", 'SUCCESS', 'hi\n'],
      };
}
