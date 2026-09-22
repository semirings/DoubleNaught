import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Thin client for the AA2JSONLNode route on the DoubleTouch backend
/// (`backend/`), targeting the camelCase contract:
///
///  * `POST /aa2jsonl` — `{aa, outputFile, format}` (the upstream ChunkNode AA)
///    → `{aa, stats: {linesWritten, skipped, outputFile, fileSizeBytes}}`
///
/// Like the other clients it only performs the call and decodes the body — it
/// holds no UI state.
class Aa2JsonlApi {
  /// Base URL of the backend (the same DoubleTouch service hosts every route).
  final String baseUrl;

  const Aa2JsonlApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Write [input] to a JSONL file at [outputFile] using [format]
  /// (`instruction-completion` | `continuation`), returning the provenance AA
  /// plus [Aa2JsonlStats].
  Future<Aa2JsonlResult> write(
    AaPayload input, {
    required String outputFile,
    required String format,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/aa2jsonl'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'aa': input.toJson(),
        'outputFile': outputFile,
        'format': format,
      }),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return Aa2JsonlResult(
        aa: AaPayload.fromJson(body['aa'] as Map<String, dynamic>),
        stats: Aa2JsonlStats.fromJson(body['stats'] as Map<String, dynamic>),
      );
    }
    throw Aa2JsonlApiException('/aa2jsonl', response.statusCode, response.body);
  }
}

/// The provenance AA plus write statistics.
class Aa2JsonlResult {
  final AaPayload aa;
  final Aa2JsonlStats stats;

  const Aa2JsonlResult({required this.aa, required this.stats});
}

/// Summary statistics for a write run (mirrors backend `Aa2JsonlStats`).
class Aa2JsonlStats {
  final int linesWritten;
  final int skipped;
  final String outputFile;
  final int fileSizeBytes;

  const Aa2JsonlStats({
    required this.linesWritten,
    required this.skipped,
    required this.outputFile,
    required this.fileSizeBytes,
  });

  factory Aa2JsonlStats.fromJson(Map<String, dynamic> json) => Aa2JsonlStats(
        linesWritten: (json['linesWritten'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        outputFile: json['outputFile'] as String? ?? '',
        fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
      );
}

/// Raised when the aa2jsonl route returns a non-200 response.
class Aa2JsonlApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  Aa2JsonlApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'Aa2JsonlApiException($path → $statusCode): $body';
}
