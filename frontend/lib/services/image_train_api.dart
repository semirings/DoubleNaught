import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend_config.dart';

/// Client for `/image-train/*`: train an image LoRA (Z-Image-Turbo, via mflux)
/// on a collected antelora.
class ImageTrainApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const ImageTrainApi({this.baseUrl = BackendConfig.baseUrl, this.client});

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

  Future<ImageTrainStarted> start({
    required String dataset,
    int epochs = 20,
    int rank = 16,
    int resolution = 768,
    String trigger = '',
    int quantize = 0,
  }) =>
      _with((c) async {
        final r = await c.post(
          Uri.parse('$baseUrl/image-train'),
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
        if (r.statusCode != 200) _fail('Training', r);
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return ImageTrainStarted(
          runId: '${j['runId']}',
          adapter: '${j['adapter']}',
          images: (j['images'] as num?)?.toInt() ?? 0,
          total: (j['total'] as num?)?.toInt() ?? 0,
        );
      });

  Future<ImageTrainStatus> status(String runId) => _with((c) async {
        final r = await c.get(Uri.parse('$baseUrl/image-train/$runId'));
        if (r.statusCode != 200) _fail('Status', r);
        return ImageTrainStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      });

  /// Write the newest checkpoint's adapter out now, while training continues.
  Future<ImageTrainStatus> exportNow(String runId) => _with((c) async {
        final r = await c.post(Uri.parse('$baseUrl/image-train/$runId/export'));
        if (r.statusCode != 200) _fail('Checkpoint', r);
        return ImageTrainStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      });

  Future<void> cancel(String runId) => _with((c) async {
        final r = await c.post(Uri.parse('$baseUrl/image-train/$runId/cancel'));
        if (r.statusCode != 200) _fail('Cancel', r);
      });
}

class ImageTrainStarted {
  final String runId;
  final String adapter;
  final int images;
  final int total;
  const ImageTrainStarted({
    required this.runId,
    required this.adapter,
    required this.images,
    required this.total,
  });
}

class ImageTrainStatus {
  final String status; // running | done | failed | cancelled
  final int step;
  final int total;
  final String adapter;
  final int iteration;
  final int checkpoints;
  final String? error;
  final List<String> lines;

  const ImageTrainStatus({
    required this.status,
    required this.step,
    required this.total,
    required this.adapter,
    required this.iteration,
    required this.checkpoints,
    this.error,
    this.lines = const [],
  });

  factory ImageTrainStatus.fromJson(Map<String, dynamic> j) => ImageTrainStatus(
        status: '${j['status']}',
        step: (j['step'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        adapter: '${j['adapter'] ?? ''}',
        iteration: (j['iteration'] as num?)?.toInt() ?? 0,
        checkpoints: (j['checkpoints'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
        lines: ((j['lines'] as List?) ?? const []).map((e) => '$e').toList(),
      );
}
