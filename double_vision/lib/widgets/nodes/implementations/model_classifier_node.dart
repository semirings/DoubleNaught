import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/classify_api.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/model_catalog_store.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Vertical space reserved so the two edge-anchored input labels (`textIn` at
/// idx 0, `urlIn` at idx 1) clear the body controls.
const double _kPortLaneInset = 26;

/// Upper bound on the characters sent to the classifier. Zero-shot models
/// truncate to a few hundred tokens anyway, so classifying the whole of a large
/// document is wasteful; the head is representative enough.
const int _kMaxClassifyChars = 8000;

/// A **functional node** that runs zero-shot classification over incoming
/// **text** and emits the results as an rcvs.json associative array.
///
/// Inputs:
///  * `textIn` (text bytes, idx 0, required) — the document text to classify,
///    typically Inventory's `content` output (a byte stream), decoded as UTF-8.
///  * `urlIn` (String, idx 1, optional) — a model URL / Hugging Face id / local
///    path that **overrides** the manual field and the dropdown.
///
/// Model resolution order: `urlIn` → manual field → dropdown selection. A
/// Hugging Face repo id is passed to the runner verbatim; a web/local path is
/// passed as resolved.
///
/// Output `classifiedAaOut` (AA, idx 0): rows = document id, cols = category
/// labels, vals = scores — a document×categories score matrix in rcvs form.
class ModelClassifierNode extends StatefulWidget {
  static const double _width = 320;

  final WorkflowNode node;

  // textIn (document text bytes) — idx 0
  final Stream<Uint8List>? input;
  final bool inputConnected;
  final void Function(PortRef source)? onTextConnect;

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

  /// Saved settings to restore (selected model, manual path, categories), and a
  /// callback to report them back to the canvas for persistence.
  final Map<String, String>? initialParams;
  final void Function(Map<String, String> params)? onParams;

  const ModelClassifierNode({
    super.key,
    required this.node,
    this.input,
    this.inputConnected = false,
    this.onTextConnect,
    this.urlConnected = false,
    this.onUrlConnect,
    this.locationInput,
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

  final OutputPort _out = OutputPort('classifiedAaOut');

  final TextEditingController _manual = TextEditingController();
  final TextEditingController _labels = TextEditingController(
    text: 'positive, negative, neutral',
  );

  // textIn: accumulate the incoming byte stream and decode to text.
  StreamSubscription<Uint8List>? _sub;
  BytesBuilder _builder = BytesBuilder();
  String? _text;
  int _bytes = 0;

  List<ModelEntry> _models = [];
  String? _selectedId; // modelId of the dropdown selection
  String? _urlOverride; // latest value from urlIn (overrides the rest)

  StreamSubscription<String>? _urlSub;
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
      _urlOverride != null && _urlOverride!.trim().isNotEmpty;

  bool get _hasText => _text != null && _text!.trim().isNotEmpty;

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
      if (p['categories'] != null && p['categories']!.isNotEmpty) {
        _labels.text = p['categories']!;
      }
    }
    widget.onOutputPort?.call(_out);
    _subscribeText();
    _subscribeUrl();
    _load();
  }

  void _reportParams() => widget.onParams?.call({
    'selectedId': _selectedId ?? '',
    'manual': _manual.text,
    'categories': _labels.text,
  });

  @override
  void didUpdateWidget(ModelClassifierNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input) _subscribeText();
    if (oldWidget.locationInput != widget.locationInput) _subscribeUrl();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _sub?.cancel();
    _urlSub?.cancel();
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

  void _subscribeText() {
    _sub?.cancel();
    _builder = BytesBuilder();
    _text = null;
    _bytes = 0;
    _sub = widget.input?.listen(_onChunk);
  }

  void _onChunk(Uint8List chunk) {
    if (!mounted) return;
    _builder.add(chunk);
    final data = _builder.toBytes();
    setState(() {
      _bytes = data.length;
      _text = utf8.decode(data, allowMalformed: true);
      _status = null;
    });
    _maybeAutoClassify();
  }

  void _subscribeUrl() {
    _urlSub?.cancel();
    _urlSub = widget.locationInput?.listen((location) {
      if (!mounted) return;
      setState(() => _urlOverride = location.trim());
      _maybeAutoClassify();
    });
  }

  /// Signature of the inputs a classify run depends on — used to skip re-running
  /// on identical data.
  String? _runSignature() {
    final m = _resolveModel();
    if (m == null || !_hasText) return null;
    return '${m.identifier}|${_labelList().join(",")}|'
        '${_text!.length}:${_text!.hashCode}';
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

  /// The single incoming document as a 1-row AA (rows = `document`, col `text`),
  /// truncated to [_kMaxClassifyChars]. Null when no text has arrived.
  AaPayload? _document() {
    final text = _text?.trim();
    if (text == null || text.isEmpty) return null;
    final clipped = text.length > _kMaxClassifyChars
        ? text.substring(0, _kMaxClassifyChars)
        : text;
    return AaPayload(
      rows: const ['document'],
      cols: const ['text'],
      vals: [clipped],
    );
  }

  List<String> _labelList() => [
    for (final l in _labels.text.split(','))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  bool get _canClassify =>
      !_busy && _hasText && _resolveModel() != null && _labelList().isNotEmpty;

  Future<void> _classify() async {
    final model = _resolveModel();
    final docs = _document();
    final labels = _labelList();
    if (model == null || docs == null || labels.isEmpty) {
      setState(
        () =>
            _error = 'Need text on textIn, a model, and at least one category.',
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
      );
      if (!mounted) return;
      _lastOutput = result;
      _lastRunSig = _runSignature();
      _out.emit(result);
      setState(
        () => _status =
            'Classified ${result.distinctRows().length} doc(s) × ${labels.length} label(s)',
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
          label: 'textIn',
          idx: 0,
          active: widget.inputConnected,
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
            onChanged: (_) {
              setState(() {});
              _reportParams();
            },
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
            onChanged: (_) {
              setState(() {});
              _reportParams();
            },
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
    if (!_hasText) {
      return Text('Connect textIn (document text).', style: muted);
    }
    final chars = _text!.length;
    final clipped = chars > _kMaxClassifyChars;
    final detail = clipped
        ? '$_bytes bytes · classifying first $_kMaxClassifyChars chars'
        : '$_bytes bytes on textIn';
    return Text(
      detail,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: muted,
    );
  }
}
