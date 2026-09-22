import 'dart:async';
import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
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
  final void Function(Map<String, String>)? onParams;
  final List<AaPayload> emitted;
  final VoidCallback? onAddLeft;
  final VoidCallback? onAddRight;

  const _Harness({
    required this.api,
    required this.emitted,
    this.initialParams,
    this.onPorts,
    this.onParams,
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
                  onParams: widget.onParams,
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
    testWidgets('starts with a single port "in"', (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
      ));

      expect(find.byType(TextField), findsWidgets);
      expect(ports.keys, [0]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text)
            .contains('in'),
        isTrue,
      );
    });

    testWidgets('the "+" affordance appends B, then C, auto-named', (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
      ));

      await tester.tap(find.text('port'));
      await tester.pumpAndSettle();
      expect(ports.keys, [0, 1]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text),
        containsAll(['in', 'B']),
      );

      await tester.tap(find.text('port'));
      await tester.pumpAndSettle();
      expect(ports.keys, [0, 1, 2]);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.controller?.text),
        containsAll(['in', 'B', 'C']),
      );
    });

    testWidgets('a port can be renamed inline', (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: const []));

      final nameField = find.widgetWithText(TextField, 'in');
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

      await tester.tap(find.text('port')); // add B
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
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: const []));
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
        emitted: const [],
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
    testWidgets('is labeled "out", not the legacy "evaluatedResult"',
        (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: const []));
      expect(
        tester.widget<OutputConnector>(find.byType(OutputConnector)).label,
        'out',
      );
    });
  });

  group('Wait/Execute readiness', () {
    testWidgets('empty script and no port data: Execute disabled', (tester) async {
      await tester.pumpWidget(_Harness(api: _successApi(), emitted: const []));
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

      await tester.tap(find.text('port')); // add B
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
        emitted: const [],
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

  group('script port', () {
    /// The shape Load File emits for a `.jl` file: one row, `text` alongside
    /// the path it came from.
    AaPayload sourceAa(String code, {String path = '/tmp/selectors.jl'}) =>
        AaPayload(
          rows: const ['0', '0'],
          cols: const ['text', 'file_path'],
          vals: [code, path],
        );

    String scriptText(WidgetTester tester) => tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.decoration?.labelText == 'Julia D4M Script')
        .controller!
        .text;

    /// A node whose second slot is the script port, marked the way the node
    /// itself persists it.
    const withScriptPort = {'portNames': 'A,script', 'scriptPortIdx': '1'};

    /// The name field of the port at [i], identified by position in the row
    /// list — the script box and the out-symbol field are TextFields too.
    TextField nameField(WidgetTester tester, int i) => tester
        .widgetList<TextField>(find.byType(TextField))
        .elementAt(i);

    testWidgets('the script port puts what arrives into the script box',
        (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        initialParams: withScriptPort,
      ));

      expect(scriptText(tester), isEmpty);
      await _feedPort(tester, ports, 1, sourceAa('Out = A[:, ["x"]]'));

      expect(scriptText(tester), 'Out = A[:, ["x"]]');

      // Replace, not append: an arrival is the script now, whatever was in the
      // box before — including something typed by hand.
      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 1, sourceAa('Out = A + A'));

      expect(scriptText(tester), 'Out = A + A');
    });

    testWidgets('a fresh node has none until + script is clicked',
        (tester) async {
      final ports = <int, InputPort>{};
      final saved = <Map<String, String>>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        onParams: saved.add,
      ));

      expect(ports.keys, [0]);
      expect(find.widgetWithText(Tooltip, 'script'), findsOneWidget,
          reason: 'the affordance is there to be found');

      await tester.tap(find.text('script'));
      await tester.pumpAndSettle();

      expect(ports.keys, [0, 1]);
      // Which slot it is gets persisted, so a reload does not have to guess
      // from the name.
      expect(saved.last['portNames'], 'in,script');
      expect(saved.last['scriptPortIdx'], '1');
      // Offered once: the remaining 'script' text is the port's own name field.
      expect(find.widgetWithText(Tooltip, 'script'), findsNothing);
      expect(nameField(tester, 1).controller?.text, 'script');
    });

    testWidgets('its name field is read-only, unlike a data port\'s',
        (tester) async {
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        initialParams: withScriptPort,
      ));

      expect(nameField(tester, 0).readOnly, isFalse);
      expect(nameField(tester, 1).readOnly, isTrue,
          reason: 'the name means nothing to anything now; editing it misleads');
    });

    testWidgets('it renders last, and stays last as data ports are added',
        (tester) async {
      final ports = <int, InputPort>{};
      final saved = <Map<String, String>>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        onParams: saved.add,
        initialParams: withScriptPort,
      ));

      List<String> laneLabels() => tester
          .widgetList<InputConnector>(find.byType(InputConnector))
          .map((c) => c.label)
          .toList();
      expect(laneLabels(), ['A', 'script']);

      await tester.tap(find.text('port'));
      await tester.pumpAndSettle();

      // The new data port went in above the script port, not after it — index
      // order is what the connector lane and the edge anchors both step by.
      expect(laneLabels(), ['A', 'B', 'script']);
      expect(saved.last['portNames'], 'A,B,script');
      expect(saved.last['scriptPortIdx'], '2');
    });

    testWidgets('the port that moved keeps its own data, not the slot\'s',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
        initialParams: withScriptPort,
      ));

      await _feedPort(tester, ports, 1, sourceAa('Out = A'));
      expect(scriptText(tester), 'Out = A');

      // Inserting a data port pushes the script port from slot 1 to slot 2.
      await tester.tap(find.text('port'));
      await tester.pumpAndSettle();

      // Its script survived the move, and the vacated slot did not inherit it.
      expect(scriptText(tester), 'Out = A');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
        reason: 'A and B are both still empty',
      );
    });

    testWidgets('an unwired script port does not hold Execute back',
        (tester) async {
      final ports = <int, InputPort>{};
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: emitted,
        onPorts: ports.addAll,
        initialParams: withScriptPort,
      ));

      await tester.enterText(
          find.widgetWithText(TextField, 'Julia D4M Script'), 'Out = A');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, _aa);
      await tester.pumpAndSettle();

      // A hand-typed script is a complete script; the port owes nothing.
      expect(find.textContaining('done'), findsOneWidget);
    });

    testWidgets('the script port is not bound as a Julia variable',
        (tester) async {
      final ports = <int, InputPort>{};
      final execBodies = <Map<String, dynamic>>[];
      final api = D4mApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/ingest')) {
            return _jsonResponse({'handleId': 'h-in', 'nnz': 1});
          }
          if (request.url.path.endsWith('/exec')) {
            execBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonResponse(
                {'handleId': 'h-out', 'numRows': 1, 'numCols': 1, 'nnz': 1});
          }
          return _jsonResponse({
            'handleId': 'h-out',
            'page': 0,
            'pageSize': 10000,
            'totalNnz': 1,
            'aa': _aa.toJson(),
          });
        }),
      );

      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        api: api,
        emitted: emitted,
        onPorts: ports.addAll,
        initialParams: withScriptPort,
      ));

      await _feedPort(tester, ports, 1, sourceAa('Out = A'));
      await _feedPort(tester, ports, 0, _aa);
      await tester.pumpAndSettle();

      expect(execBodies, hasLength(1));
      final inputs = execBodies.single['inputs'] as Map<String, dynamic>;
      expect(inputs.keys, ['A'],
          reason: 'the script is the script, not a variable holding itself');
      expect(execBodies.single['script'], 'Out = A');
    });

    testWidgets('naming a data port "script" does not promote it',
        (tester) async {
      final ports = <int, InputPort>{};
      final saved = <Map<String, String>>[];
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        onParams: saved.add,
      ));

      await tester.enterText(find.widgetWithText(TextField, 'in'), 'script');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 0, sourceAa('Out = B'));

      // Still a data port: the script box stays empty and the payload is held
      // as data. Which is the point — if a name could promote a port, a typo
      // in that name could demote one, silently.
      expect(scriptText(tester), isEmpty);
      expect(saved.last['scriptPortIdx'], '-1', reason: 'no script port');
      expect(find.widgetWithText(Tooltip, 'script'), findsOneWidget,
          reason: 'the node still has no script port to offer against');
    });

    testWidgets('the script port survives a rename attempt on itself',
        (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        initialParams: withScriptPort,
      ));

      // enterText goes through the same channel a keystroke does, so a
      // read-only field is the same wall here that it is on screen.
      await tester.enterText(find.widgetWithText(TextField, 'script'), 'scirpt');
      await tester.pumpAndSettle();
      await _feedPort(tester, ports, 1, sourceAa('Out = A'));

      expect(nameField(tester, 1).controller?.text, 'script');
      expect(scriptText(tester), 'Out = A');
    });

    testWidgets('a workflow saved before scriptPortIdx still restores it',
        (tester) async {
      final ports = <int, InputPort>{};
      await tester.pumpWidget(_Harness(
        api: _successApi(),
        emitted: const [],
        onPorts: ports.addAll,
        // No scriptPortIdx — in these files the name really was the marker.
        initialParams: const {'portNames': 'A,script'},
      ));

      await _feedPort(tester, ports, 1, sourceAa('Out = A'));
      expect(scriptText(tester), 'Out = A');
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
        emitted: const [],
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
        _Harness(api: _successApi(), emitted: const []),
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
        _Harness(api: _successApi(), emitted: const []),
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
        _Harness(api: _successApi(), emitted: const []),
      );

      await tester.tap(find.byTooltip('Expand Editor'));
      await tester.pumpAndSettle();
      expect(find.byType(PromptCanvasEditor), findsOneWidget);
    });
  });
}
