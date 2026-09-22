import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Thin client for `POST /tokenize` on the DoubleTouch backend.
///
/// Sends a chunk AA and an encoding name; receives a token-id AA plus
/// summary statistics.
class TokenizerApi {
  final String baseUrl;

  const TokenizerApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};
  static const _timeout = Duration(minutes: 5);

  Future<TokenizeResult> tokenize(
    AaPayload aa, {
    String encoding = 'gpt2',
    String textCol = 'text',
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/tokenize'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'aa': aa.toJson(),
            'encoding': encoding,
            'textCol': textCol,
          }),
        )
        .timeout(_timeout,
            onTimeout: () => throw TokenizerApiException(
                '/tokenize', 408, 'Request timed out'));
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return TokenizeResult.fromJson(body);
    }
    throw TokenizerApiException('/tokenize', response.statusCode, response.body);
  }
}

class TokenizeResult {
  final AaPayload aa;
  final String encoding;
  final int vocabSize;
  final int totalTokens;
  final int chunkCount;

  const TokenizeResult({
    required this.aa,
    required this.encoding,
    required this.vocabSize,
    required this.totalTokens,
    required this.chunkCount,
  });

  factory TokenizeResult.fromJson(Map<String, dynamic> j) => TokenizeResult(
        aa: AaPayload.fromJson(j['aa'] as Map<String, dynamic>),
        encoding: j['encoding'] as String,
        vocabSize: (j['vocabSize'] as num).toInt(),
        totalTokens: (j['totalTokens'] as num).toInt(),
        chunkCount: (j['chunkCount'] as num).toInt(),
      );
}

class TokenizerApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  TokenizerApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'TokenizerApiException($path → $statusCode): $body';
}
