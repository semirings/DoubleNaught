import 'dart:async';
import 'dart:convert';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/d4m_api.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/focus_panel.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:double_vision/widgets/prompt_canvas_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _aa = AaPayload(rows: ['0'], cols: ['val'], vals: [1]);

/// Harness mirroring the Prompt Node test's shape: mounts the node and, like
/// the canvas, renders whatever is pushed to the Focus Panel, so the inline
/// script box and the expanded editor are live at the same time.
class _Harness extends StatefulWidget {
  final D4mApi api;
  final Map<String, String>? initialParams;
  final void Function(Map<int, InputPort>)? onPorts;
  final List<AaPayload> emitted;
  final VoidCallback? onAddLeft;
  final VoidCallback? onAddRight;

  const _Harness({
    required this.api,
    required this.emitted,
    this.initialParams,
    this.onPorts,
    this.onAddLeft,
    this.onAddRight,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final Map<int, InputPort> ports = {};
  FocusContent? content;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: D4mNode(
                  node: const WorkflowNode(id: 1, type: 'd4m'),
                  initialParams: widget.initialParams,
                  api: widget.api,
                  onPort: (idx, port) {
                    ports[idx] = port;
                    widget.onPorts?.call(ports);
                  },
                  onOutputPort: (port) =>
                      port.connect(widget.emitted.add, emitCurrentState: false),
                  onAddLeft: widget.onAddLeft,
                  onAddRight: widget.onAddRight,
                  onContent: (_, c) => setState(() => content = c),
                  onView: (_) {},
                ),
              ),
            ),
            Expanded(
              child: content?.controller == null
                  ? const SizedBox.shrink()
                  : PromptCanvasEditor(controller: content!.controller!),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _feedPort(
  WidgetTester tester,
  Map<int, InputPort> ports,
  int idx,
  AaPayload payload,
) async {
  final upstream = OutputPort('upstream$idx');
  ports[idx]!.connect(upstream);
  upstream.emit(payload);
  await tester.pumpAndSettle();
}

/// Simulates a double-tap: two taps at the same point within
/// `kDoubleTapTimeout` (300ms), without a full settle in between.
Future<void> _doubleTapAt(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(point);
  await tester.pumpAndSettle();
}

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

D4mApi _successApi() => D4mApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/ingest')) {
          return _jsonResponse({'handleId': 'h-in', 'nnz': 1});
        }
        if (request.url.path.endsWith('/exec')) {
          return _jsonResponse(
              {'handleId': 'h-out', 'numRows': 1, 'numCols': 1, 'nnz': 1});
        }
        if (request.url.path.endsWith('/preview')) {
          return _jsonResponse({
            'handleId': 'h-out',
            'page': 0,
            'pageSize': 10000,
            'totalNnz': 1,
            'aa': _aa.toJson(),
          });
        }
        throw StateError('unexpected path ${request.url.path}');
      }),
    );

void main() {
  group('dynamic ports', () {
    testWidgets('starts with a single port "A"', (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: [],
        onPorts: ports.addAll,
      ));

      expect(find.byType(TextField), findsWidgets);
      expect(ports.keys, [0]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text)
            .contains('A'),
        isTrue,
      );
    });

    testWidgets('the "+" affordance appends B, then C, auto-named', (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: [],
        onPorts: ports.addAll,
      ));

      await tester.tap(find.text('+').first);
      await tester.pumpAndSettle();
      expect(ports.keys, [0, 1]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text),
        containsAll(['A', 'B']),
      );

      await tester.tap(find.text('+').first);
      await tester.pumpAndSettle();
      expect(ports.keys, [0, 1, 2]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text),
        containsAll(['A', 'B', 'C']),
      );
    });

    testWidgets('a port can be renamed inline', (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: []));

      final nameField = find.widgetWithText(TextField, 'A');
      await tester.enterText(nameField, 'left');
      await tester.pumpAndSettle();

      expect(find.byType(InputConnector), findsOneWidget);
      expect(
        tester.widget<InputConnector>(find.byType(InputConnector)).label,
        'left',
      );
    });

    testWidgets(
        'removing a port re-registers the survivor at its new index — not '
        'just its rename controller, the actual InputPort the canvas holds',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.tap(find.text('+').first); // add B
      await tester.pumpAndSettle();
      final portB = ports[1];
      expect(portB, isNotNull);

      // Remove the first port (A) — only shown once >1 port exists.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      // B is the same live InputPort object, now re-registered at slot 0 —
      // the callback API has no "unregister" signal, so a stale leftover at
      // key 1 in the *test's own* bookkeeping is expected and harmless; what
      // matters is that slot 0 now correctly resolves to B, not to A's
      // now-disposed port.
      expect(ports[0], same(portB));
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text),
        contains('B'),
      );

      // And the data-arrival tracking follows the same live lookup: feeding
      // the survivor (now at index 0) is what the widget itself sees as
      // satisfying its one remaining port, not a stale captured index.
      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = B');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);
      expect(emitted, hasLength(1));
    });

    testWidgets('the lone remaining port has no remove icon', (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: []));
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group('chain-nav arrows — independent of port management', () {
    testWidgets('left/right arrows call onAddLeft/onAddRight, not port logic',
        (tester) async {
      var left = 0;
      var right = 0;
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: [],
        onPorts: ports.addAll,
        onAddLeft: () => left++,
        onAddRight: () => right++,
      ));

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(left, 1);
      expect(right, 0);
      // Chaining a sibling node must not touch this node's own ports.
      expect(ports.keys, [0]);

      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(right, 1);
      expect(ports.keys, [0]);
    });
  });

  group('output port', () {
    testWidgets('is labeled "Out", not the legacy "evaluatedResult"',
        (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: []));
      expect(
        tester.widget<OutputConnector>(find.byType(OutputConnector)).label,
        'Out',
      );
    });
  });

  group('Wait/Execute readiness', () {
    testWidgets('empty script and no port data: Execute disabled', (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: []));
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets(
        'reactive (Wait unchecked, the default): firing happens as soon as '
        'the script is non-empty and port A has data',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      expect(emitted, isEmpty); // script alone isn't ready — A has no data

      await _feedPort(tester, ports, 0, _aa);
      expect(emitted, hasLength(1));
      expect(find.textContaining('done'), findsOneWidget);
    });

    testWidgets(
        'with two ports, Execute stays disabled until BOTH have data',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.tap(find.text('+').first); // add B
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A + B');
      await tester.pumpAndSettle();

      await _feedPort(tester, ports, 0, _aa);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
        reason: 'B has no data yet',
      );
      expect(emitted, isEmpty);

      await _feedPort(tester, ports, 1, _aa);
      expect(emitted, hasLength(1), reason: 'both ports now satisfied');
    });

    testWidgets('gated (Wait checked): ready data does not auto-fire',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);

      expect(emitted, isEmpty, reason: 'gated — nothing fires until Execute');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'Execute enablement is independent of Wait',
      );

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();
      expect(emitted, hasLength(1));
      // Clicking Execute unchecks Wait as a side effect.
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );
    });

    testWidgets(
        'manually unchecking Wait fires immediately when already ready',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);
      expect(emitted, isEmpty);

      await tester.tap(find.byType(WaitCheckbox)); // uncheck while ready
      await tester.pumpAndSettle();
      expect(emitted, hasLength(1));
    });

    testWidgets(
        'unchecking Wait while NOT ready just becomes reactive — fires '
        'later once ready, not immediately',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WaitCheckbox)); // uncheck — not ready yet
      await tester.pumpAndSettle();
      expect(emitted, isEmpty);

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);
      expect(emitted, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final ports = <int, InputPort>{};
      final response = Completer<http.Response>();
      final api = D4mApi(
        client: MockClient((request) {
          if (request.url.path.endsWith('/ingest')) {
            return Future.value(_jsonResponse({'handleId': 'h-in', 'nnz': 1}));
          }
          return response.future;
        }),
      );

      await tester.pumpWidget(_Harness(
        api: api,
        emitted: [],
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa); // auto-fires; now executing

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

      response.complete(_jsonResponse(
          {'handleId': 'h-out', 'numRows': 1, 'numCols': 1, 'nnz': 1}));
      await tester.pumpAndSettle();
    });
  });

  group('script execution', () {
    testWidgets('success: emits, status shows done with shape', (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);

      expect(emitted, hasLength(1));
      expect(emitted.single.value('val'), '1');
      expect(find.textContaining('done'), findsOneWidget);
      expect(find.textContaining('1×1'), findsOneWidget);
      expect(
        tester
            .widget<DoubleNaughtNodeWrapper>(
                find.byType(DoubleNaughtNodeWrapper))
            .borderState,
        CardBorderState.normal,
      );
    });

    testWidgets('failure: status shows error, nothing emitted', (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      final api = D4mApi(
        client: MockClient((request) async =>
            _jsonResponse({'detail': 'bad script'}, 422)),
      );

      await tester.pumpWidget(_Harness(
        api: api,
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);

      expect(emitted, isEmpty);
      expect(find.textContaining('error'), findsOneWidget);
      expect(
        tester
            .widget<DoubleNaughtNodeWrapper>(
                find.byType(DoubleNaughtNodeWrapper))
            .borderState,
        CardBorderState.error,
      );
    });
  });

  group('Cancel — hard abort', () {
    /// Holds the /exec response open so a running exec is observable, and
    /// lets the test decide exactly when (or whether) it resolves.
    ({D4mApi api, Completer<http.Response> exec}) gatedApi() {
      final exec = Completer<http.Response>();
      final api = D4mApi(
        client: MockClient((request) {
          if (request.url.path.endsWith('/ingest')) {
            return Future.value(_jsonResponse({'handleId': 'h-in', 'nnz': 1}));
          }
          if (request.url.path.endsWith('/exec')) {
            return exec.future;
          }
          throw StateError('unexpected path ${request.url.path}');
        }),
      );
      return (api: api, exec: exec);
    }

    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves — and a later-arriving success is discarded',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      final gated = gatedApi();

      await tester.pumpWidget(_Harness(
        api: gated.api,
        emitted: emitted,
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa); // auto-fires; now executing

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isTrue,
      );
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      expect(find.textContaining('idle'), findsOneWidget);
      expect(
        tester
            .widget<DoubleNaughtNodeWrapper>(
                find.byType(DoubleNaughtNodeWrapper))
            .borderState,
        CardBorderState.normal,
      );
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isFalse,
      );

      // The request finally resolves, well after cancel — must be ignored.
      gated.exec.complete(_jsonResponse(
          {'handleId': 'h-out', 'numRows': 1, 'numCols': 1, 'nnz': 1}));
      await tester.pumpAndSettle();

      expect(emitted, isEmpty, reason: 'the cancelled run\'s result must not emit');
      expect(find.textContaining('idle'), findsOneWidget);
    });

    testWidgets('cancelling never surfaces error status', (tester) async {
      final ports = <int, InputPort>{};
      final gated = gatedApi();

      await tester.pumpWidget(_Harness(
        api: gated.api,
        emitted: [],
        onPorts: ports.addAll,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);

      await tester.tap(find.byType(ExecuteButton));
      await tester.pump();

      // Even if the in-flight call eventually throws (aborted transport),
      // that must not read as a failure.
      gated.exec.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
    });
  });

  group('bidirectional script sync (Focus Panel)', () {
    testWidgets('typing alone never conjures the panel', (tester) async {
      await tester.pumpWidget(
        _Harness(api: _successApi(), emitted: []),
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();

      expect(find.byType(PromptCanvasEditor), findsNothing);
    });

    testWidgets(
        'double-tapping the script box opens the expanded editor, and edits '
        'in either surface appear in the other',
        (tester) async {
      await tester.pumpWidget(
        _Harness(api: _successApi(), emitted: []),
      );

      final scriptField =
          find.widgetWithText(TextField, 'Julia D4M Script');
      await tester.enterText(scriptField, 'Out = A');
      await tester.pumpAndSettle();

      await _doubleTapAt(tester, tester.getCenter(scriptField));
      expect(find.byType(PromptCanvasEditor), findsOneWidget);

      final expandedField = find.descendant(
        of: find.byType(PromptCanvasEditor),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(expandedField).controller!.text,
        'Out = A',
      );

      // Edit in the expanded editor; the inline field reflects it too, since
      // both are the same live controller.
      await tester.enterText(expandedField, 'Out = A + B');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(scriptField).controller!.text,
        'Out = A + B',
      );
    });

    testWidgets('the corner expand icon also opens the editor', (tester) async {
      await tester.pumpWidget(
        _Harness(api: _successApi(), emitted: []),
      );

      await tester.tap(find.byTooltip('Expand Editor'));
      await tester.pumpAndSettle();
      expect(find.byType(PromptCanvasEditor), findsOneWidget);
    });
  });
}
