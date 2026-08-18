import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../focus_panel.dart' show FocusContent;
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';

/// A universal **display** sink. It has one input — a `previewData` port (a D4M
/// associative array) — and renders whatever arrives in the right-hand
/// **Focus Panel** (as a tab), *not* inside the node. The node itself stays a
/// compact routing box showing a one-line summary and a "View in panel" button.
class PreviewNode extends BaseNodeWidget {
  /// Filename of the byte source, when known (carried out-of-band).
  final String? fileName;

  /// Pushes decoded content to the Focus Panel as this node's tab.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Retracts this node's Focus Panel tab when its inputs go dead.
  final void Function(int nodeId)? onContentCleared;

  /// Opens the Focus Panel and selects this node's tab.
  final void Function(int nodeId)? onView;

  const PreviewNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    this.fileName,
    this.onContent,
    this.onContentCleared,
    this.onView,
  });

  @override
  State<PreviewNode> createState() => _PreviewNodeState();
}

class _PreviewNodeState extends BaseNodeState<PreviewNode> {
  @override String   get nodeTitle => 'Preview';
  @override IconData get nodeIcon  => Icons.preview_outlined;

  final InputPort _in = InputPort('previewData');
  AaPayload?      _aa;

  bool get _hasContent => _aa != null;

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
    setState(() => _aa = payload);
    _report();
  }

  /// Drop the retained AA when the `previewData` wire is cut or re-pointed, so the node
  /// stops advertising an upstream it is no longer fed by.
  ///
  /// Re-pointing emits the departure and then immediately replays the new
  /// upstream's retained payload, so this clears only when the new source has
  /// nothing to give.
  void _dropAa() {
    if (!mounted || _aa == null) return;
    setState(() => _aa = null);
    _report();
  }

  /// Push the current content to the Focus Panel — or retract this node's tab
  /// once there is nothing left to show, so a dead payload cannot linger there
  /// after the node summary has cleared.
  void _report() {
    final content = _buildContent();
    if (content != null) {
      widget.onContent?.call(widget.node.id, content);
    } else {
      widget.onContentCleared?.call(widget.node.id);
    }
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        _summary(theme),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed:
                _hasContent ? () => widget.onView?.call(widget.node.id) : null,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('View in panel'),
          ),
        ),
      ],
    );
  }

  Widget _summary(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (!widget.inputConnected) {
      return Text('Connect an AA source', style: muted);
    }

    final String kind;
    if (_aa != null) {
      kind = 'AA · ${_aa!.distinctRows().length} rows × '
          '${_distinctColCount(_aa!)} cols';
    } else {
      kind = 'Waiting for data…';
    }

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
