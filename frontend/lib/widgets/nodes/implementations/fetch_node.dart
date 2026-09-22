import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/fetch_api.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A workflow **processing node** (AA-in → AA-out, per `DESIGN.md`): it consumes
/// the D4M/AA payload emitted by an upstream [UrlSourceNode], fetches the text
/// content at that URL via the backend, strips Project Gutenberg boilerplate
/// when present, and emits a cleaned-text AA out of its `rawText` output for a
/// downstream ChunkNode.
class FetchNode extends BaseNodeWidget {
  /// Backend client. Injectable for tests; defaults to the shared instance.
  final FetchApi api;

  const FetchNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const FetchApi(),
  });

  @override
  State<FetchNode> createState() => _FetchNodeState();
}

class _FetchNodeState extends BaseNodeState<FetchNode> {
  @override String   get nodeTitle    => 'Fetch';
  @override IconData get nodeIcon     => Icons.cloud_download_outlined;
  @override String   get workingLabel => 'fetching';

  final InputPort  _in  = InputPort('workMetadata');
  final OutputPort _out = OutputPort('rawText');

  AaPayload? _incoming;
  AaPayload? _lastOutput;

  Timer?  _autoTimer;
  String? _lastFetchedUrl;

  bool get _canFetch => _incoming != null && status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() => _incoming = payload);
    setIdle();
    _maybeAutoFetch();
  }

  void _maybeAutoFetch() {
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || !_canFetch) return;
      final url = _incoming?.value('url');
      if (url == null || url.isEmpty || url == _lastFetchedUrl) return;
      _fetch();
    });
  }

  Future<void> _fetch() async {
    final incoming = _incoming;
    if (incoming == null || status == NodeStatus.working) return;
    setWorking();
    try {
      final result = await widget.api.fetch(incoming);
      if (!mounted) return;
      _lastOutput = result;
      _lastFetchedUrl = incoming.value('url');
      _out.emit(result);
      final charCount = result.value('char_count');
      setComplete(detail: charCount != null ? '$charCount chars' : null);
    } catch (e) {
      if (mounted) setError(e);
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'workMetadata',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'rawText',
          idx: 0,
          active: _lastOutput != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _upstreamInfo(theme),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canFetch ? _fetch : null,
            icon: status == NodeStatus.working
                ? busyIcon()
                : const Icon(Icons.download, size: 18),
            label: const Text('Fetch'),
          ),
        ),
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a URL Source',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final url       = incoming.value('url') ?? '(no url)';
    final author    = incoming.value('author');
    final workTitle = incoming.value('work_title');
    final facts = <String>[
      if (workTitle != null && workTitle.isNotEmpty) workTitle,
      if (author    != null && author.isNotEmpty)    author,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          url,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (facts.isNotEmpty)
          Text(
            facts.join('  •  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}
