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
