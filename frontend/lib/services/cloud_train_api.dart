import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend_config.dart';

/// Client for `/cloud-train/*`: train an image LoRA (Z-Image-Turbo, via
/// ai-toolkit) on Vertex AI. The cloud-backed sibling of [ImageTrainApi] —
/// same shape, no mid-run checkpoint export (the container only uploads the
/// adapter once the job finishes) and coarser status (Vertex AI reports
/// queued/running/succeeded/failed/cancelled, not a step count).
class CloudTrainApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const CloudTrainApi({this.baseUrl = BackendConfig.baseUrl, this.client});

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

  Future<CloudTrainStarted> start({
    required String dataset,
    int epochs = 20,
    int rank = 16,
    int resolution = 768,
    String trigger = '',
    bool quantize = false,
  }) =>
      _with((c) async {
        final r = await c.post(
          Uri.parse('$baseUrl/cloud-train'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'dataset': dataset,
            'epochs': epochs,
            'rank': rank,
            'resolution': resolution,
            'trigger': trigger,
            'quantize': quantize,
          }),
        );
        if (r.statusCode != 200) _fail('Cloud training', r);
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return CloudTrainStarted(
          runId: '${j['runId']}',
          adapter: '${j['adapter']}',
          images: (j['images'] as num?)?.toInt() ?? 0,
        );
      });

  Future<CloudTrainStatus> status(String runId) => _with((c) async {
        final r = await c.get(Uri.parse('$baseUrl/cloud-train/$runId'));
        if (r.statusCode != 200) _fail('Status', r);
        return CloudTrainStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      });

  Future<void> cancel(String runId) => _with((c) async {
        final r = await c.post(Uri.parse('$baseUrl/cloud-train/$runId/cancel'));
        if (r.statusCode != 200) _fail('Cancel', r);
      });
}

class CloudTrainStarted {
  final String runId;
  final String adapter;
  final int images;
  const CloudTrainStarted({
    required this.runId,
    required this.adapter,
    required this.images,
  });
}

class CloudTrainStatus {
  final String status; // queued | running | done | failed | cancelled
  final String adapter;
  final String? error;
  final int elapsed;

  const CloudTrainStatus({
    required this.status,
    required this.adapter,
    this.error,
    this.elapsed = 0,
  });

  factory CloudTrainStatus.fromJson(Map<String, dynamic> j) => CloudTrainStatus(
        status: '${j['status']}',
        adapter: '${j['adapter'] ?? ''}',
        error: j['error'] as String?,
        elapsed: (j['elapsed'] as num?)?.toInt() ?? 0,
      );
}
