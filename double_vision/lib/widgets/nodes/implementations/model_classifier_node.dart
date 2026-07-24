import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/aa_file.dart';
import '../../../services/classify_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/model_catalog_store.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Vertical space reserved so the two edge-anchored input labels (`textIn` at
/// idx 0, `urlIn` at idx 1) clear the body controls.
const double _kPortLaneInset = 26;

/// A **functional node** that runs zero-shot classification over incoming text
/// and emits the results as an rcvs.json associative array.
///
/// Inputs:
///  * `textIn` (AA, idx 0, required) — documents to classify, typically the
///    Inventory node's `entry` output. Each AA row is one document; its text is
///    taken from the first text-like column (or a join of its values).
///  * `urlIn` (String, idx 1, optional) — a model URL / Hugging Face id / local
///    path that **overrides** the manual field and the dropdown.
///
/// Model resolution order: `urlIn` → manual field → dropdown selection. A
/// Hugging Face repo id is passed to the runner verbatim; a web/local path is
/// passed as resolved.
///
/// Output `classifiedAaOut` (AA, idx 0): rows = document ids, cols = category
/// labels, vals = scores — a documents×categories score matrix in rcvs form.
class ModelClassifierNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  // textIn (AA) — idx 0
  final bool textConnected;
  final void Function(PortRef source)? onTextConnect;
  final void Function(InputPort port)? onInputPort;

  // urlIn (String) — idx 1
  final bool urlConnected;
  final void Function(PortRef source)? onUrlConnect;
  final Stream<String>? locationInput;

  // classifiedAaOut (AA) — output idx 0
  final void Function(OutputPort port)? onOutputPort;
  final Set<int> connectedOutputs;

  /// AA-native model catalog (`storage/models_rcvs.json`). Injectable for tests.
  final ModelCatalogStore? store;

  /// Classification backend client. Injectable for tests.
  final ClassifyApi api;

  const ModelClassifierNode({
    super.key,
    required this.node,
    this.textConnected = false,
    this.onTextConnect,
    this.onInputPort,
    this.urlConnected = false,
    this.onUrlConnect,
    this.locationInput,
    this.onOutputPort,
    this.connectedOutputs = const {},
    this.store,
    this.api = const ClassifyApi(),
  });

  @override
  State<ModelClassifierNode> createState() => _ModelClassifierNodeState();
}

class _ModelClassifierNodeState extends State<ModelClassifierNode> {
  late final ModelCatalogStore _catalog = widget.store ?? ModelCatalogStore();

  final InputPort _textIn = InputPort('textIn');
  final OutputPort _out = OutputPort('classifiedAaOut');

  final TextEditingController _manual = TextEditingController();
  final TextEditingController _labels = TextEditingController(
    text: 'positive, negative, neutral',
  );

  List<ModelEntry> _models = [];
  String? _selectedId; // modelId of the dropdown selection
  String? _urlOverride; // latest value from urlIn (overrides the rest)
  AaPayload? _incoming; // documents from textIn

  StreamSubscription<String>? _urlSub;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  AaPayload? _lastOutput;
  String? _status;

  bool get _hasOverride =>
      _urlOverride != null && _urlOverride!.trim().isNotEmpty;

  ModelEntry? get _selectedModel {
    for (final m in _models) {
      if (m.modelId == _selectedId) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.onInputPort?.call(_textIn);
    widget.onOutputPort?.call(_out);
    _textIn.onDataArrived.listen(_onText);
    _subscribeUrl();
    _load();
  }

  @override
  void didUpdateWidget(ModelClassifierNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locationInput != widget.locationInput) _subscribeUrl();
  }

  @override
  void dispose() {
    _urlSub?.cancel();
    _textIn.dispose();
    _out.dispose();
    _manual.dispose();
    _labels.dispose();
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

  void _subscribeUrl() {
    _urlSub?.cancel();
    _urlSub = widget.locationInput?.listen((location) {
      if (!mounted) return;
      setState(() => _urlOverride = location.trim());
    });
  }

  void _onText(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _status = null;
    });
  }

  /// Resolve the model to classify with: urlIn → manual → dropdown. Returns the
  /// identifier the runner should receive plus its source type, or null.
  ({String identifier, String sourceType, String displayName})?
  _resolveModel() {
    final override = _urlOverride?.trim();
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

  /// Build the documents AA (rows = doc id, col `text`) from the textIn payload.
  AaPayload? _documents() {
    final aa = _incoming;
    if (aa == null) return null;
    final byRow = AaFile.groupByRow(aa);
    if (byRow.isEmpty) return null;
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];
    for (final e in byRow.entries) {
      rows.add(e.key);
      cols.add('text');
      vals.add(_textOf(e.value));
    }
    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  String _textOf(Map<String, String> row) {
    for (final k in const [
      'rawText',
      'cleanedText',
      'text',
      'content',
      'body',
      'description',
    ]) {
      final v = row[k];
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return row.values.where((v) => v.trim().isNotEmpty).join(' ');
  }

  List<String> _labelList() => [
    for (final l in _labels.text.split(','))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  bool get _canClassify =>
      !_busy &&
      _incoming != null &&
      _resolveModel() != null &&
      _labelList().isNotEmpty;

  Future<void> _classify() async {
    final model = _resolveModel();
    final docs = _documents();
    final labels = _labelList();
    if (model == null || docs == null || labels.isEmpty) {
      setState(
        () => _error =
            'Need documents on textIn, a model, and at least one category.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Classifying ${docs.distinctRows().length} document(s)…';
    });
    try {
      final result = await widget.api.classify(
        model: model.identifier,
        sourceType: model.sourceType,
        labels: labels,
        documents: docs,
      );
      if (!mounted) return;
      _lastOutput = result;
      _out.emit(result);
      setState(
        () => _status =
            'Classified ${result.distinctRows().length} doc(s) × ${labels.length} label(s)',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _status = null);
        setState(() => _error = '$e');
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
          label: 'textIn',
          idx: 0,
          active: widget.textConnected,
          onConnect: widget.onTextConnect,
        ),
        InputConnector(
          label: 'urlIn',
          idx: 1,
          active: widget.urlConnected || widget.locationInput != null,
          onConnect: widget.onUrlConnect,
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
          const SizedBox(height: 8),
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
            onChanged: (_) => setState(() {}),
          ),
          if (_hasOverride) ...[
            const SizedBox(height: 6),
            _overrideBanner(theme),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _labels,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Categories (comma-separated)',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          _textInInfo(theme, muted),
          const SizedBox(height: 10),
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
        'No models in the catalog. Use the manual field or urlIn, or add rows '
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
      onChanged: _busy ? null : (id) => setState(() => _selectedId = id),
    );
  }

  Widget _overrideBanner(ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.link, size: 14, color: theme.colorScheme.primary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          'urlIn override: ${_urlOverride!.trim()}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    ],
  );

  Widget _textInInfo(ThemeData theme, TextStyle? muted) {
    final aa = _incoming;
    if (aa == null) {
      return Text('Connect textIn (e.g. Inventory entry).', style: muted);
    }
    final docs = aa.distinctRows().length;
    return Text('$docs document(s) on textIn', style: muted);
  }
}
