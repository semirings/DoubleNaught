import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the backend Polyglot Exec node endpoint (`POST /exec`).
///
/// A failing snippet is not an error here: a non-zero exit, a timeout and a
/// missing interpreter all come back as a 200 with a [PolyglotExecResult.status]
/// of `FAILED` / `TIMEOUT`, because the node emits the failure downstream rather
/// than swallowing it. Only a malformed *request* throws.
class PolyglotExecApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const PolyglotExecApi({
    this.baseUrl = 'http://127.0.0.1:8000',
    this.client,
  });

  /// Run [code] — or the source carried on [aa] — under the interpreter for
  /// [language] (`''` or `'auto'` to let the backend infer it).
  ///
  /// The wall-clock budget is [timeoutS] on the backend; the HTTP call itself is
  /// given a little longer, so a snippet that runs to its own deadline returns a
  /// `TIMEOUT` result instead of failing as a dead connection.
  Future<PolyglotExecResult> run({
    AaPayload? aa,
    String? code,
    String language = '',
    String? filePath,
    List<String> args = const [],
    double timeoutS = 30,
  }) async {
    final body = jsonEncode({
      if (aa != null) 'executionPayload': aa.toJson(),
      if (code != null) 'code': code,
      'language': language,
      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,
      if (args.isNotEmpty) 'args': args,
      'timeoutS': timeoutS,
    });

    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport
          .post(
            Uri.parse('$baseUrl/exec'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(Duration(milliseconds: (timeoutS * 1000).round() + 10000));

      if (response.statusCode != 200) {
        throw Exception('Exec failed: ${response.statusCode} - ${response.body}');
      }
      return PolyglotExecResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

/// One execution's outcome, as the backend's `PolyglotExecResponse` describes it.
class PolyglotExecResult {
  /// The 1×8 result matrix — what goes downstream.
  final AaPayload executionResult;

  /// `SUCCESS` | `FAILED` | `TIMEOUT`.
  final String status;
  final String language;
  final String stdout;
  final String stderr;
  final int exitCode;
  final double executionTimeMs;

  const PolyglotExecResult({
    required this.executionResult,
    required this.status,
    required this.language,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.executionTimeMs,
  });

  bool get ok => status == 'SUCCESS';

  factory PolyglotExecResult.fromJson(Map<String, dynamic> json) =>
      PolyglotExecResult(
        executionResult: AaPayload.fromJson(
          (json['executionResult'] as Map<String, dynamic>?) ?? const {},
        ),
        status: json['status'] as String? ?? 'FAILED',
        language: json['language'] as String? ?? '',
        stdout: json['stdout'] as String? ?? '',
        stderr: json['stderr'] as String? ?? '',
        exitCode: (json['exitCode'] ?? json['exit_code'] ?? -1) as int,
        executionTimeMs:
            ((json['executionTimeMs'] ?? json['execution_time_ms'] ?? 0) as num)
                .toDouble(),
      );
}
