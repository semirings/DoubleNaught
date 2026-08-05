import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/category_store.dart';
import '../../../services/infobus/output_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/output_connector.dart';

/// A **source node** that loads the category set from
/// `storage/categories/categories.json` and emits it as an [AaPayload] on its
/// `categoriesOut` port — the AA that ModelClassifier's `categoryIn` consumes
/// (rows = `cat:<id>`, cols = `label` / `hypothesis_template` / `threshold`).
///
/// It emits once on load, and the [OutputPort] retains that payload so a
/// classifier wired up later replays it immediately. **Reload** re-reads the
/// file and re-emits, propagating edits without recreating the node.
class CategoriesNode extends StatefulWidget {
  static const double _width = 300;

  final WorkflowNode node;

  /// Registers this node's egress OutputPort with the canvas bridge.
  final void Function(OutputPort port)? onOutputPort;

  /// Output port indices with an outgoing edge — drives the connected-port
  /// highlight, matching every other node.
  final Set<int> connectedOutputs;

  /// AA-native category store. Injectable for tests; defaults to
  /// `storage/categories/categories.json`.
  final CategoryStore? store;

  const CategoriesNode({
    super.key,
    required this.node,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.store,
  });

  @override
  State<CategoriesNode> createState() => _CategoriesNodeState();
}

class _CategoriesNodeState extends State<CategoriesNode> {
  late final CategoryStore _store = widget.store ?? CategoryStore();

  final OutputPort _out = OutputPort('categoriesOut');

  bool _loading = true;
  String? _error;
  AaPayload? _categories;

  List<String> get _labels =>
      _categories == null ? const [] : CategoryStore.labelsOf(_categories!);

  @override
  void initState() {
    super.initState();
    widget.onOutputPort?.call(_out);
    _load();
  }

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final aa = await _store.load();
      if (!mounted) return;
      setState(() => _categories = aa);
      // Emit so a downstream categoryIn (wired now or later) receives the set.
      if (aa.cols.isNotEmpty) _out.emit(aa);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final hasOutput = _categories != null && _categories!.cols.isNotEmpty;

    return DoubleNaughtNodeWrapper(
      title: 'Categories',
      icon: Icons.label_outline,
      width: CategoriesNode._width,
      outputPorts: [
        OutputConnector(
          label: 'categoriesOut',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(theme, muted),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: const Text('Reload'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!.replaceAll('\n', ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary(ThemeData theme, TextStyle? muted) {
    if (_loading && _categories == null) {
      return Text('Loading categories…', style: muted);
    }
    final labels = _labels;
    if (labels.isEmpty) {
      return Text(
        'No categories in storage/categories/categories.json.',
        style: muted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${labels.length} categor${labels.length == 1 ? 'y' : 'ies'}',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          labels.join(', '),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
      ],
    );
  }
}
