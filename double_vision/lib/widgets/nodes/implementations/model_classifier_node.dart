import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/category_store.dart';
import '../../../services/classify_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/model_catalog_store.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Vertical space reserved so the three edge-anchored input labels (`aaIn` at
/// idx 0, `modelIn` at idx 1, `categoryIn` at idx 2) clear the body controls.
const double _kPortLaneInset = 60;

/// A **functional node** that runs zero-shot classification over incoming
/// **text** and emits the results as an rcvs.json associative array.
///
/// Inputs:
///  * `aaIn` (AA, idx 0, required) — the document text to classify, typically
///    Chunk's / Inventory's `content` output, read from the AA's `text` column.
///  * `modelIn` (String, idx 1, optional) — a model URL / Hugging Face id /
///    local path that **overrides** the manual field and the dropdown.
///  * `categoryIn` (AA, idx 2, required) — a categories AA (rows = `cat:<id>`,
///    cols = `label` / `hypothesis_template` / `threshold`), typically from a
///    **Categories** node. Its `label` column supplies the candidate categories
///    — replacing what used to be a comma-separated text field — and its
///    templates/thresholds drive the backend classification.
///
/// Model resolution order: `modelIn` → manual field → dropdown selection. A
/// Hugging Face repo id is passed to the runner verbatim; a web/local path is
/// passed as resolved.
///
/// Output `classifiedAaOut` (AA, idx 0): all original chunk triples from
/// `aaIn` plus one `score:<label>` column per category per chunk row (spaces
/// replaced with underscores), and an optional `passed` column per row when
/// the categories carry thresholds.
class ModelClassifierNode extends StatefulWidget {
  static const double _width = 320;

  /// Extracts human-readable category names from AA column names by stripping
  /// the `score:` namespace prefix applied by the backend classifier.
  static List<String> displayCategories(List<String> rawColumns) =>
      rawColumns
          .where((col) => col.startsWith('score:'))
          .map((col) => col.substring('score:'.length))
          .toList();

  /// Extracts score values from a pre-grouped row map (col → val). Returns
  /// bare label → score (0..1); non-score columns are ignored. Useful in
  /// Preview renderers that receive the classified AA row-by-row.
  static Map<String, double> scoresFromRow(Map<String, dynamic> rowMap) {
    final result = <String, double>{};
    rowMap.forEach((key, value) {
      if (key.startsWith('score:')) {
        final label = key.substring('score:'.length);
        result[label] = value is num
            ? value.toDouble()
            : double.tryParse(value.toString()) ?? 0.0;
      }
    });
    return result;
  }

  final WorkflowNode node;

  // aaIn (AA payload) — idx 0
  final bool inputConnected;
  final void Function(PortRef source)? onTextConnect;
  final void Function(InputPort port)? onInputPort;

  // modelIn (String) — idx 1
  final bool modelConnected;
  final void Function(PortRef source)? onModelConnect;
  final Stream<String>? modelInput;

  // categoryIn (AA payload) — idx 2
  final bool categoryConnected;
  final void Function(PortRef source)? onCategoryConnect;
  final void Function(InputPort port)? onCategoryPort;

  // classifiedAaOut (AA) — output idx 0
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  /// AA-native model catalog (`storage/models_rcvs.json`). Injectable for tests.
  final ModelCatalogStore? store;

  /// Classification backend client. Injectable for tests.
  final ClassifyApi api;

  /// Saved settings to restore (selected model, manual path), and a callback to
  /// report them back to the canvas for persistence.
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  const ModelClassifierNode({
    super.key,
    required this.node,
    this.inputConnected = false,
    this.onTextConnect,
    this.onInputPort,
    this.modelConnected = false,
    this.onModelConnect,
    this.modelInput,
    this.categoryConnected = false,
    this.onCategoryConnect,
    this.onCategoryPort,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.store,
    this.api = const ClassifyApi(),
    this.initialParams,
    this.onParams,
  });

  @override
  State<ModelClassifierNode> createState() => _ModelClassifierNodeState();
}

class _ModelClassifierNodeState extends State<ModelClassifierNode> {
  late final ModelCatalogStore _catalog = widget.store ?? ModelCatalogStore();

  final InputPort _in = InputPort('aaIn');
  final InputPort _categoryIn = InputPort('categoryIn');
  final OutputPort _out = OutputPort('classifiedAaOut');

  final TextEditingController _manual = TextEditingController();

  // aaIn: incoming AA payload with text column
  AaPayload? _incomingAa;
  int _bytes = 0; // total bytes across all `text` column entries

  // categoryIn: incoming categories AA (label / hypothesis_template / threshold)
  AaPayload? _categories;

  List<ModelEntry> _models = [];
  String? _selectedId; // modelId of the dropdown selection
  String? _modelOverride; // latest value from modelIn (overrides the rest)

  StreamSubscription<String>? _modelSub;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  AaPayload? _lastOutput;
  String? _status;

  // Auto-execution: fire when input data arrives, debounced, and de-duplicated
  // so identical inputs don't re-hit the backend.
  Timer? _autoTimer;
  String? _lastRunSig;

  bool get _hasOverride =>
      _modelOverride != null && _modelOverride!.trim().isNotEmpty;

  bool get _hasText => _incomingAa?.cols.contains('text') == true;

  ModelEntry? get _selectedModel {
    for (final m in _models) {
      if (m.modelId == _selectedId) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Restore saved settings so they survive save/reload.
    final p = widget.initialParams;
    if (p != null) {
      final sid = p['selectedId'];
      if (sid != null && sid.isNotEmpty) _selectedId = sid;
      if (p['manual'] != null) _manual.text = p['manual']!;
    }
    widget.onInputPort?.call(_in);
    widget.onCategoryPort?.call(_categoryIn);
    widget.onOutputPort?.call(_out);
    _in.onDataArrived.listen(_onIncoming);
    _categoryIn.onDataArrived.listen(_onCategories);
    _subscribeModel();
    _load();
  }

  void _reportParams() => widget.onParams?.call({
    'selectedId': _selectedId ?? '',
    'manual': _manual.text,
  });

  @override
  void didUpdateWidget(ModelClassifierNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelInput != widget.modelInput) _subscribeModel();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _modelSub?.cancel();
    _in.dispose();
    _categoryIn.dispose();
    _out.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final models = await _catalog.models();
      if (!mounted) return;
      setState(() {
        _models = models;
        _selectedId ??= models.isNotEmpty ? models.first.modelId : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Extract text from the incoming AA's text column.
  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    var total = 0;
    for (var i = 0; i < payload.cols.length; i++) {
      if (payload.cols[i] == 'text') total += payload.vals[i].toString().length;
    }
    setState(() {
      _status = null;
      _incomingAa = payload;
      _bytes = total;
    });
    _maybeAutoClassify();
  }

  /// Accept an incoming categories AA — its `label` column supplies the
  /// candidate categories (superseding the removed comma-separated field).
  void _onCategories(AaPayload payload) {
    if (!mounted) return;
    setState(() => _categories = payload);
    _maybeAutoClassify();
  }

  void _subscribeModel() {
    _modelSub?.cancel();
    _modelSub = widget.modelInput?.listen((location) {
      if (!mounted) return;
      setState(() => _modelOverride = location.trim());
      _maybeAutoClassify();
    });
  }

  /// Signature of the inputs a classify run depends on — used to skip re-running
  /// on identical data.
  String? _runSignature() {
    final m = _resolveModel();
    final cats = _categories;
    if (m == null || !_hasText || cats == null) return null;
    final aa = _incomingAa!;
    return '${m.identifier}|cat:${cats.length}:${cats.vals.join("|").hashCode}|'
        'aa:${aa.rows.length}:${aa.vals.hashCode}';
  }

  /// Fire a classification when input data arrives — debounced, skipping a run
  /// whose inputs match the last one. Manual [_classify] via the button still
  /// works regardless.
  void _maybeAutoClassify() {
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _busy || !_canClassify) return;
      final sig = _runSignature();
      if (sig == null || sig == _lastRunSig) return;
      _classify();
    });
  }

  /// Resolve the model to classify with: modelIn → manual → dropdown. Returns
  /// the identifier the runner should receive plus its source type, or null.
  ({String identifier, String sourceType, String displayName})?
  _resolveModel() {
    final override = _modelOverride?.trim();
    final manual = _manual.text.trim();
    final raw = (override != null && override.isNotEmpty)
        ? override
        : (manual.isNotEmpty ? manual : null);
    if (raw != null) {
      return (
        identifier: raw,
        sourceType: _sourceTypeFor(raw),
        displayName: raw,
      );
    }
    final sel = _selectedModel;
    if (sel != null) {
      return (
        identifier: sel.pathOrUrl.isNotEmpty ? sel.pathOrUrl : sel.modelId,
        sourceType: sel.sourceType,
        displayName: sel.displayName,
      );
    }
    return null;
  }

  static String _sourceTypeFor(String s) {
    final u = Uri.tryParse(s);
    if (u != null && (u.scheme == 'http' || u.scheme == 'https')) {
      return 'remote_url';
    }
    if (s.startsWith('/') ||
        s.startsWith('.') ||
        s.startsWith('~') ||
        s.startsWith('file:')) {
      return 'local';
    }
    // e.g. "org/name" — a Hugging Face repo id.
    if (!s.contains(' ') && s.contains('/')) return 'huggingface';
    return 'local';
  }

  /// The full incoming AA to send to the classifier. Preserves every chunk row
  /// so the backend scores each one independently. Null when no text column
  /// has arrived on `aaIn`.
  AaPayload? _document() => _hasText ? _incomingAa : null;

  /// Candidate labels drawn from the incoming categories AA's `label` column.
  List<String> _labelList() =>
      _categories == null ? const [] : CategoryStore.labelsOf(_categories!);

  bool get _canClassify =>
      !_busy && _hasText && _resolveModel() != null && _labelList().isNotEmpty;

  Future<void> _classify() async {
    final model = _resolveModel();
    final docs = _document();
    final categories = _categories;
    final labels = _labelList();
    if (model == null || docs == null || categories == null || labels.isEmpty) {
      setState(
        () => _error =
            'Need text on aaIn, a model, and categories on categoryIn.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Classifying…';
    });
    try {
      final result = await widget.api.classify(
        model: model.identifier,
        sourceType: model.sourceType,
        labels: labels,
        documents: docs,
        categories: categories,
      );
      if (!mounted) return;
      _lastOutput = result;
      _lastRunSig = _runSignature();
      _out.emit(result);
      final rowCount = result.distinctRows().length;
      final scoreLabels = ModelClassifierNode.displayCategories(result.cols);
      setState(
        () => _status =
            'Classified $rowCount chunk${rowCount == 1 ? '' : 's'} × '
            '${scoreLabels.length} categor${scoreLabels.length == 1 ? 'y' : 'ies'}',
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = null;
          _error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final hasOutput = _lastOutput != null;

    return DoubleNaughtNodeWrapper(
      title: 'Model Classifier',
      icon: Icons.category_outlined,
      width: ModelClassifierNode._width,
      inputPorts: [
        InputConnector(
          label: 'aaIn',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onTextConnect,
        ),
        InputConnector(
          label: 'modelIn',
          idx: 1,
          active: widget.modelConnected || widget.modelInput != null,
          onConnect: widget.onModelConnect,
        ),
        InputConnector(
          label: 'categoryIn',
          idx: 2,
          active: widget.categoryConnected,
          onConnect: widget.onCategoryConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'classifiedAaOut',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: _kPortLaneInset),
          _dropdown(theme),
          const SizedBox(height: 16),
          TextField(
            controller: _manual,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Manual path / URL',
              hintText: 'org/model or https://… or /path',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
            onChanged: (_) {
              setState(() {});
              _reportParams();
            },
          ),
          if (_hasOverride) ...[
            const SizedBox(height: 8),
            _overrideBanner(theme),
          ],
          const SizedBox(height: 14),
          _categoriesInfo(theme, muted),
          const SizedBox(height: 10),
          _textInInfo(theme, muted),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canClassify ? _classify : null,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Classify'),
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 14,
                  color: Colors.green,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _status!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.green,
                    ),
                  ),
                ),
              ],
            ),
          ],
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

  Widget _dropdown(ThemeData theme) {
    if (_loading) {
      return Text('Loading catalog…', style: theme.textTheme.bodySmall);
    }
    if (_models.isEmpty) {
      return Text(
        'No models in the catalog. Use the manual field or modelIn, or add rows '
        'to models_rcvs.json.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _selectedId,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        isDense: true,
        labelText: 'Model',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      style: theme.textTheme.bodySmall,
      items: [
        for (final m in _models)
          DropdownMenuItem(
            value: m.modelId,
            child: Text(
              m.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _busy
          ? null
          : (id) {
              setState(() => _selectedId = id);
              _reportParams();
            },
    );
  }

  Widget _overrideBanner(ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.link, size: 14, color: theme.colorScheme.primary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          'modelIn override: ${_modelOverride!.trim()}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    ],
  );

  /// The categories drawn from `categoryIn`, or a hint to connect it.
  Widget _categoriesInfo(ThemeData theme, TextStyle? muted) {
    final labels = _labelList();
    if (labels.isEmpty) {
      return Text(
        'Connect categoryIn (a categories AA) to set the categories.',
        style: muted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Categories (${labels.length}) · from categoryIn',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          labels.join(', '),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _textInInfo(ThemeData theme, TextStyle? muted) {
    if (_hasText) {
      final chunkCount = _incomingAa!.distinctRows().length;
      return Text(
        '$chunkCount chunk${chunkCount == 1 ? '' : 's'} · $_bytes bytes on aaIn',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      );
    }
    final incoming = _incomingAa;
    if (incoming == null) {
      return Text('Connect aaIn (AA payload with text column).', style: muted);
    }
    // Wired, but the AA has no `text` column — almost always a mis-wire (e.g.
    // Load Model's `model` AA or a categories AA landed on aaIn instead of
    // Chunk's passages). Name the columns that did arrive so it's self-evident.
    final cols = {for (final c in incoming.cols) c}.join(', ');
    return Text(
      "aaIn AA has no 'text' column — got: $cols. Wire Chunk's aaOut here.",
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}
