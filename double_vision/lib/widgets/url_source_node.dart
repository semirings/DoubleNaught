import 'dart:async';

import 'package:flutter/material.dart';

import '../models/aa_payload.dart';
import '../models/workflow.dart';
import '../services/url_api.dart';
import 'double_naught_node_wrapper.dart';
import 'input_connector.dart';
import 'output_connector.dart';

/// A workflow **processing node** that receives a source entry from an upstream
/// [InventoryNode], displays it for confirmation, validates the URL's
/// reachability, and emits the D4M/AA payload (`url | author | work_title |
/// work_selector | validated | timestamp`) out of its `assocArray` output for a
/// downstream FetchNode.
///
/// Fields are no longer entered by hand — the incoming inventory entry supplies
/// them. Validate probes reachability and emits the payload with `validated`
/// reflecting the result.
class UrlSourceNode extends StatefulWidget {
  /// Graph metadata for this node (id/type/position).
  final WorkflowNode node;

  /// Upstream entry stream (from InventoryNode), or null when nothing is wired.
  final Stream<AaPayload>? aaInput;

  /// Called with the source endpoint when an edge is dropped on the input port.
  final void Function(PortRef source)? onInputConnect;

  /// Called once with the node's output stream — the `assocArray` connector.
  final void Function(Stream<AaPayload> assocArray)? onConnect;

  /// Output port indices with an outgoing edge — drives the connected-port
  /// highlight, matching every other node.
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final UrlApi api;

  const UrlSourceNode({
    super.key,
    required this.node,
    this.aaInput,
    this.onInputConnect,
    this.onConnect,
    this.connectedOutputs = const {},
    this.api = const UrlApi(),
  });

  @override
  State<UrlSourceNode> createState() => _UrlSourceNodeState();
}

class _UrlSourceNodeState extends State<UrlSourceNode> {
  StreamSubscription<AaPayload>? _inputSub;

  /// The incoming inventory entry, or null before one is selected upstream.
  AaPayload? _incoming;

  /// Broadcast output port, published in [initState] so a downstream node can
  /// attach before any payload exists; replays the last payload to late
  /// subscribers.
  late final StreamController<AaPayload> _output;
  AaPayload? _lastPayload;

  bool _isValidating = false;
  bool? _reachable;
  String? _statusText;
  String? _errorMessage;

  String get _url => _incoming?.value('url') ?? '';
  String get _author => _incoming?.value('author') ?? '';
  String get _workTitle => _incoming?.value('work_title') ?? '';
  String get _workSelector => _incoming?.value('work_selector') ?? '';
  String get _description => _incoming?.value('description') ?? '';

  bool get _canValidate =>
      !_isValidating &&
      _url.isNotEmpty &&
      _author.isNotEmpty &&
      _workTitle.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _output = StreamController<AaPayload>.broadcast(onListen: _replayLast);
    widget.onConnect?.call(_output.stream);
    _subscribeInput();
  }

  @override
  void didUpdateWidget(UrlSourceNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aaInput != widget.aaInput) _subscribeInput();
  }

  void _replayLast() {
    final payload = _lastPayload;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(payload);
    });
  }

  @override
  void dispose() {
    _inputSub?.cancel();
    _output.close();
    super.dispose();
  }

  /// (Re)subscribe to the upstream entry stream. A fresh entry resets the status
  /// so the user re-validates the new source.
  void _subscribeInput() {
    _inputSub?.cancel();
    _inputSub = widget.aaInput?.listen((payload) {
      if (!mounted) return;
      setState(() {
        _incoming = payload;
        _reachable = null;
        _statusText = null;
        _errorMessage = null;
      });
    });
  }

  /// Validate the URL (backend HEAD probe), then build and emit the AA payload
  /// with `validated` reflecting the probe result. Field values come from the
  /// incoming inventory entry.
  Future<void> _validate() async {
    if (!_canValidate) return;
    setState(() {
      _isValidating = true;
      _errorMessage = null;
      _statusText = null;
    });
    try {
      final result = await widget.api.validate(_url);
      final payload = await widget.api.payload(
        nodeId: '${widget.node.id}',
        url: _url,
        author: _author,
        workTitle: _workTitle,
        workSelector: _workSelector,
        validated: result.reachable,
      );
      if (!mounted) return;
      _lastPayload = payload;
      _output.add(payload);
      setState(() {
        _reachable = result.reachable;
        _statusText = result.reachable
            ? 'Reachable${result.statusCode != null ? ' (${result.statusCode})' : ''} · payload ready'
            : 'Unreachable${result.detail != null ? ': ${result.detail}' : ''} · payload emitted';
      });
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '$e');
    } finally {
      if (mounted) setState(() => _isValidating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wired = widget.aaInput != null;
    final hasPayload = _lastPayload != null;

    return DoubleNaughtNodeWrapper(
      title: 'URL Source',
      icon: Icons.link,
      inputPorts: [
        InputConnector(
          label: 'entry',
          idx: 0,
          active: wired,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'assocArray',
          idx: 0,
          active: hasPayload || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_incoming == null)
            Text(
              'Connect an Inventory node',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            )
          else ...[
            _confirmation(theme),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _canValidate ? _validate : null,
                icon: _isValidating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('Validate'),
              ),
            ),
            const SizedBox(height: 8),
            _buildStatus(theme),
          ],
        ],
      ),
    );
  }

  /// Read-only confirmation of the incoming inventory entry.
  Widget _confirmation(ThemeData theme) {
    Widget field(String label, String value, {bool mono = false}) {
      if (value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: RichText(
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: theme.textTheme.labelSmall,
            children: [
              TextSpan(
                text: '$label  ',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              TextSpan(
                text: value,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(_description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          field('author', _author),
          field('workTitle', _workTitle),
          field('workSelector', _workSelector),
          field('url', _url),
        ],
      ),
    );
  }

  /// Inline status: an error, or the reachability result once probed.
  Widget _buildStatus(ThemeData theme) {
    if (_errorMessage != null) {
      return Text(_errorMessage!,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12));
    }
    if (_statusText == null) return const SizedBox.shrink();
    final ok = _reachable == true;
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          size: 16,
          color: ok ? Colors.green : theme.colorScheme.error,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _statusText!,
            style: theme.textTheme.bodySmall?.copyWith(
                color: ok ? Colors.green : theme.colorScheme.error),
          ),
        ),
      ],
    );
  }
}
