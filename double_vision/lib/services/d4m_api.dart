import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// Thin client for the D4M expression evaluation route on the DoubleTouch
/// backend (`POST /d4m/eval`).
///
/// Sends a map of named input AAs and a D4M expression string; returns the
/// result as an [AaPayload].  All serialisation uses the shared rcvs.json
/// contract (camelCase `rows`/`cols`/`vals`).
class D4mApi {
  final String baseUrl;

  const D4mApi({this.baseUrl = 'http://localhost:8000'});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Future<AaPayload> eval({
    required Map<String, AaPayload> inputs,
    required String expression,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/d4m/eval'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'inputs': {
          for (final entry in inputs.entries) entry.key: entry.value.toJson(),
        },
        'expression': expression,
      }),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
    }
    throw D4mApiException('/d4m/eval', response.statusCode, response.body);
  }
}

/// Raised when the `/d4m/eval` route returns a non-200 response.
class D4mApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  D4mApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'D4mApiException($path → $statusCode): $body';
}
