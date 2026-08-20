import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../services/ast_extract_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// Indexes every function and macro in a Julia source tree — see `DESIGN.md` →
/// "Function Extraction node".
///
/// Ports: `codebase` (in) supplies the path to parse, `functions` (out) carries
/// the 7-column definition index. This node has no free-text field of its own —
/// per the finalized UX spec it operates purely on its wired input port.
///
/// It **parses**, it does not run. `Polyglot Exec` is the node that executes a
/// file; this one reads it and answers "what does it define?".
class FunctionExtractionNodeWidget extends BaseNodeWidget {
  /// Backend seam; defaults to the local `/ast/extract/aa` endpoint.
  final AstExtractApi? api;

  const FunctionExtractionNodeWidget({
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
  State<FunctionExtractionNodeWidget> createState() => _FunctionExtractionNodeWidgetState();
}

class _FunctionExtractionNodeWidgetState
    extends BaseNodeState<FunctionExtractionNodeWidget>
    with WaitGatedExecution<FunctionExtractionNodeWidget> {
  @override String   get nodeTitle    => 'Function Extraction';
  @override IconData get nodeIcon     => Icons.account_tree_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'parsing';

  /// Columns an upstream AA may carry the path under. `Load File` sends
  /// `file_path` alongside a source file's text.
  static const _pathColumns = [
    'file_path',
    'filepath',
    'path',
    'root',
    'root_path',
    'rootpath',
    'file',
  ];

  late final AstExtractApi _api;
  late final InputPort _in;
  final OutputPort _out = OutputPort('functions');

  /// Path taken from `codebase`, if the arriving AA carries one.
  String? _upstreamPath;
  AaPayload? _incomingPayload;
  AstExtractResult? _result;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely stop
  /// watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state.
  int _execGen = 0;

  bool get _hasIncomingPath {
    if (_incomingPayload == null) return false;
    final aa = _incomingPayload!.toSparse();
    for (final col in aa.cols) {
      final normCol = col.replaceAll('-', '_').toLowerCase();
      if (_pathColumns.contains(normCol)) return true;
    }
    return false;
  }

  bool get _hasText {
    if (_incomingPayload == null) return false;
    return _incomingPayload!.cols.contains('text') ||
        _incomingPayload!.cols.contains('raw_text');
  }

  @override
  bool get isReady => _hasIncomingPath || _hasText;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const AstExtractApi();
    _in = InputPort('codebase');
    initInputPort(_in, _onIngress);
    _in.onDisconnected.listen((_) => _dropIncoming());
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _execClient?.close();
    super.dispose();
  }

  /// Drop the retained payload when the `codebase` wire is cut or re-pointed,
  /// so [isReady] genuinely reflects "is there live data to act on" rather
  /// than lingering on a since-disconnected upstream's last delivery.
  void _dropIncoming() {
    if (!mounted || (_upstreamPath == null && _incomingPayload == null)) return;
    setState(() {
      _upstreamPath = null;
      _incomingPayload = null;
      _result = null;
    });
    setIdle();
  }

  /// Read a path out of the arriving payload.
  ///
  /// Only a path is taken, never the text: the extractor parses files on disk, so
  /// handing it source over the wire would mean writing a temp file to read it
  /// straight back.
  void _onIngress(AaPayload payload) {
    if (!mounted) return;

    String? found;
    for (var i = 0; i < payload.cols.length && i < payload.vals.length; i++) {
      final column = payload.cols[i].replaceAll('-', '_').toLowerCase();
      if (!_pathColumns.contains(column)) continue;
      final value = '${payload.vals[i]}'.trim();
      if (value.isNotEmpty) {
        found = value;
        break;
      }
    }
    setState(() {
      _upstreamPath = found;
      _incomingPayload = payload;
      // A new payload invalidates the previous index.
      _result = null;
    });
    maybeAutoFire();
  }

  @override
  void fire() => _extract();

  Future<void> _extract() async {
    if (!isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api =
        owns ? AstExtractApi(baseUrl: _api.baseUrl, client: client) : _api;

    try {
      final res = await api.extract(_upstreamPath ?? '', parsedPayload: _incomingPayload);
      if (gen != _execGen || !mounted) return;

      setState(() => _result = res);

      if (res.definitionCount == 0) {
        setError('No definitions found in ${(_upstreamPath ?? '').split('/').last}');
      } else {
        _out.emit(res.aa);
        setComplete(detail: '${res.definitionCount} definitions');
      }
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard abort:
  /// state flips to idle synchronously, right here, not after any awaited
  /// step notices a flag. `_execGen` guards the in-flight run's own awaits
  /// against then clobbering that idle state if the request still resolves
  /// in the background.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'codebase'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'functions',
          idx: 0,
          hasData: (_result?.definitionCount ?? 0) > 0,
        ),
      ];

  // ── Body ─────────────────────────────────────────────────────────────────

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
        if (_result case final result?) ...[
          const SizedBox(height: 6),
          _summary(theme, scheme, result),
        ],
      ],
    );
  }

  /// What was found: totals, then the breakdown by kind — the answer to "did it
  /// see my macros?" without opening the panel.
  Widget _summary(ThemeData theme, ColorScheme scheme, AstExtractResult result) {
    final kinds = result.kindCounts;
    final breakdown = [
      for (final entry in kinds.entries) '${entry.value} ${entry.key}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The count itself is the status row's job (`done · N definitions`);
        // repeating it here said the same thing twice on one card.
        Text(
          '${result.filesScanned} file${result.filesScanned == 1 ? '' : 's'} scanned',
          style: theme.textTheme.labelSmall?.copyWith(
            color: result.definitionCount > 0 ? Colors.green : scheme.error,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (breakdown.isNotEmpty)
          Text(
            breakdown,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (result.errors.isNotEmpty)
          Text(
            '${result.errors.length} file(s) skipped',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          ),
      ],
    );
  }
}
