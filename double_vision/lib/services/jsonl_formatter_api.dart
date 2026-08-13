import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the JSONL Formatter node endpoint.
///
/// Uses `/jsonl/format/aa`, the wire-AA variant, because the canvas transports
/// AAs as JSON triples and Dart has no Arrow reader. The Arrow-native
/// `/jsonl/format` exists for the backend pipeline; both call the same formatter,
/// so the lines produced are identical either way.
///
/// This is the only JSONL formatting client. The deprecated `/aa2jsonl` route and
/// its `Aa2JsonlApi` remain for workflows saved before the consolidation.
class JsonlFormatterApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const JsonlFormatterApi({
    this.baseUrl = 'http://127.0.0.1:8000',
    this.client,
  });

  /// Format [aa] into training lines using [formatMode].
  Future<JsonlFormatResult> format(
    AaPayload aa, {
    String formatMode = 'chatml',
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/jsonl/format/aa'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'aa': aa.toJson(), 'formatMode': formatMode}),
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

  /// The mode the backend actually used, canonicalised.
  final String formatMode;

  final int lineCount;

  /// Rows with no generated docstring yet — the expected case mid-run.
  final int skippedNoDoc;

  /// Rows with a docstring but no source code to pair it with.
  final int skippedNoCode;

  /// Non-ChatML modes: rows lacking the fields the mode reads.
  final int skippedIncomplete;

  const JsonlFormatResult({
    required this.aa,
    required this.formatMode,
    required this.lineCount,
    required this.skippedNoDoc,
    required this.skippedNoCode,
    this.skippedIncomplete = 0,
  });

  int get skipped => skippedNoDoc + skippedNoCode + skippedIncomplete;

  factory JsonlFormatResult.fromJson(Map<String, dynamic> json) =>
      JsonlFormatResult(
        aa: AaPayload.fromJson(
          (json['aa'] as Map<String, dynamic>?) ?? const {},
        ),
        formatMode:
            (json['formatMode'] ?? json['format_mode'] ?? 'chatml') as String,
        lineCount: (json['lineCount'] ?? json['line_count'] ?? 0) as int,
        skippedNoDoc: (json['skippedNoDoc'] ?? json['skipped_no_doc'] ?? 0) as int,
        skippedNoCode:
            (json['skippedNoCode'] ?? json['skipped_no_code'] ?? 0) as int,
        skippedIncomplete:
            (json['skippedIncomplete'] ?? json['skipped_incomplete'] ?? 0) as int,
      );
}
