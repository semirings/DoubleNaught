import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:double_vision/config/node_registry.dart';
import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/save_file_api.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _aa = AaPayload(rows: ['a'], cols: ['x'], vals: ['1']);

/// The URL field, scoped by label since the Format `DropdownMenu` is a
/// `TextField` too.
Finder _urlField() => find.ancestor(
      of: find.text('URL'),
      matching: find.byType(TextField),
    );

String _urlText(WidgetTester tester) =>
    tester.widget<TextField>(_urlField()).controller!.text;

/// A backend that answers `/save` with a fixed response and records what it
/// was asked to write; `/save/cancel` records cleanup requests separately.
({SaveFileApi api, List<Map<String, dynamic>> saveRequests, List<Map<String, dynamic>> cleanupRequests})
    _api({
  int httpStatus = 200,
  String message = 'Saved',
}) {
  final saveRequests = <Map<String, dynamic>>[];
  final cleanupRequests = <Map<String, dynamic>>[];
  final api = SaveFileApi(
    client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/save/cancel') {
        cleanupRequests.add(body);
        return http.Response(
          jsonEncode({'removed': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      saveRequests.add(body);
      if (httpStatus != 200) {
        return http.Response('{"detail":"disk full"}', httpStatus);
      }
      return http.Response(
        jsonEncode({
          'filePath': '/tmp/out/export.parquet',
          'bytesWritten': 42,
          'message': message,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return (api: api, saveRequests: saveRequests, cleanupRequests: cleanupRequests);
}

Future<InputPort> _pump(
  WidgetTester tester, {
  SaveFileApi? api,
  Future<FileSaveLocation?> Function(String)? pickSaveLocation,
  Map<String, String>? initialParams,
  void Function(Map<String, String>)? onParams,
  bool inputConnected = false,
  Stream<String>? textInput,
  Stream<Uint8List>? imageInput,
}) async {
  InputPort? port;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SaveFileNode(
            node: const WorkflowNode(id: 1, type: 'save_file'),
            api: api ?? _api().api,
            pickSaveLocation: pickSaveLocation ?? (_) async => null,
            initialParams: initialParams,
            onParams: onParams,
            inputConnected: inputConnected,
            onInputPort: (p) => port = p,
            textInput: textInput,
            imageInput: imageInput,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return port!;
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

void main() {
  group('catalog registration', () {
    test('Save File is registered', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'save_file');
      expect(entry.name, 'Save File');
    });
  });

  group('readiness', () {
    testWidgets('starts with Execute disabled and an empty URL', (tester) async {
      await _pump(tester);

      expect(find.text('Save File'), findsOneWidget);
      expect(_urlText(tester), isEmpty);
      expect(find.text('Invalid URL'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('data connected but no URL leaves Execute disabled', (tester) async {
      final port = await _pump(tester, inputConnected: true);
      await _send(tester, port, _aa);

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('data connected + an invalid URL leaves Execute disabled and errors',
        (tester) async {
      final port = await _pump(tester, inputConnected: true);
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'storage/out/export');
      await tester.pump();

      expect(find.text('Invalid URL'), findsOneWidget);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('data connected + a valid URL enables Execute', (tester) async {
      final port = await _pump(tester, inputConnected: true);
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pump();

      expect(find.text('Invalid URL'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });
  });

  group('Wait/Execute mechanism', () {
    testWidgets('reactive (Wait unchecked, the default): fires once both '
        'data and a valid URL are present', (tester) async {
      final backend = _api();
      final port = await _pump(tester, api: backend.api, inputConnected: true);

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );

      await _send(tester, port, _aa);
      expect(backend.saveRequests, isEmpty, reason: 'no URL yet');

      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();

      expect(backend.saveRequests, hasLength(1));
      expect(find.textContaining('done'), findsOneWidget);
    });

    testWidgets('gated (Wait checked): ready does not auto-fire', (tester) async {
      final backend = _api();
      final port = await _pump(tester, api: backend.api, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();

      expect(backend.saveRequests, isEmpty, reason: 'gated — nothing fires until Execute');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('clicking Execute fires immediately and unchecks Wait', (tester) async {
      final backend = _api();
      final port = await _pump(tester, api: backend.api, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // gate it
      await tester.pumpAndSettle();
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      expect(backend.saveRequests, hasLength(1));
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );
    });

    testWidgets('manually unchecking Wait fires immediately when already ready',
        (tester) async {
      final backend = _api();
      final port = await _pump(tester, api: backend.api, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();
      expect(backend.saveRequests, isEmpty);

      await tester.tap(find.byType(WaitCheckbox)); // uncheck while ready
      await tester.pumpAndSettle();
      expect(backend.saveRequests, hasLength(1));
    });

    testWidgets('unchecking Wait while NOT ready just becomes reactive — '
        'fires later once ready, not immediately', (tester) async {
      final backend = _api();
      final port = await _pump(tester, api: backend.api, inputConnected: true);

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WaitCheckbox)); // uncheck — not ready yet
      await tester.pumpAndSettle();
      expect(backend.saveRequests, isEmpty);

      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();
      expect(backend.saveRequests, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final response = Completer<http.Response>();
      final api = SaveFileApi(client: MockClient((_) => response.future));
      final port = await _pump(tester, api: api, inputConnected: true);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await _send(tester, port, _aa); // auto-fires

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).locked,
        isTrue,
      );
      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
        reason: 'locked — the tap must not have toggled it',
      );

      response.complete(http.Response(
        jsonEncode({'filePath': '/x', 'bytesWritten': 1, 'message': 'ok'}),
        200,
        headers: {'content-type': 'application/json'},
      ));
      await tester.pumpAndSettle();
    });
  });

  group('saving', () {
    testWidgets('sends the URL and format, and reports the result', (tester) async {
      final backend = _api(message: 'Saved 42 bytes');
      final port = await _pump(tester, api: backend.api, inputConnected: true);
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();

      expect(backend.saveRequests.single['url'], 'file:///tmp/out/export');
      expect(backend.saveRequests.single['format'], 'parquet');
      expect(find.textContaining('done'), findsOneWidget);
      expect(find.textContaining('export.parquet'), findsOneWidget);
    });

    testWidgets('a backend failure is reported', (tester) async {
      final backend = _api(httpStatus: 500);
      final port = await _pump(tester, api: backend.api, inputConnected: true);
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('disk full'), findsOneWidget);
    });

    testWidgets('disconnecting clears the previous result and disables Execute',
        (tester) async {
      final port = await _pump(tester, inputConnected: true);
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();
      expect(find.textContaining('export.parquet'), findsOneWidget);

      port.disconnect();
      await tester.pumpAndSettle();

      expect(find.textContaining('export.parquet'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });
  });

  group('Cancel — hard abort with cleanup', () {
    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves, and calls the cleanup route',
        (tester) async {
      final response = Completer<http.Response>();
      final cleanupRequests = <Map<String, dynamic>>[];
      final api = SaveFileApi(
        client: MockClient((request) async {
          if (request.url.path == '/save/cancel') {
            cleanupRequests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'removed': true}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return response.future;
        }),
      );
      final port = await _pump(tester, api: api, inputConnected: true);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await _send(tester, port, _aa); // auto-fires

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isTrue,
      );
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      expect(find.textContaining('idle'), findsOneWidget);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isFalse,
      );

      response.complete(http.Response(
        jsonEncode({'filePath': '/x', 'bytesWritten': 1, 'message': 'ok'}),
        200,
        headers: {'content-type': 'application/json'},
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('idle'), findsOneWidget,
          reason: 'the cancelled run\'s late success must not overwrite idle');
      expect(cleanupRequests, hasLength(1),
          reason: 'a completed-but-abandoned write must be cleaned up');
      expect(cleanupRequests.single['url'], 'file:///tmp/out/export');
      expect(cleanupRequests.single['payloadKind'], 'aa');
    });

    testWidgets('cancelling never surfaces error status', (tester) async {
      final response = Completer<http.Response>();
      final api = SaveFileApi(
        client: MockClient((request) async {
          if (request.url.path == '/save/cancel') {
            return http.Response(
              jsonEncode({'removed': false}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return response.future;
        }),
      );
      final port = await _pump(tester, api: api, inputConnected: true);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await _send(tester, port, _aa);

      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      response.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
    });
  });

  group('Format', () {
    testWidgets('auto-detects Parquet for an AA, and JSONL for one carrying '
        'json_line', (tester) async {
      final port = await _pump(tester, inputConnected: true);
      await _send(tester, port, _aa);
      expect(find.text('Parquet'), findsOneWidget);

      await _send(
        tester,
        port,
        const AaPayload(rows: ['r'], cols: ['json_line'], vals: ['{}']),
      );
      expect(find.text('JSONL'), findsOneWidget);
    });

    testWidgets('picking a format persists it and re-fires reactively',
        (tester) async {
      Map<String, String>? saved;
      final backend = _api();
      final port = await _pump(
        tester,
        api: backend.api,
        inputConnected: true,
        onParams: (p) => saved = p,
      );
      await _send(tester, port, _aa);
      await tester.enterText(_urlField(), 'file:///tmp/out/export');
      await tester.pumpAndSettle();
      expect(backend.saveRequests, hasLength(1));

      await tester.tap(find.ancestor(
        of: find.text('Format'),
        matching: find.byType(TextField),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CSV').last);
      await tester.pumpAndSettle();

      expect(backend.saveRequests.last['format'], 'csv');
      expect(saved!['format'], 'csv');
    });
  });

  group('save-location dialog', () {
    testWidgets('a chosen location fills the URL field as a file:// URL',
        (tester) async {
      final suggested = <String>[];
      await _pump(
        tester,
        pickSaveLocation: (name) async {
          suggested.add(name);
          return const FileSaveLocation('/tmp/out/report.csv');
        },
      );

      await tester.tapAt(tester.getCenter(find.byTooltip('Choose location…')));
      await tester.pumpAndSettle();

      expect(suggested, ['export.parquet']);
      expect(_urlText(tester), 'file:///tmp/out/report.csv');
      expect(find.text('CSV'), findsOneWidget, reason: 'format follows the extension');
    });

    testWidgets('a cancelled dialog leaves the URL field untouched', (tester) async {
      await _pump(tester, pickSaveLocation: (_) async => null);

      await tester.tapAt(tester.getCenter(find.byTooltip('Choose location…')));
      await tester.pumpAndSettle();

      expect(_urlText(tester), isEmpty);
    });
  });

  group('legacy textIn / imageIn streams', () {
    testWidgets(
        'text arriving on the legacy textIn stream is savable, without a '
        'visible second port for it',
        (tester) async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      final backend = _api();
      await _pump(tester, api: backend.api, textInput: controller.stream);

      // Only `dataIn` is drawn — textIn/imageIn are wiring, not connectors.
      expect(find.text('textIn'), findsNothing);
      expect(find.text('imageIn'), findsNothing);

      controller.add('hello world');
      await tester.pumpAndSettle();
      expect(find.text('Text'), findsOneWidget, reason: 'auto-detected from the text payload');

      await tester.enterText(_urlField(), 'file:///tmp/out/note');
      await tester.pumpAndSettle();

      expect(backend.saveRequests, hasLength(1));
      expect(backend.saveRequests.single['text'], 'hello world');
    });

    testWidgets('image bytes arriving on the legacy imageIn stream are savable',
        (tester) async {
      final controller = StreamController<Uint8List>();
      addTearDown(controller.close);
      final backend = _api();
      await _pump(tester, api: backend.api, imageInput: controller.stream);

      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]);
      controller.add(png);
      await tester.pumpAndSettle();
      expect(find.text('PNG'), findsOneWidget, reason: 'auto-detected from the PNG signature');

      await tester.enterText(_urlField(), 'file:///tmp/out/pic');
      await tester.pumpAndSettle();

      expect(backend.saveRequests, hasLength(1));
      expect(backend.saveRequests.single['imageBase64'], isNotNull);
    });
  });

  testWidgets('the Node Catalog instantiates it onto the canvas', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();

    final item = find.text('Save File').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(SaveFileNode), findsOneWidget);
  });
}
