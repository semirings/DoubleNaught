import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/review_api.dart';
import '../../../services/storage_service.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A human-in-the-loop curation node (AA-in → AA-out, per `DESIGN.md`) that sits
/// between [ChunkNode] and [Aa2JsonlNode]. It presents candidate passages one at
/// a time; the reviewer **approves**, **edits**, or **rejects** each. Approved
/// and edited passages flow downstream via the `curated` output; rejected ones
/// are dropped from the forwarded stream (but retained in the backend's audit
/// AA).
///
/// Review state is persisted server-side (keyed by content), so a session
/// survives interruption. The node remembers its `reviewId` locally (via
/// [StorageService]) and resumes on re-mount. Keyboard shortcuts `a` / `r`
/// approve / reject the current passage for fast review.
class ReviewNode extends StatefulWidget {
  /// Wider than the default node so passage text is readable.
  static const double _width = 320;

  final WorkflowNode node;

  /// Upstream AA stream wired into the input, or null when nothing is connected.
  final Stream<AaPayload>? aaInput;

  /// Called with the source endpoint when an edge is dropped on the input port.
  final void Function(PortRef source)? onInputConnect;

  /// Called once with the node's output stream — the `curated` connector.
  final void Function(Stream<AaPayload> curated)? onConnect;

  /// Output port indices with an outgoing edge — drives the connected highlight.
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final ReviewApi api;

  /// Local persistence for the resumable `reviewId`.
  final StorageService storage;

  ReviewNode({
    super.key,
    required this.node,
    this.aaInput,
    this.onInputConnect,
    this.onConnect,
    this.connectedOutputs = const {},
    this.api = const ReviewApi(),
    StorageService? storage,
  }) : storage = storage ?? StorageService();

  @override
  State<ReviewNode> createState() => _ReviewNodeState();
}

class _ReviewNodeState extends State<ReviewNode> {
  StreamSubscription<AaPayload>? _inputSub;
  AaPayload? _incoming;

  ReviewSession? _session;
  int _index = 0;

  bool _editing = false;
  final TextEditingController _editController = TextEditingController();

  bool _busy = false;
  String? _error;

  late final StreamController<AaPayload> _output;
  AaPayload? _lastOutput;

  final FocusNode _focusNode = FocusNode(debugLabel: 'reviewNode');

  String get _storageKey => 'review_${widget.node.id}';

  @override
  void initState() {
    super.initState();
    _output = StreamController<AaPayload>.broadcast(onListen: _replayLast);
    widget.onConnect?.call(_output.stream);
    _subscribeInput();
    _tryResumeFromStorage();
  }

  @override
  void didUpdateWidget(ReviewNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aaInput != widget.aaInput) _subscribeInput();
  }

  @override
  void dispose() {
    _inputSub?.cancel();
    _editController.dispose();
    _focusNode.dispose();
    _output.close();
    super.dispose();
  }

  void _replayLast() {
    final payload = _lastOutput;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(payload);
    });
  }

  void _subscribeInput() {
    _inputSub?.cancel();
    _inputSub = widget.aaInput?.listen((payload) {
      if (!mounted) return;
      setState(() => _incoming = payload);
      _startReview(payload);
    });
  }

  /// Resume a saved session on (re)mount — before any upstream re-emits.
  Future<void> _tryResumeFromStorage() async {
    if (_session != null) return;
    try {
      final record = await widget.storage.read(_storageKey);
      final reviewId = record?['reviewId'] as String?;
      if (reviewId == null || _session != null) return;
      final session = await widget.api.session(reviewId);
      if (!mounted) return;
      _applySession(session);
    } catch (_) {
      // No saved session, or backend offline — nothing to resume.
    }
  }

  Future<void> _startReview(AaPayload aa) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.api.start(aa);
      if (!mounted) return;
      try {
        await widget.storage.write(_storageKey, {'reviewId': session.reviewId});
      } catch (_) {
        // dart:io unavailable (web) or write failed — resume still works while
        // the app stays open; ignore.
      }
      _applySession(session);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applySession(ReviewSession session) {
    setState(() {
      _session = session;
      _index = _firstPending(session, 0);
      _error = null;
    });
    if (session.complete) {
      _emitOutput(session.reviewId);
    } else {
      _requestFocusSoon();
    }
  }

  Future<void> _decide(String status, {String? editedText}) async {
    final session = _session;
    if (session == null || _busy) return;
    if (_index < 0 || _index >= session.passages.length) return;
    final passage = session.passages[_index];

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.api.decide(
        reviewId: session.reviewId,
        chunkId: passage.chunkId,
        status: status,
        editedText: editedText,
      );
      if (!mounted) return;
      setState(() {
        _session = updated;
        _editing = false;
        _index = _firstPending(updated, _index + 1);
      });
      if (updated.complete) {
        await _emitOutput(updated.reviewId);
      } else {
        _requestFocusSoon();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _emitOutput(String reviewId) async {
    try {
      final full = await widget.api.output(reviewId);
      final forwarded = _forwardable(full);
      if (!mounted) return;
      _lastOutput = forwarded;
      _output.add(forwarded);
      setState(() {}); // refresh the output-port highlight
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Keep only rows whose `review_status` flows downstream (approved / edited).
  AaPayload _forwardable(AaPayload full) {
    final statusByRow = <String, String>{};
    for (var i = 0; i < full.cols.length; i++) {
      if (full.cols[i] == 'review_status') {
        statusByRow[full.rows[i]] = full.vals[i].toString();
      }
    }
    const forwarded = {'approved', 'edited'};
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];
    for (var i = 0; i < full.cols.length; i++) {
      if (forwarded.contains(statusByRow[full.rows[i]])) {
        rows.add(full.rows[i]);
        cols.add(full.cols[i]);
        vals.add(full.vals[i]);
      }
    }
    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  /// First pending passage at or after [from]; wraps to the start; else clamps.
  int _firstPending(ReviewSession session, int from) {
    final n = session.passages.length;
    for (var i = from; i < n; i++) {
      if (session.passages[i].isPending) return i;
    }
    for (var i = 0; i < from && i < n; i++) {
      if (session.passages[i].isPending) return i;
    }
    return n == 0 ? 0 : (from.clamp(0, n - 1));
  }

  void _requestFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_editing) _focusNode.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_editing || _busy || _session == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      _decide('approved');
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _decide('rejected');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startEdit(ReviewPassage passage) {
    setState(() {
      _editing = true;
      _editController.text = passage.editedText ?? passage.text;
    });
  }

  void _cancelEdit() {
    setState(() => _editing = false);
    _requestFocusSoon();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wired = widget.aaInput != null;
    final session = _session;
    final hasOutput = _lastOutput != null;

    final Widget body;
    if (session == null) {
      body = _preSessionBody(theme, wired);
    } else if (session.complete) {
      body = _completeBody(theme, session);
    } else {
      body = _reviewingBody(theme, session);
    }

    return DoubleNaughtNodeWrapper(
      title: 'Review',
      icon: Icons.rate_review_outlined,
      width: ReviewNode._width,
      inputPorts: [
        InputConnector(
          label: 'chunks',
          idx: 0,
          active: wired,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'curated',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: body,
    );
  }

  Widget _preSessionBody(ThemeData theme, bool wired) {
    if (_busy) {
      return Row(
        children: [
          const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Starting review…', style: theme.textTheme.bodySmall),
        ],
      );
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _errorText(theme),
          if (_incoming != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _startReview(_incoming!),
              child: const Text('Retry'),
            ),
          ],
        ],
      );
    }
    return Text(
      wired ? 'Waiting for chunks…' : 'Connect a Chunk node',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget _reviewingBody(ThemeData theme, ReviewSession session) {
    final passage = session.passages[_index];
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _focusNode.requestFocus(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _progress(theme, session),
            const SizedBox(height: 8),
            _passageCard(theme, passage),
            const SizedBox(height: 10),
            if (_editing) _editControls(theme) else _actionControls(theme),
            if (_error != null) ...[
              const SizedBox(height: 8),
              _errorText(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progress(ThemeData theme, ReviewSession session) {
    final c = session.counts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Passage ${_index + 1} / ${c.total}',
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          '✓ ${c.approved}   ✎ ${c.edited}   ✗ ${c.rejected}   ·   ${c.pending} left',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _passageCard(ThemeData theme, ReviewPassage passage) {
    final scheme = theme.colorScheme;
    final displayText = passage.editedText ?? passage.text;
    final facts = <String>[
      if (passage.author.isNotEmpty) passage.author,
      if (passage.workTitle.isNotEmpty) passage.workTitle,
      'pos ${passage.position}',
      '${passage.tokenCount} tok',
      if (passage.chunkStrategy.isNotEmpty) passage.chunkStrategy,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: Text(displayText, style: theme.textTheme.bodySmall),
            ),
          ),
          const Divider(height: 14),
          Text(
            facts.join('  •  '),
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _actionControls(ThemeData theme) {
    final passage = _session!.passages[_index];
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _decide('approved'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.green),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Approve'),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          onPressed: _busy ? null : () => _startEdit(passage),
          child: const Icon(Icons.edit_outlined, size: 16),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _decide('rejected'),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Reject'),
          ),
        ),
      ],
    );
  }

  Widget _editControls(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _editController,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          style: theme.textTheme.bodySmall,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(10),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _decide('edited', editedText: _editController.text),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('Save'),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: _busy ? null : _cancelEdit,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _completeBody(ThemeData theme, ReviewSession session) {
    final c = session.counts;
    final forwarded = c.approved + c.edited;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
            const SizedBox(width: 6),
            Text('Review complete',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${c.total} passages · ✓ ${c.approved}  ✎ ${c.edited}  ✗ ${c.rejected}',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          '$forwarded forwarded downstream · ${c.rejected} rejected (retained for audit)',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          _errorText(theme),
        ],
      ],
    );
  }

  Widget _errorText(ThemeData theme) => Text(
        'Error: $_error',
        style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
      );
}
