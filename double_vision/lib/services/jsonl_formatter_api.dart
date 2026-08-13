import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the JSONL Formatter node endpoint.
///
/// Uses `/jsonl/format/aa`, the wire-AA variant, because the canvas transports
/// AAs as JSON triples and Dart has no Arrow reader. The Arrow-native
/// `/jsonl/format` exists for the backend pipeline; both call the same formatter,
/// so the lines produced are identical either way.
class JsonlFormatterApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const JsonlFormatterApi({
    this.baseUrl = 'http://127.0.0.1:8000',
    this.client,
  });

  /// Format the documented index [aa] into ChatML training lines.
  Future<JsonlFormatResult> format(AaPayload aa) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/jsonl/format/aa'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'aa': aa.toJson()}),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Format failed: ${response.statusCode} - ${response.body}',
        );
      }
      return JsonlFormatResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

/// One formatting pass: the 2-column result plus what was left out.
class JsonlFormatResult {
  /// `json_line` / `symbol_name`, one row per training example.
  final AaPayload aa;

  final int lineCount;

  /// Rows with no generated docstring yet — the expected case mid-run.
  final int skippedNoDoc;

  /// Rows with a docstring but no source code to pair it with.
  final int skippedNoCode;

  const JsonlFormatResult({
    required this.aa,
    required this.lineCount,
    required this.skippedNoDoc,
    required this.skippedNoCode,
  });

  int get skipped => skippedNoDoc + skippedNoCode;

  factory JsonlFormatResult.fromJson(Map<String, dynamic> json) =>
      JsonlFormatResult(
        aa: AaPayload.fromJson(
          (json['aa'] as Map<String, dynamic>?) ?? const {},
        ),
        lineCount: (json['lineCount'] ?? json['line_count'] ?? 0) as int,
        skippedNoDoc: (json['skippedNoDoc'] ?? json['skipped_no_doc'] ?? 0) as int,
        skippedNoCode:
            (json['skippedNoCode'] ?? json['skipped_no_code'] ?? 0) as int,
      );
}
