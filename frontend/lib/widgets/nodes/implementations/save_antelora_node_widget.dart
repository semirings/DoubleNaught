import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/antelora_api.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/output_connector.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// Writes LoRA training pages: `storage/antelora/<set>/<page>/metadata.jsonl`
/// plus one PNG per segment, from the LLM node's caption output.
///
/// One input, `captions` (idx 0). There is nothing to choose: the page folder
/// comes from the source image name, the lines from the improved captions.
/// Saving a page replaces its folder, so a re-run never leaves stale files.
class SaveAnteloraNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/antelora/save` endpoint.
  final AnteloraApi? api;

  const SaveAnteloraNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.api,
  });

  @override
  State<SaveAnteloraNodeWidget> createState() => _SaveAnteloraNodeWidgetState();
}

class _SaveAnteloraNodeWidgetState extends BaseNodeState<SaveAnteloraNodeWidget>
    with WaitGatedExecution<SaveAnteloraNodeWidget> {
  @override String   get nodeTitle    => 'Save Antelora';
  @override IconData get nodeIcon     => Icons.photo_library_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'saving';

  static const String _defaultSet = 'mccay';

  late final AnteloraApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('dir');
  late final TextEditingController _set;

  AaPayload? _incoming;
  AnteloraSaveResult? _result;
  http.Client? _execClient;
  int _execGen = 0;

  @override
  bool get isReady => _incoming != null && _nameError == null;

  /// The field is a single folder name. Pages and `metadata.jsonl` are made
  /// for you, so a path (`mccay/page_000/metadata.jsonl`) is refused.
  String? get _nameError {
    final name = _set.text.trim();
    if (name.isEmpty) return 'Enter a folder name';
    if (RegExp(r'[\\/]').hasMatch(name)) {
      return 'Just a name, e.g. mccay — pages and metadata.jsonl are created for you';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const AnteloraApi();
    _set = TextEditingController(
      text: widget.initialParams?['antelora'] ?? _defaultSet,
    )..addListener(() {
        saveParams({'antelora': _set.text.trim()});
        if (mounted) setState(() {});
      });
    initOutputPort(_out);
    _in = InputPort('captions');
    initInputPort(_in, _onIngress);
    _in.onDisconnected.listen((_) => _dropIncoming());
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _set.dispose();
    _execClient?.close();
    super.dispose();
  }

  void _dropIncoming() {
    if (!mounted || (_incoming == null && _result == null)) return;
    setState(() {
      _incoming = null;
      _result = null;
    });
    setIdle();
  }

  void _onIngress(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _result = null; // a new payload invalidates the last save's summary
    });
    maybeAutoFire();
  }

  @override
  void fire() => _save();

  Future<void> _save() async {
    final payload = _incoming;
    if (payload == null || !isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api = owns ? AnteloraApi(baseUrl: _api.baseUrl, client: client) : _api;

    try {
      final result = await api.save(payload, antelora: _set.text.trim());
      if (gen != _execGen || !mounted) return;
      setState(() => _result = result);
      final pages = result.pages.length;
      setComplete(
        detail: '${result.images} images · $pages page${pages == 1 ? '' : 's'}',
      );
      // The antelora folder, for Collect Antelora's `dir` port.
      _out.emit(AaPayload(
        rows: const ['antelora', 'antelora'],
        cols: const ['antelora', 'path'],
        vals: [result.antelora, result.path],
      ));
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  /// Execute renders as Cancel while working: hard abort, as for every node.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) =>
      [singleInputConnector(label: 'captions')];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'dir',
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
        TextField(
          key: const ValueKey('antelora-name'),
          controller: _set,
          enabled: !busy,
          decoration: InputDecoration(
            labelText: 'Antelora',
            helperText: 'storage/antelora/<name>/<page>/',
            errorText: _nameError,
            errorMaxLines: 3,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
        if (result != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            key: const ValueKey('antelora-result'),
            '${result.pages.join(', ')}\n${result.path}'
            '${result.skipped > 0 ? '\n${result.skipped} rows skipped' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
