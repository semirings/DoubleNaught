// Layered TextField focus test — step through each layer with the buttons.
//
// PURPOSE
// -------
// The D4M node has a WidgetsBindingObserver workaround for TextField focus
// loss on macOS.  This page reproduces the environment one layer at a time
// so we can identify the actual break point without relying on assumptions.
//
// HOW TO USE
// ----------
// Navigate to /textfield-test (registered in root_feature.dart).
// For each layer:
//   1. Tap the TextField, type a few characters.
//   2. Click somewhere outside the text field (but inside the coloured box).
//   3. Tap the TextField again and try to type.
//   4. If typing fails at step 3, this layer is the break point.
//
// Layers (toggled with the row of buttons at the top):
//   L0  Bare TextField, no parent infrastructure at all.
//   L1  + DoubleNaughtNodeWrapper card chrome.
//   L2  + Outer Focus(canvasFocusNode, autofocus:true, onKeyEvent: ...).
//       The onKeyEvent mirrors the canvas: passes through when a text field
//       is focused, handles Delete/Cmd-C only when canvas is primary focus.
//   L3  + Listener(onPointerDown: setState) around the node — replicates
//       the _nodeShell Listener that calls _selectNode → setState on every
//       pointer down event inside the node.
//   L4  + Stack-level GestureDetector(opaque, onTapUp: canvasFocus.requestFocus())
//       below the node — replicates _onCanvasTapUp stealing focus on canvas
//       taps.  Tests whether the opaque GD fires for TextField clicks too.
//   L5  + WidgetsBindingObserver lifecycle restore — replicates the
//       D4mNode workaround exactly.  If L4 broke things, this should fix them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/nodes/base/base_node.dart' show kNodeRadius;
import '../widgets/nodes/base/double_naught_node_wrapper.dart';

class TextFieldTestPage extends StatefulWidget {
  const TextFieldTestPage({super.key});

  @override
  State<TextFieldTestPage> createState() => _TextFieldTestPageState();
}

class _TextFieldTestPageState extends State<TextFieldTestPage>
    with WidgetsBindingObserver {
  // Which layer is active (0–5).
  int _layer = 0;

  // ── Layer 2: canvas focus node ───────────────────────────────────────────
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'testCanvas');

  // ── Layer 3/4: selection state used by setState ──────────────────────────
  bool _selected = false;

  // ── Layer 5: lifecycle restore (mirrors D4mNode) ─────────────────────────
  final FocusNode _tfFocus = FocusNode(debugLabel: 'testTextField');
  bool _restoreOnResume = false;

  // ── TextField controller ─────────────────────────────────────────────────
  final TextEditingController _ctrl = TextEditingController();

  // Log of events shown at the bottom.
  final List<String> _log = [];

  void _addLog(String msg) {
    setState(() {
      _log.insert(0, msg);
      if (_log.length > 30) _log.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tfFocus.addListener(() {
      final hasFocus = _tfFocus.hasFocus;
      final pf = FocusManager.instance.primaryFocus;
      _addLog('tfFocus: ${hasFocus ? "gained" : "lost"}  '
          'primaryFocus=${pf?.debugLabel ?? "null"}');
      if (_layer >= 5) {
        if (!hasFocus) {
          _restoreOnResume =
              pf == null || pf == FocusManager.instance.rootScope;
        } else {
          _restoreOnResume = false;
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _canvasFocus.dispose();
    _tfFocus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _addLog('lifecycle → $state  restoreOnResume=$_restoreOnResume');
    if (_layer >= 5) {
      if ((state == AppLifecycleState.resumed ||
              state == AppLifecycleState.hidden) &&
          _restoreOnResume) {
        _restoreOnResume = false;
        if (mounted) _tfFocus.requestFocus();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        _restoreOnResume = false;
      }
    }
  }

  // ── Canvas onKey (Layer 2) ───────────────────────────────────────────────
  KeyEventResult _onCanvasKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isDelete = event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace;
    final isCopy = event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isMetaPressed;
    if (!isDelete && !isCopy) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus != _canvasFocus) {
      return KeyEventResult.ignored;
    }
    _addLog('canvas handled: ${event.logicalKey.keyLabel}');
    return KeyEventResult.handled;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('TextField Focus Test')),
      body: Column(
        children: [
          // ── Layer selector ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Active layer: L$_layer  —  ${_layerLabel(_layer)}',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i <= 5; i++)
                      FilledButton.tonal(
                        onPressed:
                            () => setState(() { _layer = i; _log.clear(); }),
                        style: FilledButton.styleFrom(
                          backgroundColor: _layer == i
                              ? theme.colorScheme.primary
                              : null,
                          foregroundColor: _layer == i
                              ? theme.colorScheme.onPrimary
                              : null,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                        ),
                        child: Text('L$i'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _layerDescription(_layer),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── Test area ───────────────────────────────────────────────────
          Expanded(
            flex: 3,
            child: Center(child: _testArea(theme)),
          ),

          const Divider(height: 1),

          // ── Event log ───────────────────────────────────────────────────
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: Row(
                    children: [
                      Text('Event log',
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _log.clear()),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            textStyle: theme.textTheme.labelSmall),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Text(
                      _log[i],
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Layer builder ─────────────────────────────────────────────────────────

  Widget _testArea(ThemeData theme) {
    final tf = _buildTextField(theme);
    // L0: bare TextField.
    if (_layer == 0) return SizedBox(width: 340, child: tf);

    // L1: + DoubleNaughtNodeWrapper chrome.
    Widget inner = SizedBox(
      width: 340,
      child: DoubleNaughtNodeWrapper(
        title: 'D4M',
        icon: Icons.functions,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: tf,
        ),
      ),
    );
    if (_layer == 1) return inner;

    // L2: + canvas Focus with onKeyEvent.
    inner = Focus(
      focusNode: _canvasFocus,
      autofocus: true,
      onKeyEvent: _onCanvasKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: inner,
      ),
    );
    if (_layer == 2) return inner;

    // L3: + Listener(onPointerDown → setState) around the node.
    inner = Listener(
      onPointerDown: (_) {
        _addLog('Listener.onPointerDown → setState');
        setState(() => _selected = !_selected);
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          inner,
          // Selected outline — mirrors workflow_page._nodeShell
          if (_selected)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(kNodeRadius),
                    border: Border.all(
                        color: theme.colorScheme.tertiary, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (_layer == 3) return inner;

    // L4: + opaque canvas GestureDetector beneath the node that calls
    // canvasFocus.requestFocus() — replicates _onCanvasTapUp.
    final canvasTapLog = _addLog;
    inner = Stack(
      children: [
        // Bottom: opaque GD that steals focus on tap (canvas simulation).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              canvasTapLog('canvasTapUp → canvasFocus.requestFocus()');
              _canvasFocus.requestFocus();
            },
            child: Container(
              color: theme.colorScheme.surfaceContainerLowest,
            ),
          ),
        ),
        // Top: the node (with its Listener, chrome, and TextField).
        Center(child: inner),
      ],
    );
    if (_layer == 4) return inner;

    // L5: lifecycle workaround is active via WidgetsBindingObserver in
    // this State. Nothing to add to the widget tree — just enable logging.
    return inner;
  }

  Widget _buildTextField(ThemeData theme) => TextField(
        controller: _ctrl,
        focusNode: _layer >= 2 ? _tfFocus : null,
        minLines: 4,
        maxLines: 8,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        decoration: const InputDecoration(
          labelText: 'type here',
          hintText: 'click me, type, click outside, click me again',
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
        onChanged: (v) => _addLog('onChanged: ${v.length} chars'),
        onTap: () => _addLog('TextField.onTap'),
      );

  String _layerLabel(int l) => switch (l) {
        0 => 'bare TextField',
        1 => '+ node chrome (DoubleNaughtNodeWrapper)',
        2 => '+ canvas Focus with onKeyEvent',
        3 => '+ Listener → setState on pointer down',
        4 => '+ opaque canvas GestureDetector stealing focus on tap',
        5 => '+ WidgetsBindingObserver lifecycle restore',
        _ => '',
      };

  String _layerDescription(int l) => switch (l) {
        0 => 'No parent infrastructure. Should always work.',
        1 => 'TextField inside node card chrome. No gestures.',
        2 => 'Parent Focus(autofocus, onKeyEvent) mirrors the canvas widget. '
            'onKeyEvent passes through when a text field is focused.',
        3 => 'Listener.onPointerDown → setState on every click inside the node. '
            'Mirrors _nodeShell which calls _selectNode on every pointer down.',
        4 => 'An opaque GestureDetector under the node calls '
            'canvasFocus.requestFocus() on every tap — mirrors _onCanvasTapUp. '
            'THIS IS THE KEY LAYER: does clicking the TextField still work?',
        5 => 'Adds the WidgetsBindingObserver lifecycle workaround from '
            'D4mNode. If L4 broke focus, check whether this fixes it.',
        _ => '',
      };
}
