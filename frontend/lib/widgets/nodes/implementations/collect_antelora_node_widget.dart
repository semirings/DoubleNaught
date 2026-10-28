import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/antelora_api.dart';
import '../base/base_node_widget.dart';
import '../../../models/workflow.dart';
import '../base/gated_node_state.dart';
import '../base/output_connector.dart';
import 'vlm_trainer_node_widget.dart' show firstValue;

/// Gathers the saved antelora pages into one flat, trainer-ready folder:
/// `storage/antelora/<set>/_collected/<output>/` with `metadata.jsonl` and
/// `images/`. Tick the pages to include; untick one to hold it out (for
/// evaluation). It never runs by itself — only Execute collects — because
/// collecting is a decision about *when the set is ready*, not a reaction.
///
/// Output `dataset` (idx 0): one `collected` row — `path`, `images`, `pages` —
/// for whatever trains on it next.
class CollectAnteloraNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/antelora/*` endpoints.
  final AnteloraApi? api;

  /// Registers the `dataset` port with the workflow page (multi-output map).
  final void Function(OutputPort port)? onAaOutputPort;

  const CollectAnteloraNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.onAaOutputPort,
    this.api,
  });

  @override
  State<CollectAnteloraNodeWidget> createState() =>
      _CollectAnteloraNodeWidgetState();
}

class _CollectAnteloraNodeWidgetState
    extends GatedNodeState<CollectAnteloraNodeWidget> {
  @override String   get nodeTitle    => 'Collect Antelora';
  @override IconData get nodeIcon     => Icons.inventory_2_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'collecting';

  late final AnteloraApi _api;
  late final TextEditingController _set;
  late final TextEditingController _output;
  final OutputPort _out = OutputPort('dataset');
  late final InputPort _dirIn;
  String? _fromPort; // antelora name taken from the `dir` port, if connected

  List<AnteloraPageInfo> _pages = const [];
  late final Set<String> _held;
  AnteloraCollectResult? _result;
  String? _listError;
  bool _listing = false;
  http.Client? _execClient;
  int _execGen = 0;

  int get _includedImages => _pages
      .where((p) => !_held.contains(p.name))
      .fold(0, (sum, p) => sum + p.images);

  /// Ready when at least one page with images is ticked. Never auto-fires:
  /// [maybeAutoFire] is deliberately never called.
  @override
  bool get isReady =>
      _setError == null && _outputError == null && _includedImages > 0;

  static final RegExp _slash = RegExp(r'[\\/]');
  String? get _setError {
    final v = _set.text.trim();
    if (v.isEmpty) return 'Enter the antelora name';
    return _slash.hasMatch(v) ? 'Just a name, e.g. mccay' : null;
  }

  String? get _outputError {
    final v = _output.text.trim();
    if (v.isEmpty) return 'Enter a folder name';
    return _slash.hasMatch(v) ? 'Just a name, e.g. train' : null;
  }

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const AnteloraApi();
    final p = widget.initialParams;
    _set = TextEditingController(text: p?['antelora'] ?? '');
    _output = TextEditingController(text: p?['output'] ?? 'train');
    _held = {
      for (final n in (p?['exclude'] ?? '').split(','))
        if (n.trim().isNotEmpty) n.trim(),
    };
    initOutputPort(_out);
    widget.onAaOutputPort?.call(_out);
    _dirIn = InputPort('dir');
    initInputPort(_dirIn, _onDir);
    _dirIn.onDisconnected.listen((_) {
      if (mounted) setState(() => _fromPort = null);
    });
    _refresh();
  }

  @override
  void dispose() {
    _set.dispose();
    _output.dispose();
    _out.dispose();
    _dirIn.dispose();
    _execClient?.close();
    super.dispose();
  }

  /// A `dir` row names the antelora: its `antelora` column (Save Antelora), else
  /// the directory it came from — `source_dir` (Load File on a folder) or
  /// `path`. For a directory the name is the folder after `antelora/` when there
  /// is one (so a page folder inside a set still names the set), else the last
  /// folder.
  void _onDir(AaPayload aa) {
    var name = firstValue(aa, 'antelora');
    if (name == null) {
      final dir = firstValue(aa, 'source_dir') ?? firstValue(aa, 'path');
      if (dir != null) {
        final parts = dir
            .split(RegExp(r'[\\/]'))
            .where((x) => x.isNotEmpty)
            .toList();
        final at = parts.lastIndexOf('antelora');
        if (at >= 0 && at + 1 < parts.length) {
          name = parts[at + 1];
        } else if (parts.isNotEmpty) {
          name = parts.last;
        }
      }
    }
    if (name == null || !mounted) return;
    setState(() {
      _fromPort = name;
      _set.text = name!;
      _held.clear(); // a different set has different pages
      _result = null;
    });
    _persist();
    _refresh();
  }

  void _persist() => saveParams({
        'antelora': _set.text.trim(),
        'output': _output.text.trim(),
        'exclude': (_held.toList()..sort()).join(','),
      });

  Future<void> _refresh() async {
    if (_setError != null) {
      setState(() => _pages = const []);
      return;
    }
    setState(() {
      _listing = true;
      _listError = null;
    });
    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    final api = owns ? AnteloraApi(baseUrl: _api.baseUrl, client: client) : _api;
    try {
      final pages = await api.listPages(_set.text.trim());
      if (!mounted) return;
      setState(() => _pages = pages);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pages = const [];
        _listError = '$e';
      });
    } finally {
      if (owns) client.close();
      if (mounted) setState(() => _listing = false);
    }
  }

  void _toggle(String page, bool included) {
    setState(() {
      included ? _held.remove(page) : _held.add(page);
      _result = null;
    });
    _persist();
  }

  @override
  void fire() => _collect();

  Future<void> _collect() async {
    if (!isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();
    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api = owns ? AnteloraApi(baseUrl: _api.baseUrl, client: client) : _api;
    try {
      final result = await api.collect(
        _set.text.trim(),
        exclude: _held.toList()..sort(),
        output: _output.text.trim(),
      );
      if (gen != _execGen || !mounted) return;
      setState(() => _result = result);
      setComplete(
        detail: '${result.images} images · ${result.pages.length} '
            'page${result.pages.length == 1 ? '' : 's'}'
            '${result.skipped > 0 ? ' · ${result.skipped} skipped' : ''}',
      );
      _out.emit(AaPayload(
        rows: ['collected', 'collected', 'collected'],
        cols: ['path', 'images', 'pages'],
        vals: [result.path, '${result.images}', result.pages.join(',')],
      ));
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'dir')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'dataset',
          idx: 0,
          active: _result != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = status == NodeStatus.working;
    final result = _result;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('collect-set'),
                controller: _set,
                enabled: !busy && _fromPort == null,
                onChanged: (_) {
                  _persist();
                  setState(() => _result = null);
                },
                onSubmitted: (_) => _refresh(),
                decoration: InputDecoration(
                  labelText: 'Antelora',
                  helperText: _fromPort == null ? null : 'from the dir port',
                  errorText: _setError,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('collect-refresh'),
              tooltip: 'Refresh pages',
              onPressed: busy || _listing ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_listError != null)
          Text(_listError!,
              key: const ValueKey('collect-list-error'),
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.error))
        else if (_pages.isEmpty)
          Text(
            _listing ? 'Looking for pages…' : 'No saved pages yet',
            key: const ValueKey('collect-empty'),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in _pages)
                  CheckboxListTile(
                    key: ValueKey('collect-page-${p.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: !_held.contains(p.name),
                    onChanged: busy ? null : (v) => _toggle(p.name, v ?? true),
                    title: Text(p.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${p.images} image${p.images == 1 ? '' : 's'}'
                      '${_held.contains(p.name) ? ' · held out' : ''}',
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('collect-output'),
          controller: _output,
          enabled: !busy,
          onChanged: (_) {
            _persist();
            setState(() => _result = null);
          },
          decoration: InputDecoration(
            labelText: 'Output folder',
            helperText: '…/$_outputHint/_collected/<name>/',
            errorText: _outputError,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        ...buildWaitAndExecute(busy: busy, onCancel: _onCancelPressed),
        const SizedBox(height: 8),
        statusRow(),
        if (result != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            key: const ValueKey('collect-result'),
            [
              result.path,
              if (result.excluded.isNotEmpty)
                'held out: ${result.excluded.join(', ')}',
              ...result.problems.take(3),
              if (result.problems.length > 3)
                '… ${result.problems.length - 3} more problems',
            ].join('\n'),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  String get _outputHint => _set.text.trim().isEmpty ? '<antelora>' : _set.text.trim();
}
