import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the backend Save File node endpoint.
class SaveFileApi {
  final String baseUrl;

  const SaveFileApi({this.baseUrl = 'http://127.0.0.1:8000'});

  /// Save AA, text, or image data to the backend storage/out/ directory.
  ///
  /// Exactly one of [aa], [text], or [imageBase64] must be provided.
  Future<SaveFileResponse> save({
    AaPayload? aa,
    String? text,
    String? imageBase64,
    required String filename,
    String format = 'parquet',
  }) async {
    final payload = {
      'aa': aa?.toJson(),
      'text': text,
      'imageBase64': imageBase64,
      'filename': filename,
      'format': format,
    };

    final response = await http.post(
      Uri.parse('$baseUrl/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Save failed: ${response.statusCode} - ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SaveFileResponse.fromJson(json);
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
