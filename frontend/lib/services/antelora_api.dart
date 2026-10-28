import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Client for `/antelora/save`: writes `storage/antelora/<set>/<page>/` —
/// `metadata.jsonl` plus one PNG per segment — from the LLM caption AA.
class AnteloraApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const AnteloraApi({this.baseUrl = BackendConfig.baseUrl, this.client});

  Future<AnteloraSaveResult> save(AaPayload captions, {required String antelora}) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/antelora/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'captions': captions.toJson(), 'antelora': antelora}),
      );
      if (response.statusCode != 200) {
        throw Exception('Save failed: ${response.statusCode} - ${response.body}');
      }
      return AnteloraSaveResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

extension AnteloraCollectApi on AnteloraApi {
  /// Saved pages of [antelora]: name and image count, alphabetical.
  Future<List<AnteloraPageInfo>> listPages(String antelora) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/antelora/pages').replace(queryParameters: {'antelora': antelora}),
      );
      if (response.statusCode != 200) {
        throw Exception('List failed: ${response.statusCode} - ${response.body}');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return [
        for (final p in (body['pages'] as List? ?? const []))
          AnteloraPageInfo(
            '${(p as Map)['page']}',
            (p['images'] as num?)?.toInt() ?? 0,
          ),
      ];
    } finally {
      own?.close();
    }
  }

  /// Merge the saved pages (minus [exclude]) into one flat training folder.
  Future<AnteloraCollectResult> collect(
    String antelora, {
    List<String> exclude = const [],
    String output = 'train',
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/antelora/collect'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'antelora': antelora, 'exclude': exclude, 'output': output}),
      );
      if (response.statusCode != 200) {
        throw Exception('Collect failed: ${response.statusCode} - ${response.body}');
      }
      return AnteloraCollectResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

class AnteloraPageInfo {
  final String name;
  final int images;
  const AnteloraPageInfo(this.name, this.images);
}

class AnteloraCollectResult {
  final String path;
  final List<String> pages;
  final List<String> excluded;
  final int images;
  final int skipped;
  final List<String> problems;

  const AnteloraCollectResult({
    required this.path,
    required this.pages,
    required this.excluded,
    required this.images,
    required this.skipped,
    required this.problems,
  });

  factory AnteloraCollectResult.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? v) =>
        [for (final x in (v as List? ?? const [])) '$x'];
    return AnteloraCollectResult(
      path: '${json['path'] ?? ''}',
      pages: strings(json['pages']),
      excluded: strings(json['excluded']),
      images: (json['images'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      problems: strings(json['problems']),
    );
  }
}

class AnteloraSaveResult {
  final String antelora;
  final int images;
  final int skipped;
  final String path;
  final List<String> pages;

  const AnteloraSaveResult({
    required this.antelora,
    required this.images,
    required this.skipped,
    required this.path,
    required this.pages,
  });

  factory AnteloraSaveResult.fromJson(Map<String, dynamic> json) =>
      AnteloraSaveResult(
        antelora: '${json['antelora'] ?? ''}',
        images: (json['images'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        path: '${json['path'] ?? ''}',
        pages: [
          for (final p in (json['pages'] as List? ?? const []))
            '${(p as Map)['page']}',
        ],
      );
}
