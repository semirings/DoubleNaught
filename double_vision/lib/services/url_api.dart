import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';
import '../backend_config.dart';

/// Thin client for the URLNode routes on the DoubleTouch backend
/// (`double_touch/`), targeting the camelCase contract:
///
///  * `POST /url/validate` — `{url}` → `{url, reachable, statusCode, detail}`
///  * `POST /url/payload`  — `{nodeId, url, author, workTitle, validated}`
///    → `{nodeId, aa: {rows, cols, vals}}`
///
/// Like [Sam3Api] it only performs the calls and decodes the body — it holds no
/// UI state.
class UrlApi {
  /// Base URL of the backend. Matches [Sam3Api]'s default (the same
  /// DoubleTouch service hosts both the SAM3 and URL routes).
  final String baseUrl;

  const UrlApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Probe [url] for reachability (backend issues an HTTP HEAD request).
  Future<UrlValidateResult> validate(String url) async {
    final body = await _post('/url/validate', {'url': url});
    return UrlValidateResult(
      url: body['url'] as String? ?? url,
      reachable: body['reachable'] as bool? ?? false,
      statusCode: (body['statusCode'] as num?)?.toInt(),
      detail: body['detail'] as String?,
    );
  }

  /// Build the URLNode D4M/AA payload for the given node metadata. [validated]
  /// carries the result of a prior [validate] call into the AA's `validated`
  /// column. [workSelector] is optional — a marker ChunkNode uses to locate a
  /// specific work within a multi-work file (empty for single-work files).
  Future<AaPayload> payload({
    required String nodeId,
    required String url,
    required String author,
    required String workTitle,
    required bool validated,
    String workSelector = '',
  }) async {
    final body = await _post('/url/payload', {
      'nodeId': nodeId,
      'url': url,
      'author': author,
      'workTitle': workTitle,
      'workSelector': workSelector,
      'validated': validated,
    });
    return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw UrlApiException(path, response.statusCode, response.body);
  }
}

/// Result of a `/url/validate` reachability probe.
class UrlValidateResult {
  final String url;
  final bool reachable;

  /// HTTP status of the HEAD probe, or null when the request never completed.
  final int? statusCode;

  /// Reason string when unreachable (bad scheme, timeout, 4xx/5xx).
  final String? detail;

  const UrlValidateResult({
    required this.url,
    required this.reachable,
    this.statusCode,
    this.detail,
  });
}

/// Raised when a URL backend route returns a non-200 response.
class UrlApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  UrlApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'UrlApiException($path → $statusCode): $body';
}
