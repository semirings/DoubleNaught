import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// Thin client for the ``POST /normalize`` route on the DoubleTouch backend.
///
/// Sends a normalization request and returns metadata about the written Arrow
/// binary cache plus a provenance [AaPayload] for the downstream port bus.
class AaBinaryNormalizerApi {
  final String baseUrl;

  const AaBinaryNormalizerApi({this.baseUrl = 'http://localhost:8000'});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Normalize [filePath] to a persistent Arrow cache in [outputDirectory].
  ///
  /// Returns [AaBinaryNormalizeResult] — the metadata AA plus key stats.
  /// Throws [AaBinaryNormalizerApiException] on non-200 responses.
  Future<AaBinaryNormalizeResult> normalize({
    required String filePath,
    required String outputDirectory,
    String splitName = 'train',
    bool keepInMemory = false,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/normalize'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'filePath':        filePath,
        'outputDirectory': outputDirectory,
        'splitName':       splitName,
        'keepInMemory':    keepInMemory,
      }),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return AaBinaryNormalizeResult.fromJson(body);
    }
    throw AaBinaryNormalizerApiException(
      '/normalize',
      response.statusCode,
      response.body,
    );
  }
}

/// Result returned by a successful normalization call.
class AaBinaryNormalizeResult {
  final AaPayload aa;
  final String arrowFilePath;
  final int rowCount;
  final Map<String, String> columnSchema;
  final bool isMemoryMapped;

  const AaBinaryNormalizeResult({
    required this.aa,
    required this.arrowFilePath,
    required this.rowCount,
    required this.columnSchema,
    required this.isMemoryMapped,
  });

  factory AaBinaryNormalizeResult.fromJson(Map<String, dynamic> json) =>
      AaBinaryNormalizeResult(
        aa:             AaPayload.fromJson(json['aa'] as Map<String, dynamic>),
        arrowFilePath:  json['arrowFilePath'] as String? ?? '',
        rowCount:       (json['rowCount'] as num?)?.toInt() ?? 0,
        columnSchema: (json['columnSchema'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, v.toString())) ??
            const {},
        isMemoryMapped: json['isMemoryMapped'] as bool? ?? false,
      );
}

/// Raised when the ``/normalize`` route returns a non-200 response.
class AaBinaryNormalizerApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  const AaBinaryNormalizerApiException(this.path, this.statusCode, this.body);

  @override
  String toString() =>
      'AaBinaryNormalizerApiException($path → $statusCode): $body';
}
