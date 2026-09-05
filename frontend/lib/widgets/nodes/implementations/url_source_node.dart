import 'dart:async';

import 'package:flutter/material.dart';

import '../base/base_node_widget.dart';

/// The manual entry point of the pipeline.
///
/// The user types a location — a web address or a local file path — and sends
/// it downstream as a raw string on `locationOutput`. It performs no lookup and
/// holds no catalog of its own; cataloguing is the Inventory node's job, which
/// persists whatever arrives here into `inventory.json`.
class UrlSourceNode extends BaseNodeWidget {
  /// Called once with the node's output stream — the `locationOutput` port.
  final void Function(Stream<String> locationOutput)? onConnect;

  const UrlSourceNode({
    super.key,
    required super.node,
    this.onConnect,
    super.connectedOutputs,
  });

  @override
  State<UrlSourceNode> createState() => _UrlSourceNodeState();
}

class _UrlSourceNodeState extends BaseNodeState<UrlSourceNode> {
  @override String   get nodeTitle => 'URL Source';
  @override IconData get nodeIcon  => Icons.link;

  final TextEditingController locationController = TextEditingController();

  /// Broadcast output, published in [initState] so a downstream node can attach
  /// before anything is sent; replays the last location to late subscribers.
  late final StreamController<String> _output;
  String? _lastSent;

  bool get _canSend => locationController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _output = StreamController<String>.broadcast(onListen: _replayLast);
    widget.onConnect?.call(_output.stream);
  }

  @override
  void dispose() {
    locationController.dispose();
    _output.close();
    super.dispose();
  }

  void _replayLast() {
    final last = _lastSent;
    if (last == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(last);
    });
  }

  void _send() {
    final location = locationController.text.trim();
    if (location.isEmpty) return;
    _output.add(location);
    setState(() => _lastSent = location);
  }

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'locationOutput',
          idx: 0,
          hasData: _lastSent != null,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: locationController,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _send(),
          style: theme.textTheme.bodySmall,
          decoration: const InputDecoration(
            hintText: 'Web address or local file path',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canSend ? _send : null,
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Send to Inventory'),
          ),
        ),
        if (_lastSent != null) ...[
          const SizedBox(height: 8),
          Text(
            'Sent $_lastSent',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
