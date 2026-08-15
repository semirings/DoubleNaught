import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/focus_panel.dart' show FocusContent;
import 'package:double_vision/widgets/nodes/implementations/preview_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _aa = AaPayload(rows: ['r1'], cols: ['c1'], vals: ['v1']);
const _other = AaPayload(rows: ['r2'], cols: ['c2'], vals: ['v2']);

void main() {
  group('InputPort departure contract', () {
    test('severing a live wire notifies the owner', () async {
      final out = OutputPort('aaOut');
      final input = InputPort('aa');
      final departures = <void>[];
      input.onDisconnected.listen(departures.add);

      input.connect(out);
      out.emit(_aa);
      await Future<void>.delayed(Duration.zero);
      expect(input.hasData, isTrue);

      input.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(departures, hasLength(1));
      expect(input.hasData, isFalse);
    });

    test('disconnecting an unwired port notifies nobody', () async {
      final input = InputPort('aa');
      final departures = <void>[];
      input.onDisconnected.listen(departures.add);

      input.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(departures, isEmpty);
    });

    test('re-pointing departs the old wire then replays the new one', () async {
      final first = OutputPort('first')..emit(_aa);
      final second = OutputPort('second')..emit(_other);
      final input = InputPort('aa');
      final events = <String>[];
      input.onDisconnected.listen((_) => events.add('departed'));
      input.onDataArrived.listen((p) => events.add('data:${p.vals.first}'));

      input.connect(first);
      await Future<void>.delayed(Duration.zero);
      input.connect(second);
      await Future<void>.delayed(Duration.zero);

      expect(events, ['data:v1', 'departed', 'data:v2']);
    });

    test('dispose does not notify', () async {
      final out = OutputPort('aaOut');
      final input = InputPort('aa');
      final departures = <void>[];
      input.onDisconnected.listen(departures.add);

      input.connect(out);
      input.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(departures, isEmpty);
    });
  });

  group('Preview drops a dead upstream', () {
    testWidgets('unwiring clears the summary and retracts the panel tab',
        (tester) async {
      final out = OutputPort('aaOut');
      InputPort? registered;
      final pushed = <int>[];
      final cleared = <int>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PreviewNode(
            node: const WorkflowNode(id: 7, type: 'preview'),
            inputConnected: true,
            onInputPort: (p) => registered = p,
            onContent: (id, FocusContent _) => pushed.add(id),
            onContentCleared: cleared.add,
          ),
        ),
      ));

      registered!.connect(out);
      out.emit(_aa);
      await tester.pumpAndSettle();

      expect(find.text('AA · 1 rows × 1 cols'), findsOneWidget);
      expect(pushed, [7]);

      // The wire is cut — the canvas calls disconnect() on the input port.
      registered!.disconnect();
      await tester.pumpAndSettle();

      expect(find.text('AA · 1 rows × 1 cols'), findsNothing);
      expect(find.text('Waiting for data…'), findsOneWidget);
      expect(cleared, [7]);
    });

    testWidgets('re-pointing shows the new upstream, not the old',
        (tester) async {
      final first = OutputPort('first')..emit(_aa);
      final second = OutputPort('second')..emit(_other);
      InputPort? registered;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PreviewNode(
            node: const WorkflowNode(id: 7, type: 'preview'),
            inputConnected: true,
            onInputPort: (p) => registered = p,
            onContent: (_, __) {},
            onContentCleared: (_) {},
          ),
        ),
      ));

      registered!.connect(first);
      await tester.pumpAndSettle();
      expect(find.text('AA · 1 rows × 1 cols'), findsOneWidget);

      // Re-point at an upstream that has never emitted: the node must go quiet
      // rather than keep advertising the first upstream's payload.
      final silent = OutputPort('silent');
      registered!.connect(silent);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for data…'), findsOneWidget);

      // Re-point at one that has data: it replays on connect.
      registered!.connect(second);
      await tester.pumpAndSettle();
      expect(find.text('AA · 1 rows × 1 cols'), findsOneWidget);
    });
  });
}
