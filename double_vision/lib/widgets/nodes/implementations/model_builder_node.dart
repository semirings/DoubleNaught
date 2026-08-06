import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/model_builder_api.dart';
import '../base/base_node_widget.dart';

class _Preset {
  final String label;
  final ModelBuildConfig config;
  const _Preset(this.label, this.config);
}

const _presets = [
  _Preset('GPT-2 Small (117M)',
      ModelBuildConfig(nLayers: 12, dModel: 768, nHeads: 12, dFf: 3072)),
  _Preset('GPT-2 Medium (345M)',
      ModelBuildConfig(nLayers: 24, dModel: 1024, nHeads: 16, dFf: 4096)),
  _Preset('Tiny (15M)',
      ModelBuildConfig(nLayers: 6, dModel: 384, nHeads: 6, dFf: 1536)),
];

/// A source node that defines and builds a GPT-style transformer on the
/// backend, then holds a server-side handle for downstream training/inference.
///
/// No input ports — this is a root node. Output: model handle string (carried
/// via params for downstream nodes to read; no port-bus AA output needed).
class ModelBuilderNode extends BaseNodeWidget {
  static const double _width = 320.0;

  final ModelBuilderApi api;

  const ModelBuilderNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    this.api = const ModelBuilderApi(),
  });

  @override
  State<ModelBuilderNode> createState() => _ModelBuilderNodeState();
}

class _ModelBuilderNodeState extends BaseNodeState<ModelBuilderNode> {
  @override String   get nodeTitle    => 'Model Builder';
  @override IconData get nodeIcon     => Icons.memory_rounded;
  @override String   get workingLabel => 'building…';
  @override double   get nodeWidth    => ModelBuilderNode._width;

  late ModelBuildConfig _cfg;
  ModelBuildResult? _result;
  String? _error;

  late final TextEditingController _vocabCtrl;
  late final TextEditingController _layersCtrl;
  late final TextEditingController _dModelCtrl;
  late final TextEditingController _nHeadsCtrl;
  late final TextEditingController _dFfCtrl;
  late final TextEditingController _dropoutCtrl;
  late final TextEditingController _seqCtrl;

  @override
  void initState() {
    super.initState();
    _cfg = widget.initialParams != null && widget.initialParams!.isNotEmpty
        ? ModelBuildConfig.fromParams(widget.initialParams!)
        : const ModelBuildConfig();
    _vocabCtrl   = TextEditingController(text: '${_cfg.vocabSize}');
    _layersCtrl  = TextEditingController(text: '${_cfg.nLayers}');
    _dModelCtrl  = TextEditingController(text: '${_cfg.dModel}');
    _nHeadsCtrl  = TextEditingController(text: '${_cfg.nHeads}');
    _dFfCtrl     = TextEditingController(text: '${_cfg.dFf}');
    _dropoutCtrl = TextEditingController(text: '${_cfg.dropout}');
    _seqCtrl     = TextEditingController(text: '${_cfg.maxSeqLen}');
  }

  @override
  void dispose() {
    for (final c in [
      _vocabCtrl, _layersCtrl, _dModelCtrl, _nHeadsCtrl,
      _dFfCtrl, _dropoutCtrl, _seqCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _applyPreset(_Preset preset) {
    setState(() => _cfg = preset.config);
    _vocabCtrl.text   = '${_cfg.vocabSize}';
    _layersCtrl.text  = '${_cfg.nLayers}';
    _dModelCtrl.text  = '${_cfg.dModel}';
    _nHeadsCtrl.text  = '${_cfg.nHeads}';
    _dFfCtrl.text     = '${_cfg.dFf}';
    _dropoutCtrl.text = '${_cfg.dropout}';
    _seqCtrl.text     = '${_cfg.maxSeqLen}';
    _saveParams();
  }

  ModelBuildConfig _cfgFromFields() => _cfg.copyWith(
        vocabSize: int.tryParse(_vocabCtrl.text)    ?? _cfg.vocabSize,
        nLayers:   int.tryParse(_layersCtrl.text)   ?? _cfg.nLayers,
        dModel:    int.tryParse(_dModelCtrl.text)   ?? _cfg.dModel,
        nHeads:    int.tryParse(_nHeadsCtrl.text)   ?? _cfg.nHeads,
        dFf:       int.tryParse(_dFfCtrl.text)      ?? _cfg.dFf,
        dropout:   double.tryParse(_dropoutCtrl.text) ?? _cfg.dropout,
        maxSeqLen: int.tryParse(_seqCtrl.text)      ?? _cfg.maxSeqLen,
      );

  void _saveParams() => saveParams(_cfg.toParams());

  Future<void> _build() async {
    final cfg = _cfgFromFields();
    setState(() {
      _cfg   = cfg;
      _error = null;
    });
    setWorking();
    _saveParams();
    try {
      final result = await widget.api.build(cfg);
      if (!mounted) return;
      setState(() => _result = result);
      setComplete();
      saveParams({..._cfg.toParams(), 'modelHandleId': result.handleId});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanError(e));
      setError(e);
    }
  }

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme  = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy   = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: _presets.map((p) => ActionChip(
            label: Text(p.label, style: theme.textTheme.labelSmall),
            padding: const EdgeInsets.symmetric(horizontal: 2),
            onPressed: busy ? null : () => _applyPreset(p),
          )).toList(),
        ),
        const Divider(height: 14, thickness: 0.5),

        _intRow('Vocab size', _vocabCtrl, busy),
        _intRow('Layers',     _layersCtrl, busy),
        _intRow('d_model',    _dModelCtrl, busy),
        _intRow('n_heads',    _nHeadsCtrl, busy),
        _intRow('d_ff',       _dFfCtrl,    busy),
        _floatRow('Dropout',  _dropoutCtrl, busy),
        _intRow('Max seq len', _seqCtrl,   busy),

        Row(
          children: [
            Text('Grad checkpoint', style: theme.textTheme.bodySmall),
            const Spacer(),
            Switch(
              value: _cfg.useGradientCheckpointing,
              onChanged: busy
                  ? null
                  : (v) {
                      setState(() =>
                          _cfg = _cfg.copyWith(useGradientCheckpointing: v));
                      _saveParams();
                    },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : _build,
            icon: busy
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.construction_rounded, size: 16),
            label: Text(busy ? 'Building…' : 'Build Model'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
          ),
        ),
        const SizedBox(height: 6),

        _statusSection(theme, scheme),
      ],
    );
  }

  Widget _intRow(String label, TextEditingController ctrl, bool disabled) =>
      _fieldRow(label, ctrl, disabled,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly]);

  Widget _floatRow(String label, TextEditingController ctrl, bool disabled) =>
      _fieldRow(label, ctrl, disabled);

  Widget _fieldRow(
    String label,
    TextEditingController ctrl,
    bool disabled, {
    List<TextInputFormatter>? inputFormatters,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: theme.textTheme.bodySmall)),
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: !disabled,
              inputFormatters: inputFormatters,
              keyboardType: TextInputType.number,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
              onChanged: (_) => _saveParams(),
            ),
          ),
        ],
      ),
    );
  }

  // ModelBuilder keeps its own status section: 7×7 dot, result arch table.
  Widget _statusSection(ThemeData theme, ColorScheme scheme) {
    final (color, label) = switch (status) {
      NodeStatus.idle     => (scheme.outline, 'idle'),
      NodeStatus.working  => (scheme.primary, 'building…'),
      NodeStatus.complete => (Colors.green,   'complete'),
      NodeStatus.error    => (scheme.error,   'error'),
    };

    final r = _result;
    if (status == NodeStatus.error && _error != null) {
      return _dot(color, 'error · $_error', theme);
    }
    if (r == null) return _dot(color, label, theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dot(color, '${r.paramCountM}M params  ·  handle saved', theme),
        const SizedBox(height: 4),
        _archTable(r, theme),
      ],
    );
  }

  Widget _dot(Color color, String text, ThemeData theme) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            width: 7, height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      );

  Widget _archTable(ModelBuildResult r, ThemeData theme) {
    final rows = [
      ('Parameters',      '${r.paramCountM}M (${r.paramCount})'),
      ('VRAM fp16',       '${r.estimatedVramFp16Mb.toStringAsFixed(0)} MB'),
      ('VRAM fp32',       '${r.estimatedVramFp32Mb.toStringAsFixed(0)} MB'),
      ('Layers',          '${_cfg.nLayers}'),
      ('d_model / heads', '${_cfg.dModel} / ${_cfg.nHeads}'),
      ('Context',         '${_cfg.maxSeqLen} tokens'),
    ];
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: rows.map((pair) => TableRow(children: [
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 2),
          child: Text(pair.$1, style: theme.textTheme.bodySmall),
        ),
        Text(pair.$2, style: mono),
      ])).toList(),
    );
  }
}
