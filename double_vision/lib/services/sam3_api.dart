import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin client for the DoubleTouch SAM3 backend (`double_touch/`).
///
/// Targets the camelCase contract defined in `DESIGN.md` (Architecture Rules →
/// Backend data contract):
///
///  * `POST /segment/text`  — `{sessionId, prompt}`
///  * `POST /segment/box`   — `{sessionId, box:[cx,cy,w,h] normalized, include}`
///  * `POST /segment/point` — `{sessionId, point:[x,y] normalized, include}`
///
/// Each returns a JSON object whose `results` field carries the coordinate/mask
/// map the workspace viewport renders, plus an `inferenceMetrics` block. This
/// client only performs the calls and decodes the body — it holds no UI state.
class Sam3Api {
  /// Base URL of the segmentation backend. Matches the reference default;
  /// override for non-local deployments.
  final String baseUrl;

  const Sam3Api({this.baseUrl = 'http://localhost:8000'});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  /// Segment using a free-text [prompt] (e.g. "cat", "wheel").
  Future<Map<String, dynamic>> segmentWithText(
    String sessionId,
    String prompt,
  ) {
    return _post('/segment/text', {
      'sessionId': sessionId,
      'prompt': prompt,
    });
  }

  /// Add a box prompt. [box] is `[centerX, centerY, width, height]` normalized
  /// to 0..1; [include] maps to the backend's positive/negative `label`.
  Future<Map<String, dynamic>> segmentWithBox(
    String sessionId,
    List<double> box,
    bool include,
  ) {
    return _post('/segment/box', {
      'sessionId': sessionId,
      'box': box,
      'include': include,
    });
  }

  /// Add a point prompt. [point] is `[x, y]` normalized to 0..1; [include] maps
  /// to the backend's positive/negative `label`.
  Future<Map<String, dynamic>> segmentWithPoint(
    String sessionId,
    List<double> point,
    bool include,
  ) {
    return _post('/segment/point', {
      'sessionId': sessionId,
      'point': point,
      'include': include,
    });
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Sam3ApiException(path, response.statusCode, response.body);
  }
}

/// Raised when the SAM3 backend returns a non-200 response.
class Sam3ApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  Sam3ApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'Sam3ApiException($path → $statusCode): $body';
}
