import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// Thin HTTP client for the text-inference routes on the DoubleTouch backend.
///
/// Routes covered:
///  * `GET  /text/health` → [TextHealthResult]
///  * `POST /text/load`   → [TextLoadResult]
///  * `POST /text/infer`  → [TextInferResult]
///
/// All request/response bodies are camelCase JSON — the same convention the
/// rest of the `double_touch` API uses.  Each method performs the HTTP call
/// and decodes the body; no UI state is held here.
class TextInferenceApi {
  final String baseUrl;

  const TextInferenceApi({this.baseUrl = 'http://localhost:8000'});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  // ---------------------------------------------------------------------------
  // Health
  // ---------------------------------------------------------------------------

  /// Snapshot of the text-engine status (backend name, mlx availability,
  /// which model is currently loaded).
  Future<TextHealthResult> health() async {
    final response = await http.get(Uri.parse('$baseUrl/text/health'));
    if (response.statusCode == 200) {
      return TextHealthResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw TextApiException('/text/health', response.statusCode, response.body);
  }

  // ---------------------------------------------------------------------------
  // Model load
  // ---------------------------------------------------------------------------

  /// Load (or warm from cache) a generative text model.
  ///
  /// [modelId] is an HF repo id (e.g. `"microsoft/phi-4-mini-instruct"`) or
  /// an absolute local path to an mlx checkpoint directory.
  /// [loraPath] is optional; pass `""` for no adapter.
  Future<TextLoadResult> loadModel(String modelId, {String loraPath = ''}) async {
    final body = jsonEncode({'modelId': modelId, 'loraPath': loraPath});
    final response = await http.post(
      Uri.parse('$baseUrl/text/load'),
      headers: _jsonHeaders,
      body: body,
    );
    if (response.statusCode == 200) {
      return TextLoadResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw TextApiException('/text/load', response.statusCode, response.body);
  }

  // ---------------------------------------------------------------------------
  // Inference
  // ---------------------------------------------------------------------------

  /// Run generative inference.
  ///
  /// [modelHandle] is the AA emitted by [loadModel] (carries `model_id`).
  /// [prompt] is the ChatML AA emitted by TextPromptNode.
  /// [params] carries generation hyper-parameters; defaults apply when null.
  Future<TextInferResult> generate({
    required AaPayload modelHandle,
    required AaPayload prompt,
    TextGenParams params = const TextGenParams(),
  }) async {
    final body = jsonEncode({
      'modelHandle': modelHandle.toJson(),
      'prompt': prompt.toJson(),
      'params': params.toJson(),
    });
    final response = await http.post(
      Uri.parse('$baseUrl/text/infer'),
      headers: _jsonHeaders,
      body: body,
    );
    if (response.statusCode == 200) {
      return TextInferResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw TextApiException('/text/infer', response.statusCode, response.body);
  }
}

// ---------------------------------------------------------------------------
// Data classes (mirrors backend pydantic models)
// ---------------------------------------------------------------------------

/// Health snapshot for the text-inference subsystem.
class TextHealthResult {
  final String backend;        // "mlx-lm" | "stub"
  final bool mlxAvailable;
  final String? loadedModelId;

  const TextHealthResult({
    required this.backend,
    required this.mlxAvailable,
    this.loadedModelId,
  });

  factory TextHealthResult.fromJson(Map<String, dynamic> json) =>
      TextHealthResult(
        backend: json['backend'] as String? ?? 'stub',
        mlxAvailable: json['mlxAvailable'] as bool? ?? false,
        loadedModelId: json['loadedModelId'] as String?,
      );
}

/// Result of a successful model load.
class TextLoadResult {
  /// Model-handle AA — emitted on the `modelHandle` output port.
  final AaPayload handle;
  final TextLoadStats stats;

  const TextLoadResult({required this.handle, required this.stats});

  factory TextLoadResult.fromJson(Map<String, dynamic> json) => TextLoadResult(
        handle: AaPayload.fromJson(json['handle'] as Map<String, dynamic>),
        stats: TextLoadStats.fromJson(json['stats'] as Map<String, dynamic>),
      );
}

/// Timing / metadata from a /text/load call.
class TextLoadStats {
  final String modelId;
  final String backend;
  final int contextLength;
  final String loraPath;
  final String loadedAt;

  const TextLoadStats({
    required this.modelId,
    required this.backend,
    required this.contextLength,
    required this.loraPath,
    required this.loadedAt,
  });

  factory TextLoadStats.fromJson(Map<String, dynamic> json) => TextLoadStats(
        modelId: json['modelId'] as String? ?? '',
        backend: json['backend'] as String? ?? 'stub',
        contextLength: (json['contextLength'] as num?)?.toInt() ?? 4096,
        loraPath: json['loraPath'] as String? ?? '',
        loadedAt: json['loadedAt'] as String? ?? '',
      );
}

/// Generation hyper-parameters sent to /text/infer.
class TextGenParams {
  final int maxTokens;
  final double temperature;
  final double topP;
  final double repetitionPenalty;

  const TextGenParams({
    this.maxTokens = 512,
    this.temperature = 0.7,
    this.topP = 0.95,
    this.repetitionPenalty = 1.1,
  });

  Map<String, dynamic> toJson() => {
        'maxTokens': maxTokens,
        'temperature': temperature,
        'topP': topP,
        'repetitionPenalty': repetitionPenalty,
      };
}

/// Result of a successful inference call.
class TextInferResult {
  /// Result AA (row `result:<uuid12>`) — emitted on `resultOut` output port.
  final AaPayload result;
  final TextInferenceMetrics metrics;

  const TextInferResult({required this.result, required this.metrics});

  factory TextInferResult.fromJson(Map<String, dynamic> json) => TextInferResult(
        result: AaPayload.fromJson(json['result'] as Map<String, dynamic>),
        metrics: TextInferenceMetrics.fromJson(
            json['metrics'] as Map<String, dynamic>),
      );
}

/// Latency and throughput counters from /text/infer.
class TextInferenceMetrics {
  final String modelId;
  final int inputTokens;
  final int outputTokens;
  final double tokensPerSec;
  final String stopReason;
  final double generationTimeMs;

  const TextInferenceMetrics({
    required this.modelId,
    required this.inputTokens,
    required this.outputTokens,
    required this.tokensPerSec,
    required this.stopReason,
    required this.generationTimeMs,
  });

  factory TextInferenceMetrics.fromJson(Map<String, dynamic> json) =>
      TextInferenceMetrics(
        modelId: json['modelId'] as String? ?? '',
        inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
        tokensPerSec: (json['tokensPerSec'] as num?)?.toDouble() ?? 0.0,
        stopReason: json['stopReason'] as String? ?? 'eos',
        generationTimeMs: (json['generationTimeMs'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Raised when a text-inference route returns a non-200 response.
class TextApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  const TextApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'TextApiException($path → $statusCode): $body';
}
