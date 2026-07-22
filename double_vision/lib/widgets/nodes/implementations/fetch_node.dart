import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/fetch_api.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Lifecycle of a fetch operation, surfaced by the status indicator.
enum FetchStatus { idle, fetching, complete, error }

/// A workflow **processing node** (AA-in → AA-out, per `DESIGN.md`): it consumes
/// the D4M/AA payload emitted by an upstream [UrlSourceNode], fetches the text
/// content at that URL via the backend, strips Project Gutenberg boilerplate
/// when present, and emits a cleaned-text AA out of its `rawText` output for a
/// downstream ChunkNode.
///
/// Input handling follows the input-node convention (see `preview_node.dart` /
/// `sam3_node.dart`): subscribe to [aaInput] in [initState], re-subscribe in
/// [didUpdateWidget] when the wired stream changes, cancel in [dispose]. Output
/// handling follows the source-node convention (see `url_source_node.dart`): a
/// broadcast port published to [onConnect] in [initState], replaying the last
/// payload to late subscribers.
class FetchNode extends StatefulWidget {
  /// Graph metadata for this node (id/type/position).
  final WorkflowNode node;

  /// Upstream AA stream wired into the input, or null when nothing is connected.
  final Stream<AaPayload>? aaInput;

  /// Called with the source endpoint when an edge is dropped on the input port.
  final void Function(PortRef source)? onInputConnect;

  /// Called once with the node's output stream — the `rawText` connector.
  final void Function(Stream<AaPayload> rawText)? onConnect;

  /// Output port indices with an outgoing edge — drives the connected-port
  /// highlight, matching every other node.
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final FetchApi api;

  const FetchNode({
    super.key,
    required this.node,
    this.aaInput,
    this.onInputConnect,
    this.onConnect,
    this.connectedOutputs = const {},
    this.api = const FetchApi(),
  });

  @override
  State<FetchNode> createState() => _FetchNodeState();
}

class _FetchNodeState extends State<FetchNode> {
  StreamSubscription<AaPayload>? _inputSub;

  /// The most recent AA payload received from upstream, or null.
  AaPayload? _incoming;

  /// Broadcast output port. Created in [initState] so [onConnect] can hand it to
  /// downstream nodes before any fetch runs; its onListen replays the last
  /// emitted payload to late subscribers.
  late final StreamController<AaPayload> _output;

  /// The most recent payload emitted, retained for replay + the char count.
  AaPayload? _lastOutput;

  FetchStatus _status = FetchStatus.idle;
  String? _error;

  bool get _canFetch => _incoming != null && _status != FetchStatus.fetching;

  @override
  void initState() {
    super.initState();
    _output = StreamController<AaPayload>.broadcast(onListen: _replayLast);
    widget.onConnect?.call(_output.stream);
    _subscribeInput();
  }

  @override
  void didUpdateWidget(FetchNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aaInput != widget.aaInput) _subscribeInput();
  }

  @override
  void dispose() {
    _inputSub?.cancel();
    _output.close();
    super.dispose();
  }

  void _replayLast() {
    final payload = _lastOutput;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(payload);
    });
  }

  /// (Re)subscribe to the upstream AA stream. A fresh upstream payload resets
  /// the node to idle so the user can re-fetch for the new URL.
  void _subscribeInput() {
    _inputSub?.cancel();
    _inputSub = widget.aaInput?.listen((payload) {
      if (!mounted) return;
      setState(() {
        _incoming = payload;
        _status = FetchStatus.idle;
        _error = null;
      });
    });
  }

  Future<void> _fetch() async {
    final incoming = _incoming;
    if (incoming == null || _status == FetchStatus.fetching) return;
    setState(() {
      _status = FetchStatus.fetching;
      _error = null;
    });
    try {
      final result = await widget.api.fetch(incoming);
      if (!mounted) return;
      _lastOutput = result;
      _output.add(result);
      setState(() => _status = FetchStatus.complete);
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = FetchStatus.error;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wired = widget.aaInput != null;
    final hasOutput = _lastOutput != null;

    return DoubleNaughtNodeWrapper(
      title: 'Fetch',
      icon: Icons.cloud_download_outlined,
      inputPorts: [
        InputConnector(
          label: 'assocArray',
          idx: 0,
          active: wired,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'rawText',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _upstreamInfo(theme),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canFetch ? _fetch : null,
              icon: _status == FetchStatus.fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: const Text('Fetch'),
            ),
          ),
          const SizedBox(height: 8),
          _statusIndicator(theme),
        ],
      ),
    );
  }

  /// The incoming URL + metadata pulled from the upstream AA payload.
  Widget _upstreamInfo(ThemeData theme) {
    final incoming = _incoming;
    if (incoming == null) {
      return Text(
        'Connect a URL Source',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final url = incoming.value('url') ?? '(no url)';
    final author = incoming.value('author');
    final workTitle = incoming.value('work_title');
    final facts = <String>[
      if (workTitle != null && workTitle.isNotEmpty) workTitle,
      if (author != null && author.isNotEmpty) author,
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

  /// Status dot + label: idle | fetching | complete | error. On completion,
  /// appends the cleaned-text character count from the emitted AA.
  Widget _statusIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (color, label) = switch (_status) {
      FetchStatus.idle => (scheme.outline, 'idle'),
      FetchStatus.fetching => (scheme.primary, 'fetching'),
      FetchStatus.complete => (Colors.green, 'complete'),
      FetchStatus.error => (scheme.error, 'error'),
    };

    final charCount = _lastOutput?.value('char_count');
    final detail = switch (_status) {
      FetchStatus.complete when charCount != null => ' · $charCount chars',
      FetchStatus.error when _error != null => ' · $_error',
      _ => '',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label$detail',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
