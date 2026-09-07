import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';
import '../backend_config.dart';

/// API client for the backend Load File node endpoint.
class LoadFileApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const LoadFileApi({this.baseUrl = BackendConfig.baseUrl, this.client});

  /// Load a file from the backend storage directory.
  ///
  /// Auto-detects Associative Array format based on schema metadata or column patterns.
  Future<LoadFileResponse> load({
    required String filePath,
    String schemaMode = 'auto',
  }) async {
    final payload = {
      'filePath': filePath,
      'schemaMode': schemaMode,
    };

    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/load'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Load failed: ${response.statusCode} - ${response.body}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return LoadFileResponse.fromJson(json);
    } finally {
      own?.close();
    }
  }
}

/// Response from the backend /load endpoint.
class LoadFileResponse {
  /// The loaded AA (if detected), or null.
  final AaPayload? aa;

  /// The raw file string, when the file has one — feeds the `contents` port.
  final String? contents;

  /// Raw data representation (dict/table). For a text file this is
  /// `{"text": contents}`; kept for tabular files, which have no raw string.
  final Map<String, dynamic> data;

  /// Detected payload type: "associative_array", "table", "text", "unknown".
  final String payloadType;

  /// Status message for UI display.
  final String message;

  LoadFileResponse({
    this.aa,
    this.contents,
    required this.data,
    required this.payloadType,
    required this.message,
  });

  factory LoadFileResponse.fromJson(Map<String, dynamic> json) {
    AaPayload? aa;
    final aaJson = json['parsedPayload'] ?? json['aa'];
    if (aaJson != null) {
      aa = AaPayload.fromJson(aaJson as Map<String, dynamic>);
    }

    return LoadFileResponse(
      aa: aa,
      contents: json['contents'] as String?,
      data: (json['data'] as Map<String, dynamic>?) ?? {},
      payloadType: json['payloadType'] as String? ?? json['payload_type'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
    );
  }
}
