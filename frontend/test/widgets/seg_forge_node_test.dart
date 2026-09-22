import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:double_vision/config/node_registry.dart';
import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/image_crop.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/seg_forge_api.dart';
import 'package:double_vision/services/seg_forge_mapping.dart';
import 'package:double_vision/widgets/nodes/node_widths.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ── Fixtures ─────────────────────────────────────────────────────────────────

const _sessionId = 'sess_01';

/// A session with one segment produced by one text prompt.
Map<String, dynamic> _sessionBody({
  List<Object> prompts = const ['hair'],
  List<List<double>> boxes = const [
    [10, 20, 40, 60],
  ],
  List<double> scores = const [0.75],
  String? createdAt = '2026-01-01T00:00:00.000000',
}) => {
      'session_id': _sessionId,
      'width': 100,
      'height': 100,
      'created_at': createdAt,
      'prompts': prompts,
      'results': {
        'original_width': 100,
        'original_height': 100,
        'masks': [
          for (var i = 0; i < boxes.length; i++)
            {'counts': [0, 4], 'size': [100, 100]},
        ],
        'boxes': boxes,
        'scores': scores,
      },
    };

/// An empty session — the app was closed before any inference ran.
Map<String, dynamic> _emptySessionBody() => {
      'session_id': _sessionId,
      'width': 100,
      'height': 100,
      'created_at': null,
      'prompts': <Object>[],
      'results': {'original_width': 100, 'original_height': 100},
    };

/// Opaque stand-in for image bytes.
///
/// The widget tests stub the cropper, so nothing here is ever decoded — which
/// is the point: rasterizing through `dart:ui` inside `testWidgets` never
/// completes. The real [cropPng] is exercised in its own group below, outside
/// the widget-test zone.
final Uint8List _bytes = Uint8List.fromList(List.generate(64, (i) => i));

/// Records the rects a run asked to crop, and returns a recognisable payload.
class _FakeCropper {
  final List<ui.Rect> rects = [];
  Uint8List? result = Uint8List.fromList(const [9, 9, 9]);

  Future<Uint8List?> call(Uint8List bytes, ui.Rect rect) async {
    rects.add(rect);
    return result;
  }
}

Future<Uint8List> _realPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366AA),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A stand-in SegForge backend. Records every path it was asked for.
({SegForgeApi api, List<String> calls}) _api({
  Map<String, dynamic>? session,
  Uint8List? imageBytes,
  int segmentCount = 1,
  bool maskAvailable = true,
  // False models "nothing saved yet" — a test exercising the "+ New Session"
  // creation flow wants an empty picklist, since a canned pre-existing entry
  // would otherwise auto-select as an *already-saved* session (skipping
  // upload/initSession, per _onOpenForge's isNewSession branch).
  bool hasSavedSessions = true,
}) {
  final calls = <String>[];
  final api = SegForgeApi(
    baseUrl: 'http://sf.test',
    client: MockClient((request) async {
      final path = request.url.path;
      calls.add('${request.method} $path');

      if (path == '/newSession') {
        return http.Response(jsonEncode({'session_id': _sessionId}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/upload') {
        return http.Response(
          jsonEncode({'session_id': _sessionId, 'width': 100, 'height': 100}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/loadSession/')) {
        return http.Response(
          jsonEncode(session ?? _sessionBody()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/saveSession') {
        return http.Response(
            jsonEncode({'message': 'Session saved', 'session_id': _sessionId}),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/saveMasks') {
        return http.Response(jsonEncode({'mask_count': segmentCount}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/createSegments') {
        return http.Response(jsonEncode({'count': segmentCount}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.startsWith('/showSegments/')) {
        return http.Response(
          jsonEncode([
            for (var i = 0; i < segmentCount; i++)
              '/storage/sessions/$_sessionId/segments_raw/cat/'
                  'segment_${i.toString().padLeft(3, '0')}.png',
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.contains('/masks/')) {
        if (!maskAvailable) return http.Response('not found', 404);
        return http.Response.bytes(imageBytes ?? Uint8List(0), 200);
      }
      if (path.startsWith('/storage/')) {
        return http.Response.bytes(imageBytes ?? Uint8List(0), 200);
      }
      // SF backend health + session init (called by _ensureBackendHealthy / initSession).
      if (path == '/health') {
        // model_loaded matters: the node waits for it before uploading,
        // because /upload answers 503 until SAM has finished loading.
        return http.Response(
            jsonEncode({'status': 'ok', 'model_loaded': true}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/initSession') {
        return http.Response(jsonEncode({'session_id': _sessionId}), 200,
            headers: {'content-type': 'application/json'});
      }
      // DN backend session picklist (called by _loadSessions).
      if (request.method == 'GET' && path == '/segforge/sessions') {
        return http.Response(
          jsonEncode({
            'sessions': hasSavedSessions
                ? [
                    {
                      'session_id': _sessionId,
                      'name': 'Test session',
                      'description': '',
                      'created_at': '2026-09-07T00:00:00Z',
                      'image_url': '',
                    }
                  ]
                : <Map<String, String>>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"detail":"unexpected $path"}', 500);
    }),
  );
  return (api: api, calls: calls);
}

/// A launcher that never spawns anything; the test decides when it "exits".
class _FakeProcess implements SegForgeProcess {
  final Completer<int> _completer = Completer<int>();

  /// Shared with the backend fake's call log, so a test can assert that the
  /// save happened *before* the window was taken away.
  final List<String>? log;
  bool killed = false;

  _FakeProcess({this.log});

  @override
  Future<int> get exitCode => _completer.future;

  @override
  void kill() {
    killed = true;
    log?.add('KILL');
    if (!_completer.isCompleted) _completer.complete(-1);
  }

  void finish([int code = 0]) {
    if (!_completer.isCompleted) _completer.complete(code);
  }
}

({SegForgeLauncher launcher, List<Map<String, String>> envs, List<String> exes, List<_FakeProcess> procs})
    _launcher({bool autoExit = true, List<String>? log}) {
  final envs = <Map<String, String>>[];
  final exes = <String>[];
  final procs = <_FakeProcess>[];
  Future<SegForgeProcess> launch({
    required String executable,
    required Map<String, String> environment,
  }) async {
    exes.add(executable);
    envs.add(environment);
    final p = _FakeProcess(log: log);
    procs.add(p);
    if (autoExit) p.finish(0);
    return p;
  }
  return (launcher: launch, envs: envs, exes: exes, procs: procs);
}

/// A launch that never returns, so the node stays busy with no window to close.
Future<SegForgeProcess> _neverLaunches({
  required String executable,
  required Map<String, String> environment,
}) => Completer<SegForgeProcess>().future;

Future<({InputPort image, List<AaPayload> segments, List<AaPayload> linkage})>
    _pump(
  WidgetTester tester, {
  required SegForgeApi api,
  required SegForgeLauncher launcher,
  _FakeCropper? cropper,
  String appPath = '/tmp/SegForge',
  String Function()? idGenerator,
}) async {
  InputPort? imagePort;
  final segments = <AaPayload>[];
  final linkage = <AaPayload>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SegForgeNodeWidget(
            node: const WorkflowNode(id: 1, type: 'segForgeNode'),
            api: api,
            launcher: launcher,
            appPathOverride: appPath.isEmpty ? null : appPath,
            cropper: (cropper ?? _FakeCropper()).call,
            idGenerator: idGenerator,
            onInputPort: (p) => imagePort = p,
            onIndexedOutputPort: (idx, port) => port.connect(
              idx == 0 ? segments.add : linkage.add,
              emitCurrentState: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    image: imagePort!,
    segments: segments,
    linkage: linkage,
  );
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

/// Drives the "+ New Session" dialog end to end, leaving the freshly created
/// (locally-staged, `_isNew: true`) session selected — the case Open Forge's
/// isNewSession branch needs to see for "upload then initSession" to fire.
Future<void> _createSession(
  WidgetTester tester, {
  String name = 'Test session',
  String description = '',
}) async {
  await tester.tap(find.byTooltip('Create new session'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, name);
  await tester.enterText(find.byType(TextField).last, description);
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pumpAndSettle();
}

AaPayload _imageAa(Uint8List bytes, {String filename = 'cat.png'}) => AaPayload(
      rows: const ['img', 'img'],
      cols: const ['bytes', 'filename'],
      vals: [base64Encode(bytes), filename],
    );

/// What an upstream such as Inventory emits: a fetchable location, no blob.
AaPayload _urlAa(String url) =>
    AaPayload(rows: const ['img'], cols: const ['url'], vals: [url]);

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('catalog registration', () {
    test('Seg Forge is registered under AI & Teacher Models', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'segForgeNode');
      expect(entry.name, 'Seg Forge');
      expect(entry.category, NodeCategory.ai);
    });

    test('it is findable by the words someone would type', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'segForgeNode');
      for (final q in ['seg forge', 'segforge', 'mask', 'bbox', 'crop']) {
        expect(entry.matches(q), isTrue, reason: 'should match "$q"');
      }
    });

    test('its width is registered so edges anchor on the port dots', () {
      expect(getNodeWidth('segForgeNode'), 320);
    });
  });

  group('SegForgeMapping', () {
    test('image_id is the filename stem, matching SegForge own segment dir', () {
      expect(SegForgeMapping.imageIdFor('/a/b/cat.png'), 'cat');
      expect(SegForgeMapping.imageIdFor('cat.tar.gz'), 'cat.tar');
      expect(SegForgeMapping.imageIdFor(null), 'image');
      expect(SegForgeMapping.imageIdFor(''), 'image');
    });

    test('bbox converts SegForge xyxy into the spec xywh', () {
      expect(SegForgeMapping.bboxToJson([10, 20, 40, 60]), '[10.0,20.0,30.0,40.0]');
    });

    test('content hash is stable and content-sensitive', () {
      expect(SegForgeMapping.contentHash('hair'),
          SegForgeMapping.contentHash('hair'));
      expect(SegForgeMapping.contentHash('hair'),
          isNot(SegForgeMapping.contentHash('fur')));
      expect(SegForgeMapping.contentHash('hair').length, 8);
    });

    test('segment rows key on session:image:segment and carry all 3 columns', () {
      final session = SegForgeSession.fromJson(_sessionId, _sessionBody());
      final aa = SegForgeMapping.segments(
        session,
        imageId: 'cat',
        crops: [Uint8List.fromList([1, 2, 3])],
        masks: [Uint8List.fromList([4, 5])],
      );

      expect(aa.rows.toSet(), {'sess_01:cat:seg_000'});
      expect(aa.cols, ['crop_bytes', 'mask_bytes', 'bbox']);
      expect(aa.vals[0], base64Encode([1, 2, 3]));
      expect(aa.vals[1], base64Encode([4, 5]));
      expect(aa.vals[2], '[10.0,20.0,30.0,40.0]');
    });

    test('a missing artifact omits its cell rather than emitting an empty one', () {
      final session = SegForgeSession.fromJson(_sessionId, _sessionBody());
      final aa = SegForgeMapping.segments(
        session,
        imageId: 'cat',
        crops: const [null],
        masks: const [null],
      );
      expect(aa.cols, ['bbox'], reason: 'AA invariant: no fully-empty columns');
    });

    test('linkage scopes prompts to the image and confidence to the segment', () {
      final session = SegForgeSession.fromJson(_sessionId, _sessionBody());
      final aa = SegForgeMapping.linkage(session, imageId: 'cat');
      final byRow = <String, Map<String, Object>>{};
      for (var i = 0; i < aa.cols.length; i++) {
        (byRow[aa.rows[i]] ??= {})[aa.cols[i]] = aa.vals[i];
      }

      expect(byRow['sess_01:cat']!['created_at'], '2026-01-01T00:00:00.000000');
      expect(
        byRow['sess_01:cat']!['prompt_${SegForgeMapping.contentHash('hair')}'],
        'hair',
      );
      expect(byRow['sess_01:cat:seg_000']!['confidence'], '0.75');
    });

    test('box and point prompts keep their geometry and label', () {
      final session = SegForgeSession.fromJson(
        _sessionId,
        _sessionBody(prompts: [
          {'type': 'box', 'box': [0.1, 0.2, 0.3, 0.4], 'label': 'negative'},
        ]),
      );
      final aa = SegForgeMapping.linkage(session, imageId: 'cat');
      final encoded = aa.vals.firstWhere((v) => v.toString().contains('"box"'));
      expect(encoded.toString(), contains('negative'));
      expect(encoded.toString(), contains('0.1'));
    });

    test('a prompt entered twice does not become a duplicate (row, col)', () {
      final session = SegForgeSession.fromJson(
        _sessionId,
        _sessionBody(prompts: const ['hair', 'hair']),
      );
      final aa = SegForgeMapping.linkage(session, imageId: 'cat');
      final pairs = [
        for (var i = 0; i < aa.cols.length; i++) '${aa.rows[i]}|${aa.cols[i]}',
      ];
      expect(pairs.length, pairs.toSet().length,
          reason: 'AA invariant: unique keys');
    });

    test('a session with no inference reports itself empty', () {
      expect(
        SegForgeSession.fromJson(_sessionId, _emptySessionBody()).isEmpty,
        isTrue,
      );
      expect(
        SegForgeSession.fromJson(_sessionId, _sessionBody()).isEmpty,
        isFalse,
      );
    });
  });

  group('SegForgeNodeWidget', () {
    testWidgets('Execute is disabled until a forge run has produced something',
        (tester) async {
      final l = _launcher();
      await _pump(tester, api: _api().api, launcher: l.launcher);

      final execute = tester.widget<ExecuteButton>(find.byType(ExecuteButton));
      expect(execute.enabled, isFalse);
      expect(l.exes, isEmpty, reason: 'nothing launched without Open Forge');
    });

    testWidgets('Open Forge is disabled with no image, enabled once one arrives',
        (tester) async {
      final l = _launcher(autoExit: false);
      final ports =
          await _pump(tester, api: _api(imageBytes: _bytes).api, launcher: l.launcher);

      final forge = find.widgetWithText(OutlinedButton, 'Open Forge');
      expect(tester.widget<OutlinedButton>(forge).onPressed, isNull);

      await _send(tester, ports.image, _imageAa(_bytes));
      expect(tester.widget<OutlinedButton>(forge).onPressed, isNotNull);
    });

    testWidgets('a full run hands SegForge its inputs and emits both AAs',
        (tester) async {
      final backend = _api(imageBytes: _bytes, hasSavedSessions: false);
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: backend.api,
        launcher: l.launcher,
        idGenerator: () => _sessionId,
      );

      await _createSession(tester);
      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      // The session and a fetchable URL travel in the environment, because a
      // prebuilt bundle cannot be given new --dart-define values.
      expect(l.exes.single, '/tmp/SegForge');
      expect(l.envs.single['SEGFORGE_SESSION_ID'], _sessionId);
      expect(
        l.envs.single['SEGFORGE_IMAGE_URL'],
        'http://sf.test/storage/sessions/$_sessionId/original.png',
      );
      expect(l.envs.single['SEGFORGE_BACKEND_URL'], 'http://sf.test');

      // The node drives mask + cutout creation itself.
      expect(backend.calls, contains('POST /saveMasks'));
      expect(backend.calls, contains('POST /createSegments'));

      // Wait is unchecked by default, so results fire straight through.
      expect(ports.segments, hasLength(1));
      expect(ports.linkage, hasLength(1));
      expect(ports.segments.single.rows, contains('sess_01:cat:seg_000'));
      expect(ports.segments.single.cols, contains('crop_bytes'));
      expect(ports.linkage.single.rows, contains('sess_01:cat:seg_000'));
    });

    testWidgets('the cutout is cropped to the segment own bbox', (tester) async {
      final cropper = _FakeCropper();
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: l.launcher,
        cropper: cropper,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      // SegForge's cutouts are full-canvas, so the node must crop each one to
      // its box — passed through as xyxy, which is SegForge's own convention.
      expect(cropper.rects, [const ui.Rect.fromLTRB(10, 20, 40, 60)]);
      final aa = ports.segments.single;
      expect(
        aa.vals[aa.cols.indexOf('crop_bytes')],
        base64Encode(const [9, 9, 9]),
      );
    });

    testWidgets('a cutout that will not crop omits the column', (tester) async {
      final cropper = _FakeCropper()..result = null;
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: l.launcher,
        cropper: cropper,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      final aa = ports.segments.single;
      expect(aa.cols, isNot(contains('crop_bytes')));
      expect(aa.cols, contains('bbox'));
    });

    testWidgets('closing SegForge without segmenting reports done, not error',
        (tester) async {
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes, session: _emptySessionBody()).api,
        launcher: l.launcher,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      expect(ports.segments, isEmpty);
      expect(ports.linkage, isEmpty);
      // Nothing failed — the user just closed the app without segmenting, so
      // the status row is informative rather than red.
      expect(
        find.text('done · closed without producing a segmentation'),
        findsOneWidget,
      );
    });

    testWidgets('a mask that cannot be fetched omits the column, not the row',
        (tester) async {
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes, maskAvailable: false).api,
        launcher: l.launcher,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      final aa = ports.segments.single;
      expect(aa.cols, isNot(contains('mask_bytes')));
      expect(aa.cols, contains('bbox'));
      expect(aa.rows, contains('sess_01:cat:seg_000'));
    });

    testWidgets('a url is passed straight to SegForge, not re-uploaded',
        (tester) async {
      final backend = _api(imageBytes: _bytes, hasSavedSessions: false);
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: backend.api,
        launcher: l.launcher,
        idGenerator: () => _sessionId,
      );

      await _createSession(tester);
      await _send(tester, ports.image, _urlAa('http://example.test/cat.png'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      // SegForge fetches URLs itself, so the node must not move the bytes;
      // no /upload and no /newSession needed — the session is already selected.
      expect(backend.calls, isNot(contains('POST /upload')));
      expect(backend.calls, isNot(contains('POST /newSession')));
      expect(l.envs.single['SEGFORGE_IMAGE_URL'], 'http://example.test/cat.png');
      // image_id comes off the URL's last segment.
      expect(ports.segments.single.rows, contains('sess_01:cat:seg_000'));
    });

    testWidgets('raw bytes are uploaded, since they have no address',
        (tester) async {
      final backend = _api(imageBytes: _bytes, hasSavedSessions: false);
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: backend.api,
        launcher: l.launcher,
        idGenerator: () => _sessionId,
      );

      await _createSession(tester);
      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('POST /upload'));
      expect(backend.calls, isNot(contains('POST /newSession')));
      expect(
        l.envs.single['SEGFORGE_IMAGE_URL'],
        'http://sf.test/storage/sessions/$_sessionId/original.png',
      );
    });

    testWidgets('Wait gates the emit until Execute is pressed', (tester) async {
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: l.launcher,
      );

      // Check Wait first, so the run cannot auto-fire.
      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      expect(ports.segments, isEmpty, reason: 'Wait should hold the result');
      expect(tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
          isTrue);

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();
      expect(ports.segments, hasLength(1));
      expect(ports.linkage, hasLength(1));
    });

    testWidgets('Execute re-emits held results without relaunching the app',
        (tester) async {
      final l = _launcher();
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: l.launcher,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();
      expect(ports.segments, hasLength(1));

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      expect(ports.segments, hasLength(2), reason: 'forwarded again');
      expect(l.exes, hasLength(1), reason: 'Execute must not relaunch');
    });

    testWidgets('Open Forge is the button that turns, not Execute',
        (tester) async {
      final l = _launcher(autoExit: false);
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: l.launcher,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      // Still open: the fake process has not exited.
      expect(l.procs.single.killed, isFalse);

      expect(find.widgetWithText(OutlinedButton, 'Open Forge'), findsNothing);
      final close = find.widgetWithText(OutlinedButton, 'Close Forge');
      expect(close, findsOneWidget);
      expect(tester.widget<OutlinedButton>(close).onPressed, isNotNull);

      // Execute is a forward-what-is-held button; a forge run is not its
      // execution, so it must not read as Cancel.
      expect(tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
          isFalse);
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('Close Forge saves the session, closes the app, and collects',
        (tester) async {
      final backend = _api(imageBytes: _bytes);
      final l = _launcher(autoExit: false, log: backend.calls);
      final ports =
          await _pump(tester, api: backend.api, launcher: l.launcher);

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Close Forge'));
      await tester.pumpAndSettle();

      // The flush has to precede the kill: /loadSession reads state.json, so
      // anything still only in SegForge's memory would be lost.
      expect(backend.calls, contains('POST /saveSession'));
      expect(backend.calls.indexOf('POST /saveSession'),
          lessThan(backend.calls.indexOf('KILL')));
      expect(l.procs.single.killed, isTrue);

      // Closing the app this way collects exactly as closing its window does.
      expect(ports.segments, hasLength(1));
      expect(ports.linkage, hasLength(1));
      expect(find.widgetWithText(OutlinedButton, 'Open Forge'), findsOneWidget);
    });

    testWidgets('with no window up yet, the forge button aborts the run',
        (tester) async {
      final ports = await _pump(
        tester,
        api: _api(imageBytes: _bytes).api,
        launcher: _neverLaunches,
      );

      await _send(tester, ports.image, _imageAa(_bytes));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open Forge'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Close Forge'));
      await tester.pumpAndSettle();

      // Back to idle with nothing emitted — a cancel, per the contract.
      expect(find.widgetWithText(OutlinedButton, 'Open Forge'), findsOneWidget);
      expect(ports.segments, isEmpty);
      expect(ports.linkage, isEmpty);
    });

    testWidgets('an image column that is not base64 is reported, not thrown',
        (tester) async {
      final l = _launcher();
      final ports = await _pump(tester, api: _api().api, launcher: l.launcher);

      await _send(
        tester,
        ports.image,
        const AaPayload(rows: ['img'], cols: ['bytes'], vals: ['!!not base64!!']),
      );

      expect(find.textContaining('base64'), findsOneWidget);
      expect(l.exes, isEmpty);
    });
  });

  group('cropPng', () {
    // Plain `test`, not `testWidgets`: real rasterization needs actual async,
    // which the widget-test zone does not give it.
    test('produces a sub-image of the requested rect', () async {
      final png = await _realPng(100, 100);
      final cropped = await cropPng(png, const ui.Rect.fromLTRB(10, 20, 40, 60));
      expect(cropped, isNotNull);

      final decoded =
          (await (await ui.instantiateImageCodec(cropped!)).getNextFrame()).image;
      expect(decoded.width, 30);
      expect(decoded.height, 40);
    });

    test('clamps a box that runs past the image edge', () async {
      final png = await _realPng(50, 50);
      final cropped = await cropPng(png, const ui.Rect.fromLTRB(30, 30, 500, 500));
      expect(cropped, isNotNull);

      final decoded =
          (await (await ui.instantiateImageCodec(cropped!)).getNextFrame()).image;
      expect(decoded.width, 20);
      expect(decoded.height, 20);
    });

    test('undecodable bytes give null rather than throwing', () async {
      expect(
        await cropPng(Uint8List.fromList(const [1, 2, 3]),
            const ui.Rect.fromLTRB(0, 0, 10, 10)),
        isNull,
      );
    });

    test('a box outside the image gives null', () async {
      final png = await _realPng(20, 20);
      expect(
        await cropPng(png, const ui.Rect.fromLTRB(100, 100, 110, 110)),
        isNull,
      );
    });
  });
}
