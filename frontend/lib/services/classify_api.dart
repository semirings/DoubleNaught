import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Thin client for the zero-shot **classification runner** on the DoubleTouch
/// backend (`backend/`), targeting the camelCase, AA-native contract:
///
///  * `POST /classify` — `{ model, sourceType, task, labels, categories?,
///    documents }` where `documents` is an rcvs AA (rows = document id, col
///    `text`, val = the text) → `{ aa }` where `aa` is the rcvs result AA: rows
///    = document id, cols = category labels, vals = scores. When `categories`
///    (an rcvs AA of `label` / `hypothesis_template` / `threshold` rows) is
///    supplied it supersedes `labels`, and the result gains a `passed` column.
///
/// Like the other clients it only performs the call and decodes the body — it
/// holds no UI state. The model identifier is passed through verbatim: for a
/// Hugging Face model that is the repo id (e.g.
/// `MoritzLaurer/ModernBERT-large-zeroshot-v2.0`); for a web/local model it is
/// the resolved URL or path.
class ClassifyApi {
  final String baseUrl;

  const ClassifyApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Future<AaPayload> classify({
    required String model,
    required String sourceType,
    required List<String> labels,
    required AaPayload documents,
    AaPayload? categories,
    String task = 'zero-shot-classification',
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/classify'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'model': model,
        'sourceType': sourceType,
        'task': task,
        'labels': labels,
        if (categories != null) 'categories': categories.toJson(),
        'documents': documents.toJson(),
      }),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
    }
    throw ClassifyApiException('/classify', response.statusCode, response.body);
  }
}

/// Raised when the classify route returns a non-200 response.
class ClassifyApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  ClassifyApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'ClassifyApiException($path → $statusCode): $body';
}
