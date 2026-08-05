import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// Thin client for the ChunkNode route on the DoubleTouch backend
/// (`double_touch/`), targeting the camelCase contract:
///
///  * `POST /chunk` — `{aa: {rows, cols, vals}}` (the upstream FetchNode AA)
///    → `{aa: {...}, stats: {chunkCount, totalTokens, minTokens, maxTokens,
///      meanTokens}}`
///
/// Like the other clients it only performs the call and decodes the body — it
/// holds no UI state.
class ChunkApi {
  /// Base URL of the backend (the same DoubleTouch service hosts every route).
  final String baseUrl;

  const ChunkApi({this.baseUrl = 'http://localhost:8000'});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Chunk the cleaned text carried by [input] (a FetchNode AA payload),
  /// returning the passage AA plus summary [ChunkStats].
  Future<ChunkResult> chunk(AaPayload input) async {
    final response = await http.post(
      Uri.parse('$baseUrl/chunk'),
      headers: _jsonHeaders,
      body: jsonEncode({'aa': input.toJson()}),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return ChunkResult(
        aa: AaPayload.fromJson(body['aa'] as Map<String, dynamic>),
        stats: ChunkStats.fromJson(body['stats'] as Map<String, dynamic>),
      );
    }
    throw ChunkApiException('/chunk', response.statusCode, response.body);
  }
}

/// The passage AA plus its summary statistics.
class ChunkResult {
  final AaPayload aa;
  final ChunkStats stats;

  const ChunkResult({required this.aa, required this.stats});
}

/// Summary statistics for a chunking run (mirrors backend `ChunkStats`).
class ChunkStats {
  final int chunkCount;
  final int totalTokens;
  final int minTokens;
  final int maxTokens;
  final double meanTokens;

  const ChunkStats({
    required this.chunkCount,
    required this.totalTokens,
    required this.minTokens,
    required this.maxTokens,
    required this.meanTokens,
  });

  factory ChunkStats.fromJson(Map<String, dynamic> json) => ChunkStats(
        chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
        totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
        minTokens: (json['minTokens'] as num?)?.toInt() ?? 0,
        maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 0,
        meanTokens: (json['meanTokens'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Raised when the chunk route returns a non-200 response.
class ChunkApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  ChunkApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'ChunkApiException($path → $statusCode): $body';
}
