import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/review_api.dart';
import '../../../services/storage_service.dart';
import '../base/base_node_widget.dart';

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
class ReviewNode extends BaseNodeWidget {
  /// Wider than the default node so passage text is readable.
  static const double _width = 320;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final ReviewApi api;

  /// Local persistence for the resumable `reviewId`.
  final StorageService storage;

  ReviewNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const ReviewApi(),
    StorageService? storage,
  }) : storage = storage ?? StorageService();

  @override
  State<ReviewNode> createState() => _ReviewNodeState();
}

class _ReviewNodeState extends BaseNodeState<ReviewNode> {
  @override String   get nodeTitle => 'Review';
  @override IconData get nodeIcon  => Icons.rate_review_outlined;
  @override double   get nodeWidth => ReviewNode._width;

  final InputPort  _in  = InputPort('chunks');
  final OutputPort _out = OutputPort('curated');

  AaPayload? _incoming;

  ReviewSession? _session;
  int _index = 0;

  bool _editing = false;
  final TextEditingController _editController = TextEditingController();

  bool    _busy  = false;
  String? _error;

  AaPayload? _lastOutput;

  final FocusNode _focusNode = FocusNode(debugLabel: 'reviewNode');

  String get _storageKey => 'review_${widget.node.id}';

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
    _tryResumeFromStorage();
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _editController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() => _incoming = payload);
    _startReview(payload);
  }

  /// Resume a saved session on (re)mount — before any upstream re-emits.
  Future<void> _tryResumeFromStorage() async {
    if (_session != null) return;
    try {
      final record   = await widget.storage.read(_storageKey);
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
      _busy  = true;
      _error = null;
    });
    try {
      final session = await widget.api.start(aa);
      if (!mounted) return;
      try {
        await widget.storage.write(_storageKey, {'reviewId': session.reviewId});
      } catch (_) {
        // dart:io unavailable (web) or write failed — ignore; resume still works
        // while the app stays open.
      }
      _applySession(session);
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
    } finally {
      if (mounted) { setState(() => _busy = false); }
    }
  }

  void _applySession(ReviewSession session) {
    setState(() {
      _session = session;
      _index   = _firstPending(session, 0);
      _error   = null;
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
      _busy  = true;
      _error = null;
    });
    try {
      final updated = await widget.api.decide(
        reviewId:   session.reviewId,
        chunkId:    passage.chunkId,
        status:     status,
        editedText: editedText,
      );
      if (!mounted) return;
      setState(() {
        _session = updated;
        _editing = false;
        _index   = _firstPending(updated, _index + 1);
      });
      if (updated.complete) {
        await _emitOutput(updated.reviewId);
      } else {
        _requestFocusSoon();
      }
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
    } finally {
      if (mounted) { setState(() => _busy = false); }
    }
  }

  Future<void> _emitOutput(String reviewId) async {
    try {
      final full      = await widget.api.output(reviewId);
      final forwarded = _forwardable(full);
      if (!mounted) return;
      _lastOutput = forwarded;
      _out.emit(forwarded);
      setState(() {}); // refresh output-port highlight
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
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

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'chunks')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'curated',
          idx: 0,
          hasData: _lastOutput != null,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme   = Theme.of(context);
    final session = _session;
    if (session == null)      return _preSessionBody(theme, widget.inputConnected);
    if (session.complete)     return _completeBody(theme, session);
    return _reviewingBody(theme, session);
  }

  Widget _preSessionBody(ThemeData theme, bool wired) {
    if (_busy) {
      return Row(
        children: [
          const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
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
    final scheme      = theme.colorScheme;
    final displayText = passage.editedText ?? passage.text;
    final facts = <String>[
      if (passage.author.isNotEmpty)        passage.author,
      if (passage.workTitle.isNotEmpty)     passage.workTitle,
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
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
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
            style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
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
    final c         = session.counts;
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
