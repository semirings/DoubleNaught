import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../backend_config.dart';

/// Client for `/generate`: Qwen-Image-2.1 text-to-image (optionally with a
/// LoRA and/or an init image) through mflux on the backend's machine.
class GenerateApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const GenerateApi({this.baseUrl = BackendConfig.baseUrl, this.client});

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

  Future<String> start({
    required String prompt,
    String model = '',
    int steps = 40,
    int size = 1024,
    int seed = 42,
    String lora = '',
    double loraScale = 1.0,
    String imageB64 = '',
    double imageStrength = 0.6,
    String mode = 'img2img',
    double editStrength = 1.0,
  }) =>
      _with((c) async {
        final r = await c.post(
          Uri.parse('$baseUrl/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'prompt': prompt,
            'model': model,
            'steps': steps,
            'width': size,
            'height': size,
            'seed': seed,
            'lora': lora,
            'loraScale': loraScale,
            'imageB64': imageB64,
            'imageStrength': imageStrength,
            'mode': mode,
            'editStrength': editStrength,
          }),
        );
        if (r.statusCode != 200) _fail('Generate', r);
        return '${(jsonDecode(r.body) as Map)['runId']}';
      });

  Future<GenerateStatus> status(String runId) => _with((c) async {
        final r = await c.get(Uri.parse('$baseUrl/generate/$runId'));
        if (r.statusCode != 200) _fail('Status', r);
        return GenerateStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      });

  Future<void> cancel(String runId) => _with((c) async {
        final r = await c.post(Uri.parse('$baseUrl/generate/$runId/cancel'));
        if (r.statusCode != 200) _fail('Cancel', r);
      });

  Future<Uint8List> image(String runId) => _with((c) async {
        final r = await c.get(Uri.parse('$baseUrl/generate/$runId/image'));
        if (r.statusCode != 200) _fail('Image', r);
        return r.bodyBytes;
      });
}

class GenerateStatus {
  final String status; // running | done | failed | cancelled
  final int step;
  final int total;
  final String path;
  final double? seconds;
  final String? error;

  const GenerateStatus({
    required this.status,
    required this.step,
    required this.total,
    required this.path,
    this.seconds,
    this.error,
  });

  factory GenerateStatus.fromJson(Map<String, dynamic> j) => GenerateStatus(
        status: '${j['status']}',
        step: (j['step'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        path: '${j['path'] ?? ''}',
        seconds: (j['seconds'] as num?)?.toDouble(),
        error: j['error'] as String?,
      );
}
