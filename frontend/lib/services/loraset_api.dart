import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Client for `/loraset/save`: writes `storage/loraset/<set>/<page>/` —
/// `metadata.jsonl` plus one PNG per segment — from the LLM caption AA.
class LorasetApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const LorasetApi({this.baseUrl = BackendConfig.baseUrl, this.client});

  Future<LorasetSaveResult> save(AaPayload captions, {required String loraset}) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/loraset/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'captions': captions.toJson(), 'loraset': loraset}),
      );
      if (response.statusCode != 200) {
        throw Exception('Save failed: ${response.statusCode} - ${response.body}');
      }
      return LorasetSaveResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

extension LorasetCollectApi on LorasetApi {
  /// Saved pages of [loraset]: name and image count, alphabetical.
  Future<List<LorasetPageInfo>> listPages(String loraset) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/loraset/pages').replace(queryParameters: {'loraset': loraset}),
      );
      if (response.statusCode != 200) {
        throw Exception('List failed: ${response.statusCode} - ${response.body}');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return [
        for (final p in (body['pages'] as List? ?? const []))
          LorasetPageInfo(
            '${(p as Map)['page']}',
            (p['images'] as num?)?.toInt() ?? 0,
          ),
      ];
    } finally {
      own?.close();
    }
  }

  /// Merge the saved pages (minus [exclude]) into one flat training folder.
  Future<LorasetCollectResult> collect(
    String loraset, {
    List<String> exclude = const [],
    String output = 'train',
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/loraset/collect'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'loraset': loraset, 'exclude': exclude, 'output': output}),
      );
      if (response.statusCode != 200) {
        throw Exception('Collect failed: ${response.statusCode} - ${response.body}');
      }
      return LorasetCollectResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }
}

class LorasetPageInfo {
  final String name;
  final int images;
  const LorasetPageInfo(this.name, this.images);
}

class LorasetCollectResult {
  final String path;
  final List<String> pages;
  final List<String> excluded;
  final int images;
  final int skipped;
  final List<String> problems;

  const LorasetCollectResult({
    required this.path,
    required this.pages,
    required this.excluded,
    required this.images,
    required this.skipped,
    required this.problems,
  });

  factory LorasetCollectResult.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? v) =>
        [for (final x in (v as List? ?? const [])) '$x'];
    return LorasetCollectResult(
      path: '${json['path'] ?? ''}',
      pages: strings(json['pages']),
      excluded: strings(json['excluded']),
      images: (json['images'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      problems: strings(json['problems']),
    );
  }
}

class LorasetSaveResult {
  final String loraset;
  final int images;
  final int skipped;
  final String path;
  final List<String> pages;

  const LorasetSaveResult({
    required this.loraset,
    required this.images,
    required this.skipped,
    required this.path,
    required this.pages,
  });

  factory LorasetSaveResult.fromJson(Map<String, dynamic> json) =>
      LorasetSaveResult(
        loraset: '${json['loraset'] ?? ''}',
        images: (json['images'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        path: '${json['path'] ?? ''}',
        pages: [
          for (final p in (json['pages'] as List? ?? const []))
            '${(p as Map)['page']}',
        ],
      );
}
