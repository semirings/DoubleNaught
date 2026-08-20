import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../focus_panel.dart' show FocusContent;
import '../../../services/d4m_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node.dart' show kPortSpacing;
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

// ---------------------------------------------------------------------------
// Port data model
// ---------------------------------------------------------------------------

class _D4mPort {
  String name;
  final InputPort inputPort;
  String? handleId; // ingested server-side handle (set after Execute)

  _D4mPort(this.name) : inputPort = InputPort(name);
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// A **functional node** (AA-in → AA-out) that executes a multi-line D4M/Julia
/// script over dynamically-managed input ports.
///
/// * Input ports default to 1, expandable via the `+` button; each supports
///   inline rename.
/// * Wait/Execute: reactive by default (fires the instant every declared port
///   has data and the script is non-empty); Wait gates that — see
///   `UX_UI/GLOBAL_UX_CONTRACT.md` §3.
/// * Execute: ingests each port's AA into server-side handles, runs the script,
///   stores output handle, emits the first 10 000 triples on the port bus.
/// * Left/Right: spawn adjacent D4M nodes.
/// * Merge: combine selected D4M nodes' scripts.
class D4mNode extends BaseNodeWidget {
  static const double _width = 340;

  // Dynamic port callbacks — index-based.
  final void Function(int idx, InputPort port)? onPort;
  final bool Function(int idx)? connectedAt;
  final void Function(PortRef source, int idx)? onConnect;

  // Adjacent-node spawning.
  final VoidCallback? onAddLeft;
  final VoidCallback? onAddRight;

  // Merge controls.
  final bool inMergeSet;
  final VoidCallback? onToggleMerge;
  final bool canMerge;
  final VoidCallback? onMerge;

  /// Pushes the expanded script editor into the Focus Panel as this node's tab.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Opens (and selects) this node's Focus Panel tab.
  final void Function(int nodeId)? onView;

  final D4mApi api;

  const D4mNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onOutputPort,
    super.connectedOutputs,
    this.onPort,
    this.connectedAt,
    this.onConnect,
    this.onAddLeft,
    this.onAddRight,
    this.inMergeSet = false,
    this.onToggleMerge,
    this.canMerge = false,
    this.onMerge,
    this.onContent,
    this.onView,
    this.api = const D4mApi(),
  });

  @override
  State<D4mNode> createState() => _D4mNodeState();
}

class _D4mNodeState extends BaseNodeState<D4mNode>
    with WidgetsBindingObserver, WaitGatedExecution<D4mNode> {
  // ── Required base overrides ────────────────────────────────────────────────
  @override String   get nodeTitle    => 'D4M';
  @override IconData get nodeIcon     => Icons.functions;
  @override String   get workingLabel => 'executing';
  @override double   get nodeWidth    => D4mNode._width;

  late List<_D4mPort> _ports;
  final Map<int, AaPayload> _portData = {};

  final OutputPort _out = OutputPort('Out');

  late final TextEditingController _scriptCtrl;
  late final TextEditingController _outSymCtrl;
  final Map<int, TextEditingController> _nameCtrl = {};

  late final FocusNode _scriptFocusNode;
  // macOS Desktop: activating text input sends inactive→resumed, which causes
  // FocusManager._appLifecycleChange to clear focus.  When focus lands on the
  // root scope (not a real widget), we know it was lifecycle-driven and we
  // restore focus on the next resumed event.
  bool _restoreFocusOnResume = false;

  /// Whether the Focus Panel tab exists yet. Only an explicit user action
  /// (double-clicking the script box, or the corner expand icon) sets this;
  /// without the guard, restoring `script` from `initialParams` would throw
  /// the Focus Panel open on load — see `PromptNodeWidget`'s identical guard.
  bool _editorMounted = false;

  D4mExecResult? _lastExec;
  String? _outputHandleId;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely stop
  /// watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state — this is what makes a stale
  /// result harmless even though the abort itself is synchronous, not
  /// dependent on this check.
  int _execGen = 0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    final p = widget.initialParams ?? {};

    // Restore port names from params (comma-separated); default = 1 port "A".
    final names = (p['portNames'] ?? 'A')
        .split(',')
        .where((s) => s.isNotEmpty)
        .toList();
    _ports = names.map((n) => _D4mPort(n)).toList();

    _scriptCtrl = TextEditingController(text: p['script'] ?? '');
    _outSymCtrl = TextEditingController(text: p['outputSymbol'] ?? 'Out');

    WidgetsBinding.instance.addObserver(this);

    _scriptFocusNode = FocusNode(debugLabel: 'D4M-script');
    _scriptFocusNode.addListener(() {
      if (_scriptFocusNode.hasFocus) {
        _restoreFocusOnResume = false;
      } else {
        // Focus going to the root scope means no real widget claimed it —
        // this is the macOS lifecycle bounce, not intentional user navigation.
        final pf = FocusManager.instance.primaryFocus;
        _restoreFocusOnResume =
            pf == null || pf == FocusManager.instance.rootScope;
        debugPrint('[D4M-diag] focus lost → restoreOnResume=$_restoreFocusOnResume  '
            'primaryFocus=${pf?.debugLabel}');
      }
    });

    _initPorts();
    widget.onOutputPort?.call(_out);
  }

  void _initPorts() {
    for (var i = 0; i < _ports.length; i++) {
      _nameCtrl[i] = TextEditingController(text: _ports[i].name);
      widget.onPort?.call(i, _ports[i].inputPort);
      _listenPort(_ports[i]);
    }
  }

  /// Looks up [port]'s *current* list position on each arrival rather than
  /// capturing a fixed index at listener-registration time — removing an
  /// earlier port shifts every later one down, and a captured index would
  /// silently go stale, writing arrived data under the wrong key.
  void _listenPort(_D4mPort port) {
    port.inputPort.onDataArrived.listen((payload) {
      if (!mounted) return;
      final idx = _ports.indexOf(port);
      if (idx < 0) return; // removed since this arrival was queued
      setState(() => _portData[idx] = payload);
      maybeAutoFire();
    });
  }

  @override
  void dispose() {
    for (final p in _ports) {
      p.inputPort.dispose();
    }
    _out.dispose();
    _scriptCtrl.dispose();
    _outSymCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _scriptFocusNode.dispose();
    for (final c in _nameCtrl.values) {
      c.dispose();
    }
    _execClient?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[D4M-diag] lifecycle → $state  restoreOnResume=$_restoreFocusOnResume');
    // macOS Desktop sends inactive→hidden (not inactive→resumed) when the
    // text input system activates.  Restore on hidden so Flutter queues the
    // focus request; when the window becomes key again the text input fires.
    if ((state == AppLifecycleState.resumed ||
            state == AppLifecycleState.hidden) &&
        _restoreFocusOnResume) {
      _restoreFocusOnResume = false;
      if (mounted) _scriptFocusNode.requestFocus();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _restoreFocusOnResume = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Port management
  // ---------------------------------------------------------------------------

  void _addPort() {
    setState(() {
      final idx = _ports.length;
      final name = String.fromCharCode('A'.codeUnitAt(0) + idx);
      final port = _D4mPort(name.length == 1 ? name : 'p$idx');
      _ports.add(port);
      _nameCtrl[idx] = TextEditingController(text: _ports.last.name);
      widget.onPort?.call(idx, port.inputPort);
      _listenPort(port);
    });
    _saveParams();
    // A newly-added, unsatisfied port can only ever make isReady FALSE, never
    // true — but calling this consistently at every port-management mutation
    // point avoids re-deriving that reasoning by hand at each call site.
    maybeAutoFire();
  }

  void _removePort(int idx) {
    if (_ports.length <= 1) return;
    setState(() {
      _ports[idx].inputPort.dispose();
      _ports.removeAt(idx);
      _nameCtrl.remove(idx)?.dispose();
      _portData.remove(idx);
      // Shift everything above the removed slot down by one — the name
      // controller, any arrived data, AND re-notify the canvas of each
      // surviving port's new index. The re-notify is required: the canvas's
      // registry is index-keyed too, and nothing else tells it a port's
      // *rendered* connector index just changed (only [_listenPort]'s live
      // lookup self-corrects; `onPort` does not).
      for (var i = idx; i < _ports.length; i++) {
        _nameCtrl[i] = _nameCtrl.remove(i + 1) ??
            TextEditingController(text: _ports[i].name);
        final shifted = _portData.remove(i + 1);
        if (shifted != null) {
          _portData[i] = shifted;
        } else {
          _portData.remove(i);
        }
        widget.onPort?.call(i, _ports[i].inputPort);
      }
    });
    _saveParams();
    // Removing an unsatisfied port can flip readiness from false to true.
    maybeAutoFire();
  }

  void _renamePort(int idx, String name) {
    final trimmed = name.trim().isEmpty ? 'p$idx' : name.trim();
    setState(() => _ports[idx].name = trimmed);
    _saveParams();
  }

  // ---------------------------------------------------------------------------
  // Params persistence
  // ---------------------------------------------------------------------------

  void _saveParams() {
    saveParams({
      'portNames': _ports.map((p) => p.name).join(','),
      'script': _scriptCtrl.text,
      'outputSymbol': _outSymCtrl.text,
    });
  }

  // ---------------------------------------------------------------------------
  // Wait/Execute readiness
  // ---------------------------------------------------------------------------

  bool get _allPortsSatisfied {
    for (var i = 0; i < _ports.length; i++) {
      if (!_portData.containsKey(i)) return false;
    }
    return true;
  }

  @override
  bool get isReady => _scriptCtrl.text.trim().isNotEmpty && _allPortsSatisfied;

  // ---------------------------------------------------------------------------
  // Execute / Cancel
  // ---------------------------------------------------------------------------

  @override
  void fire() => _execute();

  Future<void> _execute() async {
    if (!isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final owns = widget.api.client == null;
    final client = widget.api.client ?? http.Client();
    _execClient = client;
    final api =
        owns ? D4mApi(baseUrl: widget.api.baseUrl, client: client) : widget.api;

    try {
      // Ingest each port's AA that has data.
      final inputHandles = <String, String>{};
      for (var i = 0; i < _ports.length; i++) {
        final data = _portData[i];
        if (data == null) continue;
        final ingest = await api.ingest(data);
        if (gen != _execGen) return; // cancelled — state is already idle
        _ports[i].handleId = ingest.handleId;
        inputHandles[_ports[i].name] = ingest.handleId;
      }

      final execResult = await api.exec(
        inputs: inputHandles,
        script: _scriptCtrl.text.trim(),
        outputSymbol: _outSymCtrl.text.trim().isEmpty
            ? 'Out'
            : _outSymCtrl.text.trim(),
      );
      if (gen != _execGen || !mounted) return;
      _lastExec = execResult;
      _outputHandleId = execResult.handleId;

      // Emit first 10 000 triples on the port bus.
      final preview = await api.preview(
        handleId: execResult.handleId,
        page: 0,
        pageSize: 10000,
      );
      if (gen != _execGen || !mounted) return;
      _out.emit(preview.aa);
      setComplete(
        detail: '${execResult.numRows}×${execResult.numCols}  '
            'nnz=${execResult.nnz}',
      );
      _saveParams();
    } catch (e) {
      if (gen != _execGen || !mounted) return; // discard a cancelled run's error
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard abort:
  /// state flips to idle synchronously, right here, not after any awaited
  /// step notices a flag. `_execGen` guards the in-flight run's own awaits
  /// against then clobbering that idle state if the request still resolves
  /// in the background.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  // ---------------------------------------------------------------------------
  // Focus Panel — script editor bidirectional sync
  // ---------------------------------------------------------------------------

  void _openEditor() {
    _editorMounted = true;
    _republishEditor();
    widget.onView?.call(widget.node.id);
  }

  /// Refresh the Focus Panel tab's subtitle. The editor itself needs no push —
  /// it holds the live controller — but the subtitle is a snapshot.
  ///
  /// No-op until the tab exists, so state changes never conjure the panel.
  void _republishEditor() {
    if (!_editorMounted) return;
    widget.onContent?.call(
      widget.node.id,
      FocusContent.promptEditor(_scriptCtrl, subtitle: _scriptSummary),
    );
  }

  String get _scriptSummary {
    final lines =
        _scriptCtrl.text.isEmpty ? 0 : _scriptCtrl.text.split('\n').length;
    final shape = _lastExec != null
        ? ' · ${_lastExec!.numRows}×${_lastExec!.numCols}'
        : '';
    return '$lines line${lines == 1 ? '' : 's'}$shape';
  }

  // ---------------------------------------------------------------------------
  // Build overrides
  // ---------------------------------------------------------------------------

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        for (var i = 0; i < _ports.length; i++)
          InputConnector(
            label: _ports[i].name,
            idx: i,
            active: widget.connectedAt?.call(i) ?? false,
            onConnect: (src) => widget.onConnect?.call(src, i),
          ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'Out',
          idx: 0,
          active: _outputHandleId != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Port management ---
        _portManagementSection(theme),
        const Divider(height: 12, thickness: 0.5),

        // --- Script editor ---
        //
        // The expand icon is a Stack SIBLING of the double-tap detector, not
        // a descendant of it: nesting an IconButton inside a
        // GestureDetector.onDoubleTap subtree puts both recognizers in the
        // same gesture arena, and a single tap on the icon can be held for
        // the double-tap timeout before resolving. Keeping them disjoint
        // means each area resolves its own gesture with no competition.
        Stack(
          children: [
            GestureDetector(
              onDoubleTap: _openEditor,
              child: TextField(
                controller: _scriptCtrl,
                focusNode: _scriptFocusNode,
                minLines: 6,
                maxLines: 16,
                scrollPhysics: const ClampingScrollPhysics(),
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Julia D4M Script',
                  hintText: 'Out = A + B\nOut = Out[sw"chunk:", :]',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onChanged: (v) {
                  setState(() {});
                  _saveParams();
                  _republishEditor();
                  maybeAutoFire();
                },
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                onPressed: _openEditor,
                icon: const Icon(Icons.open_in_full, size: 14),
                tooltip: 'Expand Editor',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        // --- Output symbol ---
        Row(
          children: [
            Text('Out: ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace')),
            Expanded(
              child: TextField(
                controller: _outSymCtrl,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  hintText: 'Out',
                ),
                onChanged: (_) => _saveParams(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // --- Wait / Execute ---
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),

        // --- Adjacent node buttons ---
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: widget.onAddLeft,
              icon: const Icon(Icons.arrow_back, size: 14),
              label: const Text('+'),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                textStyle: theme.textTheme.labelSmall,
              ),
            ),
            if (widget.inMergeSet || widget.canMerge)
              _mergeButton(theme, theme.colorScheme),
            TextButton(
              onPressed: widget.onAddRight,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                textStyle: theme.textTheme.labelSmall,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('+'),
                  SizedBox(width: 2),
                  Icon(Icons.arrow_forward, size: 14),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // --- Status row ---
        statusRow(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-builders
  // ---------------------------------------------------------------------------

  Widget _portManagementSection(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _ports.length; i++) _portRow(i, theme),
        // Add port button
        SizedBox(
          height: kPortSpacing,
          child: Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: _addPort,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('+',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _portRow(int i, ThemeData theme) {
    final scheme = theme.colorScheme;
    final hasData = _portData.containsKey(i);
    return SizedBox(
      height: kPortSpacing,
      child: Row(
        children: [
          // Editable name
          Expanded(
            child: TextField(
              controller: _nameCtrl[i],
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 2),
              ),
              onChanged: (v) => _renamePort(i, v),
            ),
          ),
          // Data status dot
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasData ? Colors.green : scheme.outline,
            ),
          ),
          // Remove button (only when >1 port)
          if (_ports.length > 1)
            InkWell(
              onTap: () => _removePort(i),
              borderRadius: BorderRadius.circular(4),
              child: Icon(Icons.close, size: 13, color: scheme.outline),
            ),
        ],
      ),
    );
  }

  Widget _mergeButton(ThemeData theme, ColorScheme scheme) {
    return OutlinedButton(
      onPressed: widget.inMergeSet
          ? (widget.canMerge ? widget.onMerge : widget.onToggleMerge)
          : widget.onToggleMerge,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        textStyle: theme.textTheme.labelSmall,
        foregroundColor:
            widget.inMergeSet ? scheme.primary : scheme.onSurface,
        side: widget.inMergeSet
            ? BorderSide(color: scheme.primary)
            : null,
      ),
      child: Text(
        widget.inMergeSet
            ? (widget.canMerge ? 'Merge' : 'Selected')
            : 'Select',
      ),
    );
  }
}
