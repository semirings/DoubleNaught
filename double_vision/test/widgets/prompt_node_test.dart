import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/widgets/focus_panel.dart';
import 'package:double_vision/widgets/nodes/implementations/prompt_node_widget.dart';
import 'package:double_vision/widgets/prompt_canvas_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _debounce = Duration(milliseconds: 10);

/// Harness that mounts the node and, like the canvas, renders whatever the node
/// pushes to the Focus Panel — so the inline field and the expanded editor are
/// live at the same time, which is the point of the sync requirement.
class _Harness extends StatefulWidget {
  final Map<String, String>? initialParams;
  final void Function(InputPort) onInputPort;
  final void Function(OutputPort) onOutputPort;

  const _Harness({
    required this.onInputPort,
    required this.onOutputPort,
    this.initialParams,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  FocusContent? _content;
  int views = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: PromptNodeWidget(
                  node: const WorkflowNode(id: 3, type: 'promptNode'),
                  initialParams: widget.initialParams,
                  emitDebounce: _debounce,
                  onInputPort: widget.onInputPort,
                  onOutputPort: widget.onOutputPort,
                  onContent: (_, c) => setState(() => _content = c),
                  onView: (_) => views++,
                ),
              ),
            ),
            Expanded(
              child: _content?.controller == null
                  ? const SizedBox.shrink()
                  : PromptCanvasEditor(controller: _content!.controller!),
            ),
          ],
        ),
      ),
    );
  }
}

/// The node's inline field (the only monospace TextField inside the node card).
TextField _inlineField(WidgetTester tester) => tester.widget<TextField>(
      find.descendant(
        of: find.byType(PromptNodeWidget),
        matching: find.byType(TextField),
      ),
    );

Finder _expandedField() => find.descendant(
      of: find.byType(PromptCanvasEditor),
      matching: find.byType(TextField),
    );

void main() {
  group('extractText', () {
    test('prefers a text-bearing column when the AA has one', () {
      const aa = AaPayload(
        rows: ['c:1', 'c:1', 'c:2', 'c:2'],
        cols: ['text', 'position', 'text', 'position'],
        vals: ['first passage', 0, 'second passage', 1],
      );
      expect(
        PromptNodeWidget.extractText(aa),
        'first passage\nsecond passage',
      );
    });

    test('falls back to every string value, skipping numerics', () {
      const aa = AaPayload(
        rows: ['r1', 'r1', 'r1'],
        cols: ['GENDER', 'CITY', 'token_count'],
        vals: ['F', 'Norfolk', 12],
      );
      expect(PromptNodeWidget.extractText(aa), 'F\nNorfolk');
    });

    test('empty and numeric-only AAs yield nothing', () {
      expect(PromptNodeWidget.extractText(const AaPayload()), '');
      expect(
        PromptNodeWidget.extractText(const AaPayload(
          rows: ['r'],
          cols: ['n'],
          vals: [7],
        )),
        '',
      );
    });
  });

  group('Prompt Node', () {
    testWidgets('exposes fileInput on the left and promptOutput on the right',
        (tester) async {
      InputPort? input;
      OutputPort? output;
      await tester.pumpWidget(_Harness(
        onInputPort: (p) => input = p,
        onOutputPort: (p) => output = p,
      ));

      expect(find.text('Prompt Node'), findsOneWidget);
      expect(find.text('fileInput'), findsOneWidget);
      expect(find.text('promptOutput'), findsOneWidget);
      expect(input!.id, 'fileInput');
      expect(output!.id, 'promptOutput');
    });

    testWidgets('typing re-broadcasts a debounced prompt AA', (tester) async {
      OutputPort? out;
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        onInputPort: (_) {},
        onOutputPort: (p) {
          out = p;
          p.connect(emitted.add, emitCurrentState: false);
        },
      ));
      expect(out, isNotNull);

      await tester.enterText(find.byType(TextField).first, 'Summarise this');
      await tester.pump(_debounce);
      await tester.pumpAndSettle();

      expect(emitted, hasLength(1));
      final aa = emitted.single;
      expect(aa.rows, ['prompt:3', 'prompt:3']);
      expect(aa.cols, ['prompt', 'char_count']);
      expect(aa.vals, ['Summarise this', 14]);
      // Retained, so a wire drawn later replays it.
      expect(out!.lastPayload?.vals.first, 'Summarise this');
    });

    testWidgets('clearing publishes an empty prompt rather than going silent',
        (tester) async {
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        initialParams: const {'prompt': 'seeded'},
        onInputPort: (_) {},
        onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
      ));
      await tester.pumpAndSettle();
      emitted.clear();

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump(_debounce);
      await tester.pumpAndSettle();

      expect(emitted.last.vals, ['', 0]);
    });

    testWidgets('restored params publish once past the first frame',
        (tester) async {
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        initialParams: const {'prompt': 'restored', 'insert': 'prepend'},
        onInputPort: (_) {},
        onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
      ));
      await tester.pumpAndSettle();

      expect(emitted, hasLength(1));
      expect(emitted.single.vals.first, 'restored');
      expect(_inlineField(tester).controller!.text, 'restored');
      expect(find.text('prepend'), findsOneWidget);
    });
  });

  group('fileInput ingest', () {
    const file = AaPayload(
      rows: ['f:1'],
      cols: ['text'],
      vals: ['FILE BODY'],
    );

    testWidgets('appends into the editable state by default', (tester) async {
      InputPort? input;
      await tester.pumpWidget(_Harness(
        initialParams: const {'prompt': 'MY PROMPT'},
        onInputPort: (p) => input = p,
        onOutputPort: (_) {},
      ));
      await tester.pumpAndSettle();

      final out = OutputPort('aa')..emit(file);
      input!.connect(out);
      await tester.pumpAndSettle();

      expect(_inlineField(tester).controller!.text, 'MY PROMPT\n\nFILE BODY');
      expect(find.textContaining('1 ingested'), findsWidgets);
    });

    testWidgets('prepends when the insert mode says so', (tester) async {
      InputPort? input;
      await tester.pumpWidget(_Harness(
        initialParams: const {'prompt': 'MY PROMPT', 'insert': 'prepend'},
        onInputPort: (p) => input = p,
        onOutputPort: (_) {},
      ));
      await tester.pumpAndSettle();

      input!.connect(OutputPort('aa')..emit(file));
      await tester.pumpAndSettle();

      expect(_inlineField(tester).controller!.text, 'FILE BODY\n\nMY PROMPT');
    });

    testWidgets('an ingest re-broadcasts downstream', (tester) async {
      InputPort? input;
      final emitted = <AaPayload>[];
      await tester.pumpWidget(_Harness(
        onInputPort: (p) => input = p,
        onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
      ));
      await tester.pumpAndSettle();

      input!.connect(OutputPort('aa')..emit(file));
      await tester.pump(_debounce);
      await tester.pumpAndSettle();

      expect(emitted.last.vals, ['FILE BODY', 9]);
    });
  });

  group('Focus Panel tab ownership', () {
    testWidgets('typing alone never conjures the panel', (tester) async {
      await tester.pumpWidget(_Harness(
        onInputPort: (_) {},
        onOutputPort: (_) {},
      ));

      await tester.enterText(find.byType(TextField).first, 'no panel please');
      await tester.pump(_debounce);
      await tester.pumpAndSettle();

      // Only Expand Editor may create the tab.
      expect(find.byType(PromptCanvasEditor), findsNothing);

      await tester.tapAt(tester.getCenter(find.byTooltip('Expand Editor')));
      await tester.pumpAndSettle();
      expect(find.byType(PromptCanvasEditor), findsOneWidget);
    });
  });

  group('bidirectional sync', () {
    testWidgets('inline edits appear in the expanded editor and vice versa',
        (tester) async {
      await tester.pumpWidget(_Harness(
        onInputPort: (_) {},
        onOutputPort: (_) {},
      ));

      // Expand Editor mounts the panel editor on the same controller.
      await tester.tapAt(tester.getCenter(find.byTooltip('Expand Editor')));
      await tester.pumpAndSettle();
      expect(find.byType(PromptCanvasEditor), findsOneWidget);

      // Node → panel.
      await tester.enterText(find.byType(TextField).first, 'from the node');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_expandedField()).controller!.text,
        'from the node',
      );

      // Panel → node. One controller, so this is the same document.
      await tester.enterText(_expandedField(), 'from the panel');
      await tester.pumpAndSettle();
      expect(_inlineField(tester).controller!.text, 'from the panel');
    });
  });

  group('PromptCanvasEditor', () {
    testWidgets('numbers every logical line and counts the document',
        (tester) async {
      final controller = TextEditingController(text: 'one\ntwo\nthree');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PromptCanvasEditor(controller: controller)),
      ));

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsNothing);
      expect(find.text('3 lines · 13 chars'), findsOneWidget);
    });

    testWidgets('word wrap toggles', (tester) async {
      final controller = TextEditingController(text: 'x');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PromptCanvasEditor(controller: controller)),
      ));

      expect(find.byTooltip('Word wrap: on'), findsOneWidget);
      await tester.tap(find.byTooltip('Word wrap: on'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Word wrap: off'), findsOneWidget);
    });

    testWidgets('Copy All / Paste / Clear act on the shared document',
        (tester) async {
      final controller = TextEditingController(text: 'payload');
      addTearDown(controller.dispose);
      String? copied;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PromptCanvasEditor(
            controller: controller,
            writeClipboard: (t) async => copied = t,
            readClipboard: () async => ' + pasted',
          ),
        ),
      ));

      await tester.tap(find.byTooltip('Copy All'));
      await tester.pumpAndSettle();
      expect(copied, 'payload');
      expect(find.text('Copied 7 chars'), findsOneWidget);

      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();
      expect(controller.text, 'payload + pasted');

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.text('Cleared'), findsOneWidget);
    });
  });
}
