import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/model_catalog_store.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';

/// A **functional node** that resolves a model definition and emits it as a
/// standard [AaPayload] (row `model:<id>`, attribute columns) for downstream
/// nodes.
///
/// Inputs:
///  * `trigger` (AA, idx 0) — an arriving payload (e.g. from **Start**) resolves
///    and emits the current selection, driving the reactive pipeline.
///  * `urlIn` (String, idx 1) — a URL or Hugging Face id that **overrides** the
///    dropdown; the model is loaded from that source instead of the catalog.
///
/// The `modelSelect` dropdown is populated from the `displayName` attributes of
/// rows in `storage/models_aa.json`. A remote model resolved from `urlIn` can be
/// saved back into the catalog as a new AA row.
class LoadModelNode extends BaseNodeWidget {
  static const double _width = 320;

  // urlIn (String) — idx 1
  final bool urlConnected;
  final void Function(PortRef source)? onUrlConnect;
  final Stream<String>? locationInput;

  final ModelCatalogStore? store;

  const LoadModelNode({
    super.key,
    required super.node,
    bool triggerConnected = false,
    void Function(PortRef source)? onTriggerConnect,
    super.onInputPort,
    this.urlConnected = false,
    this.onUrlConnect,
    this.locationInput,
    super.onOutputPort,
    super.connectedOutputs,
    this.store,
    super.initialParams,
    super.onParams,
  }) : super(inputConnected: triggerConnected, onInputConnect: onTriggerConnect);

  @override
  State<LoadModelNode> createState() => _LoadModelNodeState();
}

class _LoadModelNodeState extends BaseNodeState<LoadModelNode> {
  @override String   get nodeTitle => 'Load Model';
  @override IconData get nodeIcon  => Icons.memory_outlined;
  @override double   get nodeWidth => LoadModelNode._width;

  late final ModelCatalogStore _catalog = widget.store ?? ModelCatalogStore();

  final InputPort  _trigger = InputPort('trigger');
  final OutputPort _out     = OutputPort('model');

  List<ModelEntry> _models        = [];
  String?          _selectedId;
  String?          _urlOverride;
  ModelEntry?      _resolvedRemote;

  StreamSubscription<String>? _urlSub;
  bool         _loading  = true;
  bool         _busy     = false;
  String?      _error;
  AaPayload?   _lastOutput;
  String?      _resolvedLabel;

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
    final saved = widget.initialParams?['selectedId'];
    if (saved != null && saved.isNotEmpty) _selectedId = saved;
    initInputPort(_trigger, _onTrigger);
    initOutputPort(_out);
    _subscribeUrl();
    _load();
  }

  void _reportParams() =>
      saveParams({'selectedId': _selectedId ?? ''});

  @override
  void didUpdateWidget(LoadModelNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locationInput != widget.locationInput) _subscribeUrl();
  }

  @override
  void dispose() {
    _urlSub?.cancel();
    _trigger.dispose();
    _out.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error   = null;
    });
    try {
      final models = await _catalog.models();
      if (!mounted) return;
      setState(() {
        _models    = models;
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
      _resolveAndEmit();
    });
  }

  void _onTrigger(AaPayload _) {
    if (!mounted) return;
    _resolveAndEmit();
  }

  AaPayload? _buildAa() {
    if (_hasOverride) {
      final src  = _urlOverride!.trim();
      final isHf = _looksLikeHfId(src);
      final entry = ModelEntry(
        modelId:     _modelIdFrom(src),
        displayName: src,
        sourceType:  isHf ? 'huggingface' : 'remote_url',
        pathOrUrl:   src,
        format:      '',
        task:        '',
      );
      _resolvedRemote = entry;
      return ModelCatalogStore.sliceModel(entry);
    }
    final selected = _selectedModel;
    if (selected == null) return null;
    _resolvedRemote = null;
    return ModelCatalogStore.sliceModel(selected);
  }

  void _resolveAndEmit() {
    final aa = _buildAa();
    if (aa == null) {
      setState(() => _error = 'Select a model or provide a URL on urlIn.');
      return;
    }
    _lastOutput = aa;
    _out.emit(aa);
    setState(() {
      _resolvedLabel = aa.value('displayName');
      _error         = null;
    });
  }

  Future<void> _saveToCatalog() async {
    final entry = _resolvedRemote;
    if (entry == null) return;
    setState(() {
      _busy  = true;
      _error = null;
    });
    try {
      final models = await _catalog.upsert(entry);
      if (!mounted) return;
      setState(() {
        _models         = models;
        _selectedId     = entry.modelId;
        _urlOverride    = null;
        _resolvedRemote = null;
      });
      _reportParams();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static bool _looksLikeUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && (u.scheme == 'http' || u.scheme == 'https');
  }

  static bool _looksLikeHfId(String s) =>
      !_looksLikeUrl(s) && s.contains('/') && !s.contains(' ');

  static String _modelIdFrom(String s) {
    String base = s.trim();
    final u = Uri.tryParse(base);
    if (u != null && (u.scheme == 'http' || u.scheme == 'https')) {
      base = u.pathSegments.isNotEmpty ? u.pathSegments.last : u.host;
    }
    final b    = StringBuffer();
    var   dash = false;
    for (final ch in base.toLowerCase().codeUnits) {
      final alnum =
          (ch >= 0x30 && ch <= 0x39) || (ch >= 0x61 && ch <= 0x7a);
      if (alnum) {
        if (dash && b.isNotEmpty) b.write('-');
        dash = false;
        b.writeCharCode(ch);
      } else {
        dash = true;
      }
    }
    final out = b.toString();
    return out.isEmpty ? 'model' : out;
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'trigger',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
        InputConnector(
          label: 'urlIn',
          idx: 1,
          active: widget.urlConnected || widget.locationInput != null,
          onConnect: widget.onUrlConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'model',
          idx: 0,
          hasData: _lastOutput != null,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme  = Theme.of(context);
    final muted  = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    const kPortLaneInset = 28.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: kPortLaneInset),
        _dropdown(theme),
        if (_hasOverride) ...[
          const SizedBox(height: 8),
          _overrideBanner(theme),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    (_busy || (_selectedModel == null && !_hasOverride))
                        ? null
                        : _resolveAndEmit,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Load'),
              ),
            ),
            if (_resolvedRemote != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Save this model to the catalog',
                onPressed: _busy ? null : _saveToCatalog,
                icon: const Icon(Icons.save_alt, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        _status(theme, muted),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
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

  Widget _dropdown(ThemeData theme) {
    if (_loading) {
      return Text('Loading catalog…', style: theme.textTheme.bodySmall);
    }
    if (_models.isEmpty) {
      return Text(
        'No models in the catalog. Feed a URL on urlIn, or add rows to '
        'models_aa.json.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _selectedId,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        isDense: true,
        labelText: 'modelSelect',
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
              setState(() {
                _selectedId     = id;
                _urlOverride    = null;
                _resolvedRemote = null;
              });
              _reportParams();
              _resolveAndEmit();
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
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        ],
      );

  Widget _status(ThemeData theme, TextStyle? muted) {
    final aa = _lastOutput;
    if (aa == null) return Text('Not loaded', style: muted);

    final source = aa.value('sourceType');
    final format = aa.value('format');
    final task   = aa.value('task');
    final facts  = <String>[
      if (source != null && source.isNotEmpty) source,
      if (format != null && format.isNotEmpty) format,
      if (task   != null && task.isNotEmpty)   task,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Emitted ${_resolvedLabel ?? aa.value('displayName') ?? 'model'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: Colors.green),
              ),
            ),
          ],
        ),
        if (facts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              facts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
      ],
    );
  }
}
