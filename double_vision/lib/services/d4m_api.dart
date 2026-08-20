import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// Result from [D4mApi.ingest]: server-side handle id + entry count.
class D4mIngestResult {
  final String handleId;
  final int nnz;

  const D4mIngestResult({required this.handleId, required this.nnz});

  factory D4mIngestResult.fromJson(Map<String, dynamic> j) =>
      D4mIngestResult(handleId: j['handleId'] as String, nnz: j['nnz'] as int);
}

/// Result from [D4mApi.exec]: output handle + shape metadata.
class D4mExecResult {
  final String handleId;
  final int numRows;
  final int numCols;
  final int nnz;

  const D4mExecResult({
    required this.handleId,
    required this.numRows,
    required this.numCols,
    required this.nnz,
  });

  factory D4mExecResult.fromJson(Map<String, dynamic> j) => D4mExecResult(
        handleId: j['handleId'] as String,
        numRows: j['numRows'] as int,
        numCols: j['numCols'] as int,
        nnz: j['nnz'] as int,
      );
}

/// Result from [D4mApi.preview]: paginated AA slice + total count.
class D4mPreviewResult {
  final String handleId;
  final int page;
  final int pageSize;
  final int totalNnz;
  final AaPayload aa;

  const D4mPreviewResult({
    required this.handleId,
    required this.page,
    required this.pageSize,
    required this.totalNnz,
    required this.aa,
  });

  factory D4mPreviewResult.fromJson(Map<String, dynamic> j) => D4mPreviewResult(
        handleId: j['handleId'] as String,
        page: j['page'] as int,
        pageSize: j['pageSize'] as int,
        totalNnz: j['totalNnz'] as int,
        aa: AaPayload.fromJson(j['aa'] as Map<String, dynamic>),
      );
}

/// Client for the D4M routes on the DoubleTouch backend.
///
/// Three interaction patterns:
///  1. [eval] — legacy single-expression eval (full AA payloads).
///  2. [ingest] + [exec] — handle-based multi-line script execution.
///  3. [preview] — paginated AA slice from a stored handle.
class D4mApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const D4mApi({this.baseUrl = 'http://localhost:8000', this.client});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  // Exec can trigger Julia cold-start precompilation; allow up to 3 minutes.
  static const _execTimeout = Duration(minutes: 3);
  // Ingest and preview are pure Python — should be fast.
  static const _fastTimeout = Duration(seconds: 30);

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    required Duration timeout,
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      return await transport
          .post(
            Uri.parse('$baseUrl$path'),
            headers: _jsonHeaders,
            body: jsonEncode(body),
          )
          .timeout(timeout,
              onTimeout: () =>
                  throw D4mApiException(path, 408, 'Request timed out'));
    } finally {
      own?.close();
    }
  }

  /// Legacy: evaluate a single D4M expression over full AA inputs.
  Future<AaPayload> eval({
    required Map<String, AaPayload> inputs,
    required String expression,
  }) async {
    final response = await _post('/d4m/eval', {
      'inputs': {
        for (final entry in inputs.entries) entry.key: entry.value.toJson(),
      },
      'expression': expression,
    }, timeout: _execTimeout);
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
    }
    throw D4mApiException('/d4m/eval', response.statusCode, response.body);
  }

  /// Store an AA in the server-side handle store; returns handle id + nnz.
  Future<D4mIngestResult> ingest(AaPayload aa) async {
    final response = await _post(
      '/d4m/ingest',
      {'aa': aa.toJson()},
      timeout: _fastTimeout,
    );
    if (response.statusCode == 200) {
      return D4mIngestResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw D4mApiException('/d4m/ingest', response.statusCode, response.body);
  }

  /// Execute a multi-line Julia D4M script over handle-referenced inputs.
  ///
  /// [inputs] maps Julia variable names to handle ids from prior [ingest]
  /// calls. Returns a [D4mExecResult] with the output handle and shape.
  /// Allows up to 3 minutes for Julia cold-start precompilation.
  Future<D4mExecResult> exec({
    required Map<String, String> inputs,
    required String script,
    required String outputSymbol,
  }) async {
    final response = await _post('/d4m/exec', {
      'inputs': inputs,
      'script': script,
      'outputSymbol': outputSymbol,
    }, timeout: _execTimeout);
    if (response.statusCode == 200) {
      return D4mExecResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw D4mApiException('/d4m/exec', response.statusCode, response.body);
  }

  /// Fetch a paginated slice of the AA identified by [handleId].
  Future<D4mPreviewResult> preview({
    required String handleId,
    int page = 0,
    int pageSize = 200,
  }) async {
    final response = await _post('/d4m/preview', {
      'handleId': handleId,
      'page': page,
      'pageSize': pageSize,
    }, timeout: _fastTimeout);
    if (response.statusCode == 200) {
      return D4mPreviewResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw D4mApiException('/d4m/preview', response.statusCode, response.body);
  }
}

/// Raised when a D4M backend route returns a non-200 response.
class D4mApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  D4mApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'D4mApiException($path → $statusCode): $body';
}
