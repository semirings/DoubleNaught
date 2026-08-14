import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';

/// API client for the AST Extract node endpoint.
///
/// Uses `/ast/extract/aa`, the wire-AA variant, because the canvas transports AAs
/// as JSON triples and Dart has no Arrow reader. The Arrow-native `/ast/extract`
/// exists for the backend pipeline; both run the same Julia script, so the index is
/// identical either way.
class AstExtractApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const AstExtractApi({
    this.baseUrl = 'http://127.0.0.1:8000',
    this.client,
  });

  /// Index every function and macro under [rootPath] — a directory or a single
  /// `.jl` file.
  ///
  /// [timeoutS] is generous by default: a cold Julia plus loading Arrow.jl costs a
  /// couple of seconds before any parsing starts.
  Future<AstExtractResult> extract(
    String rootPath, {
    double timeoutS = 180,
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport
          .post(
            Uri.parse('$baseUrl/ast/extract/aa'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'rootPath': rootPath, 'timeoutS': timeoutS}),
          )
          .timeout(Duration(milliseconds: (timeoutS * 1000).round() + 15000));

      if (response.statusCode != 200) {
        throw Exception(
          'Extract failed: ${response.statusCode} - ${response.body}',
        );
      }
      return AstExtractResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

/// One extraction: the 7-column index plus what happened while building it.
class AstExtractResult {
  /// `symbol_name` · `kind` · `file_path` · `line_range` · `docstring` ·
  /// `raw_code` · `better_docstring`, one row per definition.
  final AaPayload aa;

  final int definitionCount;
  final int filesScanned;

  /// Files the walk skipped — a broken file is reported, never fatal.
  final List<String> errors;

  /// The root as the extractor resolved it.
  final String root;

  const AstExtractResult({
    required this.aa,
    required this.definitionCount,
    required this.filesScanned,
    this.errors = const [],
    this.root = '',
  });

  factory AstExtractResult.fromJson(Map<String, dynamic> json) =>
      AstExtractResult(
        aa: AaPayload.fromJson(
          (json['aa'] as Map<String, dynamic>?) ?? const {},
        ),
        definitionCount:
            (json['definitionCount'] ?? json['definition_count'] ?? 0) as int,
        filesScanned: (json['filesScanned'] ?? json['files_scanned'] ?? 0) as int,
        errors: [
          for (final e in (json['errors'] as List? ?? const [])) '$e',
        ],
        root: (json['root'] ?? '') as String,
      );

  /// How many definitions of each kind — `{function: 150, macro: 5}`.
  Map<String, int> get kindCounts {
    final counts = <String, int>{};
    final sparse = aa.toSparse();
    for (var i = 0; i < sparse.cols.length; i++) {
      if (sparse.cols[i] != 'kind') continue;
      final kind = '${sparse.vals[i]}';
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    return counts;
  }
}
