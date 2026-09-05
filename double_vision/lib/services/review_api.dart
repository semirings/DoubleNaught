import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aa_payload.dart';
import '../backend_config.dart';

/// Thin client for the ReviewNode routes on the DoubleTouch backend
/// (`double_touch/`), targeting the camelCase contract:
///
///  * `POST /review/start`            — `{aa}` → [ReviewSession]
///  * `GET  /review/session/{id}`     — → [ReviewSession] (resume)
///  * `POST /review/decision`         — `{reviewId, chunkId, status, editedText?}`
///    → [ReviewSession]
///  * `GET  /review/output/{id}`      — → `{aa, counts}` (full audit AA)
///
/// Review state lives on the backend (persisted to disk); this client only
/// performs the calls and decodes the bodies.
class ReviewApi {
  final String baseUrl;

  const ReviewApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Begin (or transparently resume) a review of [aa].
  Future<ReviewSession> start(AaPayload aa) async {
    final body = await _post('/review/start', {'aa': aa.toJson()});
    return ReviewSession.fromJson(body);
  }

  /// Resume an existing review session by id.
  Future<ReviewSession> session(String reviewId) async {
    final body = await _get('/review/session/$reviewId');
    return ReviewSession.fromJson(body);
  }

  /// Record a decision for one passage.
  Future<ReviewSession> decide({
    required String reviewId,
    required String chunkId,
    required String status,
    String? editedText,
  }) async {
    final body = await _post('/review/decision', {
      'reviewId': reviewId,
      'chunkId': chunkId,
      'status': status,
      if (editedText != null) 'editedText': editedText,
    });
    return ReviewSession.fromJson(body);
  }

  /// The full audit AA (every decided passage, including rejected).
  Future<AaPayload> output(String reviewId) async {
    final body = await _get('/review/output/$reviewId');
    return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    return _decode(path, response);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await http.get(Uri.parse('$baseUrl$path'));
    return _decode(path, response);
  }

  Map<String, dynamic> _decode(String path, http.Response response) {
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ReviewApiException(path, response.statusCode, response.body);
  }
}

/// One candidate passage plus its (possibly pending) review decision.
class ReviewPassage {
  final String chunkId;
  final String text;
  final String author;
  final String workTitle;
  final int position;
  final int tokenCount;
  final String chunkStrategy;

  /// approved | edited | rejected | null (pending).
  final String? status;
  final String? editedText;
  final String? reviewTimestamp;

  const ReviewPassage({
    required this.chunkId,
    required this.text,
    this.author = '',
    this.workTitle = '',
    this.position = 0,
    this.tokenCount = 0,
    this.chunkStrategy = '',
    this.status,
    this.editedText,
    this.reviewTimestamp,
  });

  bool get isPending => status == null;

  factory ReviewPassage.fromJson(Map<String, dynamic> json) => ReviewPassage(
        chunkId: json['chunkId'] as String? ?? '',
        text: json['text'] as String? ?? '',
        author: json['author'] as String? ?? '',
        workTitle: json['workTitle'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        tokenCount: (json['tokenCount'] as num?)?.toInt() ?? 0,
        chunkStrategy: json['chunkStrategy'] as String? ?? '',
        status: json['status'] as String?,
        editedText: json['editedText'] as String?,
        reviewTimestamp: json['reviewTimestamp'] as String?,
      );
}

/// Running tally of decisions in a review session.
class ReviewCounts {
  final int total;
  final int approved;
  final int edited;
  final int rejected;
  final int pending;

  const ReviewCounts({
    required this.total,
    required this.approved,
    required this.edited,
    required this.rejected,
    required this.pending,
  });

  factory ReviewCounts.fromJson(Map<String, dynamic> json) => ReviewCounts(
        total: (json['total'] as num?)?.toInt() ?? 0,
        approved: (json['approved'] as num?)?.toInt() ?? 0,
        edited: (json['edited'] as num?)?.toInt() ?? 0,
        rejected: (json['rejected'] as num?)?.toInt() ?? 0,
        pending: (json['pending'] as num?)?.toInt() ?? 0,
      );
}

/// A full review session as returned by the backend.
class ReviewSession {
  final String reviewId;
  final List<ReviewPassage> passages;
  final ReviewCounts counts;
  final bool complete;

  const ReviewSession({
    required this.reviewId,
    required this.passages,
    required this.counts,
    required this.complete,
  });

  factory ReviewSession.fromJson(Map<String, dynamic> json) => ReviewSession(
        reviewId: json['reviewId'] as String? ?? '',
        passages: [
          for (final p in (json['passages'] as List? ?? const []))
            ReviewPassage.fromJson(p as Map<String, dynamic>),
        ],
        counts: ReviewCounts.fromJson(
            (json['counts'] as Map<String, dynamic>?) ?? const {}),
        complete: json['complete'] as bool? ?? false,
      );
}

/// Raised when a review route returns a non-200 response.
class ReviewApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  ReviewApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'ReviewApiException($path → $statusCode): $body';
}
