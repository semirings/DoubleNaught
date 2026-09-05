import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';
import '../backend_config.dart';

/// Thin client for the FetchNode route on the DoubleTouch backend
/// (`backend/`), targeting the camelCase contract:
///
///  * `POST /fetch` — `{aa: {rows, cols, vals}}` (the upstream URLNode AA)
///    → `{aa: {rows, cols, vals}}` (a cleaned-text AA for ChunkNode)
///
/// Like [Sam3Api]/[UrlApi] it only performs the call and decodes the body — it
/// holds no UI state.
class FetchApi {
  /// Base URL of the backend. Matches the other clients (the same DoubleTouch
  /// service hosts the SAM3, URL, and fetch routes).
  final String baseUrl;

  const FetchApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Fetch and clean the text referenced by [input] (a URLNode AA payload),
  /// returning the resulting cleaned-text AA.
  Future<AaPayload> fetch(AaPayload input) async {
    final response = await http.post(
      Uri.parse('$baseUrl/fetch'),
      headers: _jsonHeaders,
      body: jsonEncode({'aa': input.toJson()}),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
    }
    throw FetchApiException('/fetch', response.statusCode, response.body);
  }
}

/// Raised when the fetch route returns a non-200 response.
class FetchApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  FetchApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'FetchApiException($path → $statusCode): $body';
}
