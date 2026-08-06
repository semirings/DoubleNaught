import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/d4m_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node.dart' show kPortSpacing;
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

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
// Status
// ---------------------------------------------------------------------------

enum _D4mStatus { idle, busy, complete, error }

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// A **functional node** (AA-in → AA-out) that executes a multi-line D4M/Julia
/// script over dynamically-managed input ports.
///
/// * Input ports default to 1, expandable via the `+` button; each supports
///   inline rename.
/// * Execute: ingests each port's AA into server-side handles, runs the script,
///   stores output handle, emits the first 10 000 triples on the port bus.
/// * Preview: paginated AA table modal.
/// * Left/Right: spawn adjacent D4M nodes.
/// * Merge: combine selected D4M nodes' scripts.
class D4mNode extends StatefulWidget {
  static const double _width = 340;

  final WorkflowNode node;
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  // Dynamic port callbacks — index-based.
  final void Function(int idx, InputPort port)? onPort;
  final bool Function(int idx)? connectedAt;
  final void Function(PortRef source, int idx)? onConnect;

  // Output port.
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  // Adjacent-node spawning.
  final VoidCallback? onAddLeft;
  final VoidCallback? onAddRight;

  // Merge controls.
  final bool inMergeSet;
  final VoidCallback? onToggleMerge;
  final bool canMerge;
  final VoidCallback? onMerge;

  final D4mApi api;

  const D4mNode({
    super.key,
    required this.node,
    this.initialParams,
    this.onParams,
    this.onPort,
    this.connectedAt,
    this.onConnect,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.onAddLeft,
    this.onAddRight,
    this.inMergeSet = false,
    this.onToggleMerge,
    this.canMerge = false,
    this.onMerge,
    this.api = const D4mApi(),
  });

  @override
  State<D4mNode> createState() => _D4mNodeState();
}

class _D4mNodeState extends State<D4mNode> with WidgetsBindingObserver {
  late List<_D4mPort> _ports;
  final Map<int, AaPayload> _portData = {};

  final OutputPort _out = OutputPort('aaOut');

  late final TextEditingController _scriptCtrl;
  late final TextEditingController _outSymCtrl;
  final Map<int, TextEditingController> _nameCtrl = {};

  late final FocusNode _scriptFocusNode;
  // macOS Desktop: activating text input sends inactive→resumed, which causes
  // FocusManager._appLifecycleChange to clear focus.  When focus lands on the
  // root scope (not a real widget), we know it was lifecycle-driven and we
  // restore focus on the next resumed event.
  bool _restoreFocusOnResume = false;

  _D4mStatus _status = _D4mStatus.idle;
  String? _error;
  D4mExecResult? _lastExec;
  String? _outputHandleId;
  bool _cancelled = false;
  bool _previewOpen = false;

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
      final idx = i;
      _ports[i].inputPort.onDataArrived.listen((payload) {
        if (!mounted) return;
        setState(() => _portData[idx] = payload);
      });
    }
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
      port.inputPort.onDataArrived.listen((payload) {
        if (!mounted) return;
        setState(() => _portData[idx] = payload);
      });
    });
    _saveParams();
  }

  void _removePort(int idx) {
    if (_ports.length <= 1) return;
    setState(() {
      _ports[idx].inputPort.dispose();
      _ports.removeAt(idx);
      _nameCtrl.remove(idx);
      _portData.remove(idx);
      // Re-index controllers above the removed slot.
      for (var i = idx; i < _ports.length; i++) {
        _nameCtrl[i] = _nameCtrl.remove(i + 1) ??
            TextEditingController(text: _ports[i].name);
      }
    });
    _saveParams();
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
    widget.onParams?.call({
      'portNames': _ports.map((p) => p.name).join(','),
      'script': _scriptCtrl.text,
      'outputSymbol': _outSymCtrl.text,
    });
  }

  // ---------------------------------------------------------------------------
  // Execute
  // ---------------------------------------------------------------------------

  bool get _canExec =>
      _scriptCtrl.text.trim().isNotEmpty &&
      _status != _D4mStatus.busy &&
      _portData.isNotEmpty;

  void _cancel() {
    _cancelled = true;
    setState(() {
      _status = _D4mStatus.idle;
      _error = null;
    });
  }

  Future<void> _execute() async {
    if (!_canExec) return;
    _cancelled = false;
    setState(() {
      _status = _D4mStatus.busy;
      _error = null;
    });
    try {
      // Ingest each port's AA that has data.
      final inputHandles = <String, String>{};
      for (var i = 0; i < _ports.length; i++) {
        if (_cancelled) return;
        final data = _portData[i];
        if (data == null) continue;
        final ingest = await widget.api.ingest(data);
        if (_cancelled) return;
        _ports[i].handleId = ingest.handleId;
        inputHandles[_ports[i].name] = ingest.handleId;
      }

      if (_cancelled) return;
      final execResult = await widget.api.exec(
        inputs: inputHandles,
        script: _scriptCtrl.text.trim(),
        outputSymbol: _outSymCtrl.text.trim().isEmpty
            ? 'Out'
            : _outSymCtrl.text.trim(),
      );

      if (!mounted || _cancelled) return;
      _lastExec = execResult;
      _outputHandleId = execResult.handleId;

      // Emit first 10 000 triples on the port bus.
      final preview = await widget.api.preview(
        handleId: execResult.handleId,
        page: 0,
        pageSize: 10000,
      );
      if (!mounted || _cancelled) return;
      _out.emit(preview.aa);
      setState(() => _status = _D4mStatus.complete);
      _saveParams();
    } catch (e) {
      if (!mounted || _cancelled) return;
      final msg = '$e';
      final friendly =
          msg.contains(': ') ? msg.split(': ').skip(1).join(': ') : msg;
      setState(() {
        _status = _D4mStatus.error;
        _error = friendly;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Preview modal
  // ---------------------------------------------------------------------------

  void _showPreview() {
    final hid = _outputHandleId;
    if (hid == null) return;
    if (_previewOpen) return; // already on top (modal)
    setState(() => _previewOpen = true);
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _PreviewDialog(api: widget.api, handleId: hid),
    ).whenComplete(() {
      if (mounted) setState(() => _previewOpen = false);
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasOutput = _outputHandleId != null;

    return DoubleNaughtNodeWrapper(
      title: 'D4M',
      icon: Icons.functions,
      width: D4mNode._width,
      inputPorts: [
        for (var i = 0; i < _ports.length; i++)
          InputConnector(
            label: _ports[i].name,
            idx: i,
            active: widget.connectedAt?.call(i) ?? false,
            onConnect: (src) => widget.onConnect?.call(src, i),
          ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'aaOut',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Port management ---
          _portManagementSection(theme),
          const Divider(height: 12, thickness: 0.5),

          // --- Script editor ---
          TextField(
            controller: _scriptCtrl,
            focusNode: _scriptFocusNode,
            minLines: 6,
            maxLines: 16,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontFamily: 'monospace'),
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
            },
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

          // --- Execute + Preview ---
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _status == _D4mStatus.busy
                      ? _cancel
                      : (_canExec ? _execute : null),
                  icon: _status == _D4mStatus.busy
                      ? const Icon(Icons.stop_rounded, size: 16)
                      : const Icon(Icons.play_arrow_rounded, size: 16),
                  label: Text(
                      _status == _D4mStatus.busy ? 'Cancel' : 'Execute'),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: _outputHandleId != null ? _showPreview : null,
                icon: Icon(
                  _previewOpen
                      ? Icons.table_view
                      : Icons.table_view_outlined,
                  size: 16,
                ),
                label: const Text('Preview'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  foregroundColor: _previewOpen
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

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
                _mergeButton(theme, scheme),
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
          _statusRow(theme, scheme),
        ],
      ),
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

  Widget _statusRow(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (_status) {
      _D4mStatus.idle => (scheme.outline, 'idle'),
      _D4mStatus.busy => (scheme.primary, 'executing'),
      _D4mStatus.complete => (Colors.green, 'complete'),
      _D4mStatus.error => (scheme.error, 'error'),
    };
    final meta = _lastExec != null
        ? '  ${_lastExec!.numRows}×${_lastExec!.numCols}  nnz=${_lastExec!.nnz}'
        : '';
    final detail = _status == _D4mStatus.error && _error != null
        ? ' · $_error'
        : meta;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$label$detail',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Preview dialog
// ---------------------------------------------------------------------------

class _PreviewDialog extends StatefulWidget {
  final D4mApi api;
  final String handleId;

  const _PreviewDialog({required this.api, required this.handleId});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  static const _pageSize = 200;

  int _page = 0;
  D4mPreviewResult? _result;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchPage(0);
  }

  Future<void> _fetchPage(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.preview(
        handleId: widget.handleId,
        page: page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    final totalPages =
        r == null ? 1 : ((r.totalNnz + _pageSize - 1) ~/ _pageSize);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Preview  ${r != null ? "${r.totalNnz} triples" : ""}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (r != null)
                    Text('page ${_page + 1} / $totalPages',
                        style: theme.textTheme.bodySmall),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 28, minHeight: 28),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Table
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Text(_error!,
                              style: TextStyle(
                                  color: theme.colorScheme.error)))
                      : _table(theme, r!.aa),
            ),

            // Pagination
            if (!_loading && _error == null && r != null && totalPages > 1)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed:
                          _page > 0 ? () => _fetchPage(_page - 1) : null,
                      child: const Text('‹ Prev'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _page < totalPages - 1
                          ? () => _fetchPage(_page + 1)
                          : null,
                      child: const Text('Next ›'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _table(ThemeData theme, AaPayload aa) {
    if (aa.rows.isEmpty) {
      return Center(
          child: Text('Empty result',
              style: theme.textTheme.bodySmall));
    }
    return SingleChildScrollView(
      child: DataTable(
        headingRowHeight: 28,
        dataRowMinHeight: 22,
        dataRowMaxHeight: 28,
        columnSpacing: 12,
        columns: const [
          DataColumn(label: Text('row')),
          DataColumn(label: Text('col')),
          DataColumn(label: Text('val')),
        ],
        rows: [
          for (var i = 0; i < aa.rows.length; i++)
            DataRow(cells: [
              DataCell(Text(aa.rows[i],
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'))),
              DataCell(Text(aa.cols[i],
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'))),
              DataCell(Text('${aa.vals[i]}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'))),
            ]),
        ],
      ),
    );
  }
}
