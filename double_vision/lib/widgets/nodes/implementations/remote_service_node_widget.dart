import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';

/// Enriches an AST index with LLM-generated better_docstring column.
///
/// Takes the 7-column documented index from AST Extract, calls the backend
/// `/llm/enrich-ast` endpoint to generate improved docstrings via LLM, and
/// emits the enriched index (8 columns) downstream.
///
/// Ports: `astIndex` (idx 0) is the 7-column input, `enrichedIndex` (idx 0)
/// is the 8-column output with better_docstring added.
class RemoteServiceNodeWidget extends BaseNodeWidget {
  final String? baseUrl;
  final http.Client Function() clientFactory;

  const RemoteServiceNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    super.onOutputPort,
    super.connectedOutputs,
    this.baseUrl,
    this.clientFactory = http.Client.new,
  });

  @override
  State<RemoteServiceNodeWidget> createState() =>
      _RemoteServiceNodeWidgetState();
}

class _RemoteServiceNodeWidgetState
    extends BaseNodeState<RemoteServiceNodeWidget> {
  @override
  String get nodeTitle => 'Remote Service';
  @override
  IconData get nodeIcon => Icons.cloud_sync_outlined;
  @override
  double get nodeWidth => 320;
  @override
  String get workingLabel => 'enriching';

  late final InputPort _in;
  final OutputPort _out = OutputPort('enrichedIndex');

  late TextEditingController _modelId;
  late TextEditingController _maxTokens;
  late TextEditingController _temperature;

  AaPayload? _incoming;
  bool _busy = false;
  String? _detail;

  @override
  void initState() {
    super.initState();
    _in = InputPort('astIndex');
    initInputPort(_in, _onIngress);
    initOutputPort(_out);

    _modelId = TextEditingController(
      text: widget.initialParams?['modelId'] ??
          'mlx-community/Phi-4-mini-instruct-4bit',
    );
    _maxTokens = TextEditingController(
      text: widget.initialParams?['maxTokens'] ?? '256',
    );
    _temperature = TextEditingController(
      text: widget.initialParams?['temperature'] ?? '0.7',
    );
  }

  @override
  void dispose() {
    _modelId.dispose();
    _maxTokens.dispose();
    _temperature.dispose();
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  void _persist() => saveParams({
        'modelId': _modelId.text.trim(),
        'maxTokens': _maxTokens.text.trim(),
        'temperature': _temperature.text.trim(),
      });

  void _onIngress(AaPayload payload) {
    if (!mounted) return;
    setState(() => _incoming = payload);
    setIdle();
  }

  Future<void> _enrich() async {
    final payload = _incoming;
    if (payload == null || _busy) return;

    setState(() => _busy = true);
    setWorking();

    try {
      final maxTokens = int.tryParse(_maxTokens.text.trim()) ?? 256;
      final temperature = double.tryParse(_temperature.text.trim()) ?? 0.7;
      final modelId = _modelId.text.trim();

      if (modelId.isEmpty) {
        setState(() {
          _busy = false;
          _detail = 'Model ID cannot be empty';
        });
        setError('Model ID required');
        return;
      }

      final url = Uri.parse(
          '${widget.baseUrl ?? "http://localhost:8000"}/llm/enrich-ast');
      final client = widget.clientFactory();

      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'astIndex': {
            'rows': payload.rows,
            'cols': payload.cols,
            'vals': payload.vals,
          },
          'modelId': modelId,
          'maxTokens': maxTokens,
          'temperature': temperature,
        });

      final response = await client.send(request);
      final body = await response.stream.bytesToString();

      if (!mounted) return;

      if (response.statusCode != 200) {
        final detail = jsonDecode(body)['detail'] ?? 'HTTP ${response.statusCode}';
        setState(() {
          _busy = false;
          _detail = detail;
        });
        setError(detail);
        return;
      }

      final result = jsonDecode(body);
      final enrichedAa = AaPayload(
        rows: List<String>.from(result['enrichedIndex']['rows'] ?? []),
        cols: List<String>.from(result['enrichedIndex']['cols'] ?? []),
        vals: List.from(result['enrichedIndex']['vals'] ?? []),
      );

      if (!mounted) return;

      setState(() {
        _busy = false;
        _detail =
            '${result["rowsProcessed"] ?? 0} rows · ${enrichedAa.cols.length} cols';
      });

      _out.emit(enrichedAa);
      setComplete(detail: _detail);
      client.close();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _detail = e.toString();
      });
      setError(e);
    }
  }

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'astIndex'),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        singleOutputConnector(
          label: 'enrichedIndex',
          idx: 0,
          hasData: status == NodeStatus.complete,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        if (_incoming == null) ...[
          Text(
            'Waiting for astIndex — wire an AST Extract node',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ] else ...[
          Text(
            'Input: ${_incoming!.distinctRows().length} rows × '
            '${_incoming!.cols.length} cols',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _modelId,
          enabled: !_busy,
          onChanged: (_) => _persist(),
          decoration: const InputDecoration(
            labelText: 'Model ID',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 1,
              child: TextField(
                controller: _maxTokens,
                enabled: !_busy,
                onChanged: (_) => _persist(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Tokens',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _temperature,
                enabled: !_busy,
                onChanged: (_) => _persist(),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Temperature',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            onPressed: _incoming != null && !_busy ? _enrich : null,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined, size: 18),
            label: Text(_busy ? 'Enriching…' : 'Enrich with LLM'),
          ),
        ),
        const SizedBox(height: 10),
        statusRow(),
        if (_detail != null) ...[
          const SizedBox(height: 6),
          Text(
            _detail!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: status == NodeStatus.error
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
