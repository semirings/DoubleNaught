import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../services/infobus/input_port.dart';
import '../../focus_panel.dart' show FocusContent;
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/input_connector.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// A universal **display** sink. It has one input — a `previewData` port (a D4M
/// associative array) — and renders whatever arrives in the right-hand
/// **Focus Panel** (as a tab), *not* inside the node. The node itself stays a
/// compact routing box showing a one-line summary plus the standard
/// Wait/Execute/status trio (`UX_UI/GLOBAL_UX_CONTRACT.md` §§2–3, 5) — Preview
/// is not an exception to that mechanism (see `UX_UI/build_preview.py`'s v3
/// revision note).
class PreviewNode extends BaseNodeWidget {
  /// Filename of the byte source, when known (carried out-of-band).
  final String? fileName;

  /// Pushes decoded content to the Focus Panel as this node's tab.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Retracts this node's Focus Panel tab when its inputs go dead.
  final void Function(int nodeId)? onContentCleared;

  const PreviewNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    this.fileName,
    this.onContent,
    this.onContentCleared,
  });

  @override
  State<PreviewNode> createState() => _PreviewNodeState();
}

class _PreviewNodeState extends BaseNodeState<PreviewNode>
    with WaitGatedExecution<PreviewNode> {
  @override String   get nodeTitle => 'Preview';
  @override IconData get nodeIcon  => Icons.preview_outlined;

  final InputPort _in = InputPort('previewData');

  /// Arrived but not yet published — differs from [_aa] only while gated
  /// (Wait checked) and not yet fired.
  AaPayload? _pending;

  /// Published — what the Focus Panel tab and the summary reflect.
  AaPayload? _aa;

  @override
  bool get isReady => _pending != null;

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onAa);
    _in.onDisconnected.listen((_) => _dropAa());
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _onAa(AaPayload payload) {
    if (!mounted) return;
    setState(() => _pending = payload);
    maybeAutoFire();
  }

  /// Publish [_pending] — reactive nodes never see an intermediate "working"
  /// frame: there is no async step here, so faking one would misrepresent
  /// real backend state (`UX_UI/GLOBAL_UX_CONTRACT.md` §5).
  @override
  void fire() {
    setState(() => _aa = _pending);
    widget.onContent?.call(widget.node.id, _buildContent()!);
    setComplete();
  }

  /// Drop the retained AA when the `previewData` wire is cut or re-pointed, so
  /// the node stops advertising an upstream it is no longer fed by.
  ///
  /// Re-pointing emits the departure and then immediately replays the new
  /// upstream's retained payload, so this clears only when the new source has
  /// nothing to give.
  void _dropAa() {
    if (!mounted || (_aa == null && _pending == null)) return;
    setState(() {
      _aa = null;
      _pending = null;
    });
    setIdle();
    widget.onContentCleared?.call(widget.node.id);
  }

  FocusContent? _buildContent() {
    if (_aa != null) {
      final rows = _aa!.distinctRows().length;
      final cols = _distinctColCount(_aa!);
      return FocusContent.aa(_aa!, subtitle: '$rows rows × $cols cols');
    }
    return null;
  }

  int _distinctColCount(AaPayload aa) {
    final seen = <String>{};
    for (final c in aa.cols) { seen.add(c); }
    return seen.length;
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'previewData',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
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
        const SizedBox(height: 28),
        _summary(theme),
        const SizedBox(height: 10),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          onPressed: onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  Widget _summary(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final kind = _aa != null
        ? 'AA · ${_aa!.distinctRows().length} rows × '
            '${_distinctColCount(_aa!)} cols'
        : 'Waiting for data…';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.fileName ?? 'Received content',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(kind,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
      ],
    );
  }
}
