import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../backend_config.dart';

/// What a completed SegForge session holds, as read back off its backend.
///
/// Mirrors `GET /loadSession/{id}`, which SegForge serves straight from the
/// session's `session.json` without needing its model loaded. Index `i` is
/// consistent across [masksRle], [boxes] and [scores] — and across the
/// `segment_NNN.png` / `mask_NNN.png` files on SegForge's disk.
class SegForgeSession {
  final String sessionId;
  final int width;
  final int height;

  /// Session creation time, ISO 8601 UTC. Null for a session that was never
  /// uploaded to. SegForge records no *per-prompt* timestamps.
  final String? createdAt;

  /// Heterogeneous by design, matching what SegForge appends:
  /// a bare `String` for a text prompt, or a `Map` of
  /// `{type: 'box'|'point', box|point: [...], label: 'positive'|'negative'}`.
  final List<Object> prompts;

  /// Run-length encoded masks, `{counts: [...], size: [h, w]}`. SegForge's own
  /// encoding, not COCO's compressed-string RLE.
  final List<Map<String, dynamic>> masksRle;

  /// Pixel-space `[x0, y0, x1, y1]` in original-image coordinates.
  final List<List<double>> boxes;

  /// Per-segment confidence, parallel to [boxes].
  final List<double> scores;

  const SegForgeSession({
    required this.sessionId,
    required this.width,
    required this.height,
    this.createdAt,
    this.prompts = const [],
    this.masksRle = const [],
    this.boxes = const [],
    this.scores = const [],
  });

  /// True when the user closed SegForge without ever producing an inference —
  /// the node treats this as "nothing produced" rather than an error.
  bool get isEmpty => masksRle.isEmpty && boxes.isEmpty;

  int get segmentCount =>
      boxes.length > masksRle.length ? boxes.length : masksRle.length;

  factory SegForgeSession.fromJson(String sessionId, Map<String, dynamic> j) {
    final results = (j['results'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SegForgeSession(
      sessionId: sessionId,
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      createdAt: j['created_at'] as String?,
      prompts: [for (final p in (j['prompts'] as List? ?? const [])) p as Object],
      masksRle: [
        for (final m in (results['masks'] as List? ?? const []))
          (m as Map).cast<String, dynamic>(),
      ],
      boxes: [
        for (final b in (results['boxes'] as List? ?? const []))
          [for (final v in (b as List)) (v as num).toDouble()],
      ],
      scores: [
        for (final s in (results['scores'] as List? ?? const []))
          (s as num).toDouble(),
      ],
    );
  }
}

/// Result of `POST /upload`.
class SegForgeUpload {
  final String sessionId;
  final int width;
  final int height;

  const SegForgeUpload({
    required this.sessionId,
    required this.width,
    required this.height,
  });
}

/// Client for the **SegForge** backend — a separate FastAPI service from
/// DoubleNaught's own `double_touch` backend.
///
/// SegForge listens on 8401 and DoubleNaught on 8400 specifically so both can
/// run at once; see `backend_config.dart` for this app's own address. Override
/// with `--dart-define=SEGFORGE_BACKEND_URL=...` to point at a different host.
///
/// Only the endpoints the Seg Forge node needs are wrapped here.
class SegForgeApi {
  final String baseUrl;
  final http.Client? client;

  static const String defaultBaseUrl = String.fromEnvironment(
    'SEGFORGE_BACKEND_URL',
    defaultValue: 'http://127.0.0.1:8401',
  );

  const SegForgeApi({this.baseUrl = defaultBaseUrl, this.client});

  /// Unwrap FastAPI's `{"detail": ...}` so node status rows show the real cause.
  Never _fail(String what, http.Response r) {
    String detail;
    try {
      detail = (jsonDecode(r.body) as Map)['detail']?.toString() ??
          'HTTP ${r.statusCode}';
    } catch (_) {
      detail = r.body.isNotEmpty ? r.body : 'HTTP ${r.statusCode}';
    }
    throw Exception('$what failed: $detail');
  }

  /// Uploads image bytes, creating a session when [sessionId] is null.
  ///
  /// The node does this *before* launching the app so the image is already
  /// registered and servable over SegForge's `/storage` static mount — which
  /// is how a `byte[]` input becomes the URL the app expects at launch.
  Future<SegForgeUpload> uploadImage(
    Uint8List bytes, {
    required String filename,
    String? sessionId,
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload'),
      )..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
      if (sessionId != null) request.fields['session_id'] = sessionId;

      final response =
          await http.Response.fromStream(await transport.send(request));
      if (response.statusCode != 200) _fail('Upload', response);

      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return SegForgeUpload(
        sessionId: j['session_id'] as String,
        width: (j['width'] as num).toInt(),
        height: (j['height'] as num).toInt(),
      );
    } finally {
      own?.close();
    }
  }

  /// Allocates an empty session and returns its id.
  ///
  /// Used when the image is a URL the app can fetch for itself: the node needs
  /// to know the session id up front in order to read results back, but has
  /// nothing to upload. The backend creates the session directories here, and
  /// the app's own `/upload` then lands in this same session because the node
  /// passes the id to it.
  Future<String> newSession() async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/newSession'),
        headers: const {'Content-Type': 'application/json'},
      );
      if (response.statusCode != 200) _fail('New session', response);
      return (jsonDecode(response.body) as Map<String, dynamic>)['session_id']
          as String;
    } finally {
      own?.close();
    }
  }

  /// URL for an image already uploaded into [sessionId], via the `/storage`
  /// static mount. This is what gets handed to the app as `SEGFORGE_IMAGE_URL`.
  String originalImageUrl(String sessionId) =>
      '$baseUrl/storage/sessions/$sessionId/original.png';

  Future<SegForgeSession> loadSession(String sessionId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/loadSession/$sessionId'),
      );
      if (response.statusCode != 200) _fail('Load session', response);
      return SegForgeSession.fromJson(
        sessionId,
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } finally {
      own?.close();
    }
  }

  /// Renders each mask into a cutout PNG under the session's `segments_raw/`.
  ///
  /// SegForge's own UI no longer calls this, so the node drives it directly
  /// after the app exits. Returns how many segments were written.
  Future<int> createSegments(String sessionId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/createSegments'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': sessionId}),
      );
      if (response.statusCode != 200) _fail('Create segments', response);
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return (j['count'] as num?)?.toInt() ?? 0;
    } finally {
      own?.close();
    }
  }

  /// Writes `masks/mask_NNN.png` for every mask in the session.
  ///
  /// Driven by the node rather than relying on the user having pressed Save in
  /// the app, so `mask_bytes` is always a real PNG instead of sometimes being
  /// absent. Returns how many masks were written.
  Future<int> saveMasks(String sessionId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/saveMasks'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': sessionId}),
      );
      if (response.statusCode != 200) _fail('Save masks', response);
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return (j['mask_count'] as num?)?.toInt() ??
          (j['count'] as num?)?.toInt() ??
          0;
    } finally {
      own?.close();
    }
  }

  /// Flushes SegForge's in-memory session to its `state.json` (`POST
  /// /saveSession` on the SegForge backend — *not* DoubleNaught's Parquet
  /// store, which is [saveSession]).
  ///
  /// [loadSession] reads from disk, so anything still only in the backend's
  /// memory is invisible to the node. SegForge already writes state.json after
  /// every inference, but Close Forge takes the window away from the user, so
  /// it flushes first rather than assuming that.
  Future<void> saveSessionToDisk(String sessionId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.post(
        Uri.parse('$baseUrl/saveSession'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': sessionId}),
      );
      if (response.statusCode != 200) _fail('Save session to disk', response);
    } finally {
      own?.close();
    }
  }

  /// URL of a single saved mask PNG, 8-bit grayscale at full image size.
  String maskUrl(String sessionId, int index) =>
      '$baseUrl/storage/sessions/$sessionId/masks/'
      'mask_${index.toString().padLeft(3, '0')}.png';

  /// Absolute URLs of the session's segment cutouts, in segment-index order.
  Future<List<String>> showSegments(String sessionId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/showSegments/$sessionId'),
      );
      if (response.statusCode != 200) _fail('Show segments', response);
      final paths = [
        for (final p in (jsonDecode(response.body) as List)) p as String,
      ]..sort();
      return [for (final p in paths) p.startsWith('http') ? p : '$baseUrl$p'];
    } finally {
      own?.close();
    }
  }

  Future<Uint8List> fetchBytes(String url) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(Uri.parse(url));
      if (response.statusCode != 200) _fail('Fetch $url', response);
      return response.bodyBytes;
    } finally {
      own?.close();
    }
  }

  /// Whether anything is answering on the backend's port at all.
  ///
  /// Distinct from [healthCheck]: a backend that is listening but still
  /// loading its model must not be launched a second time, so "should I spawn
  /// uvicorn" and "may I upload yet" are two different questions.
  Future<bool> isListening() async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/health'),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      own?.close();
    }
  }

  /// Checks whether the SF backend is up **and has its model loaded**.
  ///
  /// `/health` answers 200 from the moment uvicorn is listening, but `/upload`
  /// — the node's first call — answers 503 "Model not loaded yet" until SAM
  /// finishes loading, which on a cold start is well after the port opens. So
  /// readiness here means `model_loaded`, not merely reachable; anything less
  /// and an auto-launched backend gets uploaded to too early.
  Future<bool> healthCheck() async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('$baseUrl/health'),
      ).timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return false;
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return j['model_loaded'] == true;
    } catch (_) {
      return false;
    } finally {
      own?.close();
    }
  }

  /// Initializes a session on the SF backend with metadata and image URL.
  ///
  /// Called after a session is allocated but before the SF frontend launches.
  /// The backend stores the session metadata (id, name, description, image_url)
  /// and makes them available to the frontend via `/getSession/{id}`.
  ///
  /// [sessionId], [name], [description], [imageUrl] are packed into an AA and
  /// POSTed as JSON. The backend responds with session confirmation.
  Future<Map<String, dynamic>> initSession({
    required String sessionId,
    required String name,
    required String description,
    required String imageUrl,
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final body = jsonEncode({
        'session_id': sessionId,
        'name': name,
        'description': description,
        'image_url': imageUrl,
      });
      final response = await transport.post(
        Uri.parse('$baseUrl/initSession'),
        headers: const {'Content-Type': 'application/json'},
        body: body,
      );
      if (response.statusCode != 200) _fail('Init session', response);
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      own?.close();
    }
  }

  /// Lists sessions SF has actually saved, for the Seg Forge node's picklist.
  ///
  /// DN's own backend reads this straight off SF's `registry.parquet` files
  /// (`storage/sf/sessions/*/`) via the shared juliacall bridge — DN itself
  /// no longer creates or loads full session content, only lists what SF has
  /// saved. Returns metadata (session_id, name, description, created_at,
  /// image_url) per session.
  Future<List<Map<String, dynamic>>> listSessions() async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final response = await transport.get(
        Uri.parse('${BackendConfig.baseUrl}/segforge/sessions'),
      );
      if (response.statusCode != 200) _fail('List sessions', response);
      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return [
        for (final s in (j['sessions'] as List? ?? const []))
          (s as Map).cast<String, dynamic>(),
      ];
    } finally {
      own?.close();
    }
  }

  /// Detect every text region on a comic page and LaMa-scrub them in one pass.
  ///
  /// The session SegForge creates for this is deliberately never saved, so the
  /// returned id is a record of the run rather than something to reload.
  /// Nothing is captioned: held-and-scrubbed-without-a-caption is the implicit
  /// discard state a word balloon belongs in.
  Future<BalloonScrubResult> balloonScrub(
    Uint8List bytes, {
    required String filename,
  }) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/balloon-scrub'),
      )..files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: filename));

      final response =
          await http.Response.fromStream(await transport.send(request));
      if (response.statusCode != 200) _fail('Balloon scrub', response);

      final j = jsonDecode(response.body) as Map<String, dynamic>;
      return BalloonScrubResult(
        sessionId: j['session_id'] as String,
        imageBytes: base64Decode(j['image_b64'] as String),
        width: (j['width'] as num).toInt(),
        height: (j['height'] as num).toInt(),
        confidenceThreshold: (j['confidence_threshold'] as num).toDouble(),
        scrubbed: j['scrubbed'] as bool? ?? false,
        detections: [
          for (final d in (j['detections'] as List? ?? const []))
            (d as Map).cast<String, dynamic>(),
        ],
      );
    } finally {
      own?.close();
    }
  }
}

/// One automatic balloon-scrub run.
///
/// [detections] is the whole audit trail — there is no per-detection human
/// review in this flow, so it is the only record of what was scrubbed and why.
/// Each entry carries `box` (pixel xyxy), `confidence`, `cls` and `mask_id`.
class BalloonScrubResult {
  final String sessionId;
  final Uint8List imageBytes;
  final int width;
  final int height;
  final double confidenceThreshold;

  /// False when nothing was detected — the image comes back unchanged.
  final bool scrubbed;

  final List<Map<String, dynamic>> detections;

  const BalloonScrubResult({
    required this.sessionId,
    required this.imageBytes,
    required this.width,
    required this.height,
    required this.confidenceThreshold,
    required this.scrubbed,
    this.detections = const [],
  });
}
