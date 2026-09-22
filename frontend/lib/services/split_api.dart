import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Thin client for `POST /split` on the DoubleTouch backend.
///
/// Takes a token AA and a split ratio; returns two AAs — train and val —
/// partitioned by unique row key (chunk_id).
class SplitApi {
  final String baseUrl;

  const SplitApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};
  static const _timeout = Duration(minutes: 2);

  Future<SplitResult> split(
    AaPayload aa, {
    double ratio = 0.8,
    String strategy = 'random',
    int seed = 42,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/split'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'aa': aa.toJson(),
            'ratio': ratio,
            'strategy': strategy,
            'seed': seed,
          }),
        )
        .timeout(_timeout,
            onTimeout: () =>
                throw SplitApiException('/split', 408, 'Request timed out'));
    if (response.statusCode == 200) {
      return SplitResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw SplitApiException('/split', response.statusCode, response.body);
  }
}

class SplitResult {
  final AaPayload trainAa;
  final AaPayload valAa;
  final int trainCount;
  final int valCount;
  final int totalCount;

  const SplitResult({
    required this.trainAa,
    required this.valAa,
    required this.trainCount,
    required this.valCount,
    required this.totalCount,
  });

  factory SplitResult.fromJson(Map<String, dynamic> j) => SplitResult(
        trainAa: AaPayload.fromJson(j['trainAa'] as Map<String, dynamic>),
        valAa: AaPayload.fromJson(j['valAa'] as Map<String, dynamic>),
        trainCount: (j['trainCount'] as num).toInt(),
        valCount: (j['valCount'] as num).toInt(),
        totalCount: (j['totalCount'] as num).toInt(),
      );
}

class SplitApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  SplitApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'SplitApiException($path → $statusCode): $body';
}
