import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend_config.dart';

/// Client for `/vlm/*`: fine-tune a vision-language model (Qwen-VL) on a
/// collected loraset, and caption images with it.
class VlmApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const VlmApi({this.baseUrl = BackendConfig.baseUrl, this.client});

  static const defaultModel = 'mlx-community/Qwen2-VL-2B-Instruct-bf16';

  /// The prompt Collect Loraset trains with. Caption with the same one.
  static const defaultPrompt = 'Describe this image.';

  Future<T> _with<T>(Future<T> Function(http.Client c) fn) async {
    final own = client == null ? http.Client() : null;
    try {
      return await fn(client ?? own!);
    } finally {
      own?.close();
    }
  }

  static Never _fail(String what, http.Response r) {
    var detail = r.body;
    try {
      final d = (jsonDecode(r.body) as Map)['detail'];
      if (d != null) detail = '$d';
    } catch (_) {}
    throw Exception('$what failed: ${r.statusCode} - $detail');
  }

  Future<VlmTrainStarted> startTrain({
    required String dataset,
    String model = defaultModel,
    int epochs = 3,
    int rank = 8,
  }) =>
      _with((c) async {
        final r = await c.post(
          Uri.parse('$baseUrl/vlm/train'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'dataset': dataset,
            'model': model,
            'epochs': epochs,
            'rank': rank,
          }),
        );
        if (r.statusCode != 200) _fail('Training', r);
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return VlmTrainStarted('${j['runId']}', '${j['adapter']}');
      });

  Future<VlmTrainStatus> trainStatus(String runId) => _with((c) async {
        final r = await c.get(Uri.parse('$baseUrl/vlm/train/$runId'));
        if (r.statusCode != 200) _fail('Status', r);
        return VlmTrainStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      });

  Future<void> cancelTrain(String runId) => _with((c) async {
        final r = await c.post(Uri.parse('$baseUrl/vlm/train/$runId/cancel'));
        if (r.statusCode != 200) _fail('Cancel', r);
      });

  Future<String> caption({
    required String imageB64,
    String model = defaultModel,
    String adapter = '',
    String prompt = defaultPrompt,
  }) =>
      _with((c) async {
        final r = await c.post(
          Uri.parse('$baseUrl/vlm/caption'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'imageB64': imageB64,
            'model': model,
            'adapter': adapter,
            'prompt': prompt,
          }),
        );
        if (r.statusCode != 200) _fail('Caption', r);
        return '${(jsonDecode(r.body) as Map)['text']}';
      });
}

class VlmTrainStarted {
  final String runId;
  final String adapter;
  const VlmTrainStarted(this.runId, this.adapter);
}

class VlmTrainStatus {
  final String status; // running | done | failed | cancelled
  final int step;
  final int total;
  final String adapter;
  final String? error;

  const VlmTrainStatus({
    required this.status,
    required this.step,
    required this.total,
    required this.adapter,
    this.error,
  });

  factory VlmTrainStatus.fromJson(Map<String, dynamic> j) => VlmTrainStatus(
        status: '${j['status']}',
        step: (j['step'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        adapter: '${j['adapter'] ?? ''}',
        error: j['error'] as String?,
      );
}
