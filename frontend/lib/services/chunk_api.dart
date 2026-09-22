import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Chunking strategy passed to `POST /chunk`.
enum ChunkStrategy {
  /// Author-registry path (default). The `author` column in the AA selects a
  /// registered backend strategy (gilbert / chesterton / churchill).
  author,

  /// Paragraph-then-sentence boundary-aware chunking. Splits on `\n\n` first,
  /// then on sentence endings if a paragraph exceeds [ChunkConfig.maxTokens].
  /// Never truncates mid-sentence. Supports stride and EOT injection.
  paragraphSentence,

  /// Fixed character-window chunking (legacy fallback). Splits every
  /// [ChunkConfig.maxChars] characters, advancing by
  /// `maxChars - stride` per step.
  characterCount;

  String get wireValue => switch (this) {
        ChunkStrategy.author => 'author',
        ChunkStrategy.paragraphSentence => 'paragraph_sentence',
        ChunkStrategy.characterCount => 'character_count',
      };
}

/// Configuration for a chunking request.
class ChunkConfig {
  final ChunkStrategy strategy;

  /// Max tokens per chunk (paragraph_sentence only).
  final int maxTokens;

  /// Max characters per window (character_count only).
  final int maxChars;

  /// Overlap carried into the next chunk (tokens or chars depending on strategy).
  final int stride;

  /// Append `<|endoftext|>` to each chunk (paragraph_sentence only).
  final bool injectEot;

  const ChunkConfig({
    this.strategy = ChunkStrategy.author,
    this.maxTokens = 300,
    this.maxChars = 1000,
    this.stride = 0,
    this.injectEot = false,
  });

  Map<String, dynamic> toJson() => {
        'chunkStrategy': strategy.wireValue,
        'maxTokens': maxTokens,
        'maxChars': maxChars,
        'stride': stride,
        'injectEot': injectEot,
      };

  ChunkConfig copyWith({
    ChunkStrategy? strategy,
    int? maxTokens,
    int? maxChars,
    int? stride,
    bool? injectEot,
  }) =>
      ChunkConfig(
        strategy: strategy ?? this.strategy,
        maxTokens: maxTokens ?? this.maxTokens,
        maxChars: maxChars ?? this.maxChars,
        stride: stride ?? this.stride,
        injectEot: injectEot ?? this.injectEot,
      );

  factory ChunkConfig.fromParams(Map<String, String> p) {
    final strategyStr = p['chunkStrategy'] ?? 'author';
    final strategy = ChunkStrategy.values.firstWhere(
      (s) => s.wireValue == strategyStr,
      orElse: () => ChunkStrategy.author,
    );
    return ChunkConfig(
      strategy: strategy,
      maxTokens: int.tryParse(p['maxTokens'] ?? '') ?? 300,
      maxChars: int.tryParse(p['maxChars'] ?? '') ?? 1000,
      stride: int.tryParse(p['stride'] ?? '') ?? 0,
      injectEot: p['injectEot'] == 'true',
    );
  }

  Map<String, String> toParams() => {
        'chunkStrategy': strategy.wireValue,
        'maxTokens': '$maxTokens',
        'maxChars': '$maxChars',
        'stride': '$stride',
        'injectEot': '$injectEot',
      };
}

/// Thin client for `POST /chunk` on the DoubleTouch backend.
class ChunkApi {
  final String baseUrl;

  const ChunkApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Chunk the cleaned text carried by [input] using [config].
  Future<ChunkResult> chunk(
    AaPayload input, {
    ChunkConfig config = const ChunkConfig(),
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/chunk'),
      headers: _jsonHeaders,
      body: jsonEncode({'aa': input.toJson(), ...config.toJson()}),
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return ChunkResult(
        aa: AaPayload.fromJson(body['aa'] as Map<String, dynamic>),
        stats: ChunkStats.fromJson(body['stats'] as Map<String, dynamic>),
      );
    }
    throw ChunkApiException('/chunk', response.statusCode, response.body);
  }
}

/// The passage AA plus its summary statistics.
class ChunkResult {
  final AaPayload aa;
  final ChunkStats stats;

  const ChunkResult({required this.aa, required this.stats});
}

/// Summary statistics for a chunking run (mirrors backend `ChunkStats`).
class ChunkStats {
  final int chunkCount;
  final int totalTokens;
  final int minTokens;
  final int maxTokens;
  final double meanTokens;

  const ChunkStats({
    required this.chunkCount,
    required this.totalTokens,
    required this.minTokens,
    required this.maxTokens,
    required this.meanTokens,
  });

  factory ChunkStats.fromJson(Map<String, dynamic> json) => ChunkStats(
        chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
        totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
        minTokens: (json['minTokens'] as num?)?.toInt() ?? 0,
        maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 0,
        meanTokens: (json['meanTokens'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Raised when the chunk route returns a non-200 response.
class ChunkApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  ChunkApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'ChunkApiException($path → $statusCode): $body';
}
