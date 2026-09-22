import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/category_store.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// A **source node** that loads the category set from
/// `storage/categories/categories.json` and emits it as an [AaPayload] on its
/// `categoriesOut` port — the AA that ModelClassifier's `categoryIn` consumes
/// (rows = `cat:<id>`, cols = `label` / `hypothesis_template` / `threshold`).
///
/// It emits once on load, and the [OutputPort] retains that payload so a
/// classifier wired up later replays it immediately. **Reload** re-reads the
/// file and re-emits, propagating edits without recreating the node.
class CategoriesNode extends BaseNodeWidget {
  static const double _width = 300;

  /// AA-native category store. Injectable for tests; defaults to
  /// `storage/categories/categories.json`.
  final CategoryStore? store;

  const CategoriesNode({
    super.key,
    required super.node,
    super.onOutputPort,
    super.connectedOutputs,
    this.store,
  });

  @override
  State<CategoriesNode> createState() => _CategoriesNodeState();
}

class _CategoriesNodeState extends BaseNodeState<CategoriesNode> {
  @override String   get nodeTitle => 'Categorize';
  @override IconData get nodeIcon  => Icons.label_outline;
  @override double   get nodeWidth => CategoriesNode._width;

  late final CategoryStore _store = widget.store ?? CategoryStore();

  final OutputPort _out = OutputPort('categoriesOut');

  bool       _loading    = true;
  String?    _error;
  AaPayload? _categories;

  List<String> get _labels =>
      _categories == null ? const [] : CategoryStore.labelsOf(_categories!);

  @override
  void initState() {
    super.initState();
    initOutputPort(_out);
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
      _error   = null;
    });
    try {
      final aa = await _store.load();
      if (!mounted) return;
      setState(() => _categories = aa);
      if (aa.cols.isNotEmpty) _out.emit(aa);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'categoriesOut',
          idx: 0,
          active: (_categories?.cols.isNotEmpty ?? false) ||
              widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _summary(theme, muted),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading ? busyIcon() : const Icon(Icons.refresh, size: 18),
            label: const Text('Reload'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline, size: 14,
                  color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _error!.replaceAll('\n', ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ],
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
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(labels.join(', '), maxLines: 3, overflow: TextOverflow.ellipsis,
            style: muted),
      ],
    );
  }
}
