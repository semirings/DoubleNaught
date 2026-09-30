import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/seg_forge_api.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Detects every speech balloon on a comic page and LaMa-scrubs them in one
/// automatic pass, via SegForge's `POST /balloon-scrub`.
///
/// Takes an image AA on `image` (the shape `Load File` emits for an image file:
/// a one-row AA with a `bytes_b64` cell) and emits an AA carrying the scrubbed
/// image plus the full per-detection audit list.
///
/// There is no per-detection human review anywhere in this flow, so the audit
/// rows are the only record of what was scrubbed and why — they are emitted
/// even when a detection produced no mask.
class BalloonScrubNode extends BaseNodeWidget {
  /// Backend client. Injectable for tests; defaults to the shared instance.
  final SegForgeApi api;

  const BalloonScrubNode({
    super.key,
    required super.node,
    super.inputConnected,
    super.onInputConnect,
    super.onInputPort,
    super.onOutputPort,
    super.connectedOutputs,
    this.api = const SegForgeApi(),
  });

  /// The scrub result as an AA: row `0` carries the scrubbed image and run
  /// metadata, and one `det_N` row per detection carries the audit entry.
  static AaPayload resultToAa(BalloonScrubResult r) {
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];

    void put(String row, String col, Object? val) {
      if (val == null) return;
      rows.add(row);
      cols.add(col);
      vals.add(val);
    }

    put('0', 'bytes_b64', base64Encode(r.imageBytes));
    put('0', 'format', 'png');
    put('0', 'width', r.width);
    put('0', 'height', r.height);
    put('0', 'session_id', r.sessionId);
    put('0', 'confidence_threshold', r.confidenceThreshold);
    put('0', 'scrubbed', r.scrubbed);
    put('0', 'detection_count', r.detections.length);

    for (var i = 0; i < r.detections.length; i++) {
      final d = r.detections[i];
      final row = 'det_$i';
      final box = d['box'];
      put(row, 'box', box is List ? box.join(',') : box);
      put(row, 'confidence', d['confidence']);
      put(row, 'cls', d['cls']);
      put(row, 'mask_id', d['mask_id']);
      put(row, 'note', d['note']);
    }

    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  @override
  State<BalloonScrubNode> createState() => _BalloonScrubNodeState();
}

class _BalloonScrubNodeState extends BaseNodeState<BalloonScrubNode> {
  @override String   get nodeTitle    => 'Balloon Scrub';
  @override IconData get nodeIcon     => Icons.auto_fix_high;
  @override String   get workingLabel => 'scrubbing';

  final InputPort  _in  = InputPort('image');
  final OutputPort _out = OutputPort('scrubbed');

  AaPayload? _incoming;
  AaPayload? _lastOutput;
  BalloonScrubResult? _result;

  /// Set when SegForge itself could not be reached, as opposed to a request it
  /// answered with an error. Confirmed repeatedly in this project that the SF
  /// backend can simply be down, so this is surfaced on the card rather than
  /// folded into a generic failure.
  String? _unreachable;

  bool get _canRun => _incoming != null && status != NodeStatus.working;

  @override
  void initState() {
    super.initState();
    initInputPort(_in, _onIncoming);
    initOutputPort(_out);
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _onIncoming(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incoming = payload;
      _result = null;
      _unreachable = null;
    });
    setIdle();
  }

  Uint8List? _imageBytesOf(AaPayload aa) {
    final b64 = aa.value('bytes_b64');
    if (b64 == null) return null;
    try {
      return base64Decode(b64.toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _run() async {
    final incoming = _incoming;
    if (incoming == null || status == NodeStatus.working) return;

    final bytes = _imageBytesOf(incoming);
    if (bytes == null) {
      setError('Input AA has no decodable `bytes_b64` image cell');
      return;
    }

    setState(() => _unreachable = null);
    setWorking();
    try {
      final result = await widget.api.balloonScrub(
        bytes,
        filename: incoming.value('file_path')?.toString().split('/').last ??
            'page.png',
      );
      if (!mounted) return;
      final aa = BalloonScrubNode.resultToAa(result);
      _lastOutput = aa;
      _out.emit(aa);
      setState(() => _result = result);
      setComplete();
    } on SocketException catch (e) {
      if (mounted) _reportUnreachable(e.message);
    } on http.ClientException catch (e) {
      if (mounted) _reportUnreachable(e.message);
    } catch (e) {
      if (mounted) setError(e);
    }
  }

  void _reportUnreachable(String detail) {
    setState(() => _unreachable = detail);
    setError('SegForge backend unreachable at ${widget.api.baseUrl}');
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'image',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'scrubbed',
          idx: 0,
          active: _lastOutput != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final busy = status == NodeStatus.working;
    final muted = theme.textTheme.bodySmall;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _incoming == null
              ? 'Connect an image source'
              : 'Image ready — ${_incoming!.value('format') ?? 'image'}',
          style: muted,
        ),
        const SizedBox(height: 12),

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _canRun ? _run : null,
            icon: busy ? busyIcon() : const Icon(Icons.auto_fix_high, size: 18),
            label: const Text('Scrub balloons'),
          ),
        ),

        if (_unreachable != null) ...[
          const SizedBox(height: 10),
          _unreachablePanel(theme),
        ],
        if (_result != null) ...[
          const SizedBox(height: 10),
          _resultPanel(theme, _result!),
        ],
        const SizedBox(height: 8),
        statusRow(),
      ],
    );
  }

  Widget _unreachablePanel(ThemeData theme) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off,
                    size: 16, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'SegForge backend unreachable',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.api.baseUrl}\n$_unreachable',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
      );

  Widget _resultPanel(ThemeData theme, BalloonScrubResult r) {
    final muted = theme.textTheme.bodySmall;
    final withMask =
        r.detections.where((d) => d['mask_id'] != null).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.scrubbed
                ? 'Scrubbed $withMask of ${r.detections.length} detections'
                : 'No detections — image returned unchanged',
            style: muted?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text('threshold ${r.confidenceThreshold}', style: muted),
          Text('session ${r.sessionId} (unsaved)', style: muted),
        ],
      ),
    );
  }
}
