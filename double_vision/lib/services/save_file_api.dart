import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the backend Save File node endpoints.
class SaveFileApi {
  final String baseUrl;

  /// Injected in tests, and by the node for hard-abort Cancel
  /// (`UX_UI/GLOBAL_UX_CONTRACT.md` §2). When null, each call uses (and
  /// closes) its own client.
  final http.Client? client;

  const SaveFileApi({
    this.baseUrl = 'http://127.0.0.1:8000',
    this.client,
  });

  /// Save AA, text, or image data to [url] (a `file://` URL — see
  /// `IOSupport`), or under the backend's storage/out/ directory via the
  /// legacy [filename].
  ///
  /// Exactly one of [aa], [text], or [imageBase64] must be provided.
  Future<SaveFileResponse> save({
    AaPayload? aa,
    String? text,
    String? imageBase64,
    String? url,
    String filename = 'export',
    String format = 'parquet',
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'aa': aa?.toJson(),
          'text': text,
          'imageBase64': imageBase64,
          'url': url,
          'filename': filename,
          'format': format,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Save failed: ${response.statusCode} - ${response.body}',
        );
      }

      return SaveFileResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }

  /// Cancel's cleanup follow-up: best-effort removal of whatever an
  /// abandoned [save] call might have written before the wait was aborted
  /// (see `save_file.delete_output` on the backend for why this is needed —
  /// the write itself can't be interrupted mid-flight). Never throws on "no
  /// file was there" — that is the expected common case, not a failure.
  Future<bool> cancelCleanup({
    String? url,
    String filename = 'export',
    String format = 'parquet',
    required String payloadKind,
    bool hasJsonlColumn = false,
  }) async {
    // Reuses the injected [client] like [save] does — closing it on Cancel
    // (`_execClient?.close()`) is harmless: `http.BaseClient.close()` is a
    // no-op unless a concrete client overrides it, and the real
    // `http.Client()` this falls back to in production is always the
    // ephemeral one [save] itself created, never a long-lived shared one.
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/save/cancel'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': url,
          'filename': filename,
          'format': format,
          'payloadKind': payloadKind,
          'hasJsonlColumn': hasJsonlColumn,
        }),
      );
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['removed'] as bool?) ?? false;
    } catch (_) {
      // Best-effort: a cleanup call that itself fails to reach the backend
      // must not surface as a user-facing error on top of a cancel that
      // already completed from the UI's perspective.
      return false;
    } finally {
      own?.close();
    }
  }
}

/// Response from the backend /save endpoint.
class SaveFileResponse {
  /// Absolute path of the saved file on the backend.
  final String filePath;

  /// Byte size of the written file.
  final int bytesWritten;

  /// Status message for UI display.
  final String message;

  SaveFileResponse({
    required this.filePath,
    required this.bytesWritten,
    required this.message,
  });

  factory SaveFileResponse.fromJson(Map<String, dynamic> json) =>
      SaveFileResponse(
        filePath: json['filePath'] as String? ?? json['file_path'] as String,
        bytesWritten: json['bytesWritten'] as int? ?? json['bytes_written'] as int,
        message: json['message'] as String,
      );
}
