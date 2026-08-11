import 'package:http/http.dart' as http;

import '../../models/auth_profile.dart';

/// Outcome of a **Test Connection** attempt.
class PingResult {
  final bool ok;

  /// One-line summary for the drawer. Never contains the credential.
  final String message;

  const PingResult(this.ok, this.message);
}

/// Verifies a profile's base URL and credential with the cheapest authenticated
/// request each provider offers — a **model-listing** call in every case, so a
/// test costs no inference tokens and creates no completion.
///
/// Per-provider auth, from each vendor's documented scheme:
///
/// | Provider | Request | Credential carried as |
/// |---|---|---|
/// | Anthropic | `GET /v1/models` | `x-api-key` + `anthropic-version: 2023-06-01` |
/// | OpenAI/Compatible | `GET /v1/models` | `Authorization: Bearer …` |
/// | Google Gemini | `GET /v1beta/models` | `x-goog-api-key` |
/// | Ollama Local | `GET /api/tags` | none — a local daemon, key optional |
///
/// The Anthropic call needs **both** headers: `anthropic-version` is required on
/// every request to that API, and a call without it fails for the wrong reason,
/// which would read as a bad key.
class ProviderPing {
  /// Per-attempt ceiling. A wrong host usually manifests as a hang, not a
  /// refusal, so the timeout is what actually surfaces that error.
  final Duration timeout;
  final http.Client Function() clientFactory;

  const ProviderPing({
    this.timeout = const Duration(seconds: 10),
    this.clientFactory = _defaultClient,
  });

  static http.Client _defaultClient() => http.Client();

  /// Send the ping. [apiKey] is used for this request only and is never stored,
  /// logged, or echoed into [PingResult.message].
  Future<PingResult> test(AuthProfile profile, String? apiKey) async {
    var base = profile.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) return const PingResult(false, 'Enter a base URL');

    final needsKey = profile.provider != AuthProvider.ollamaLocal;
    if (needsKey && (apiKey == null || apiKey.isEmpty)) {
      return const PingResult(false, 'No API key on file for this profile');
    }

    final uri = Uri.tryParse('$base${_path(profile.provider)}');
    if (uri == null || !uri.hasScheme) {
      return PingResult(false, 'Not a valid URL: $base');
    }

    final client = clientFactory();
    try {
      final response = await client
          .get(uri, headers: _headers(profile.provider, apiKey))
          .timeout(timeout);
      return _interpret(response.statusCode);
    } catch (e) {
      return PingResult(false, 'Unreachable: ${_reason(e)}');
    } finally {
      client.close();
    }
  }

  String _path(AuthProvider provider) => switch (provider) {
        AuthProvider.anthropic => '/v1/models',
        AuthProvider.openAiCompatible => '/v1/models',
        AuthProvider.googleGemini => '/v1beta/models',
        AuthProvider.ollamaLocal => '/api/tags',
      };

  Map<String, String> _headers(AuthProvider provider, String? apiKey) =>
      switch (provider) {
        AuthProvider.anthropic => {
            'x-api-key': apiKey!,
            'anthropic-version': '2023-06-01',
          },
        AuthProvider.openAiCompatible => {'Authorization': 'Bearer $apiKey'},
        AuthProvider.googleGemini => {'x-goog-api-key': apiKey!},
        AuthProvider.ollamaLocal => const {},
      };

  /// Map the status to a cause the user can act on. 401/403 is a credential
  /// problem; 404 usually means the base URL points somewhere that isn't this
  /// provider's API root — a distinction worth drawing, since both otherwise
  /// read as "it didn't work".
  PingResult _interpret(int status) {
    if (status >= 200 && status < 300) {
      return PingResult(true, 'Validated · HTTP $status');
    }
    return switch (status) {
      401 || 403 => PingResult(false, 'Rejected credential · HTTP $status'),
      404 => const PingResult(
          false,
          'Endpoint not found — check the base URL',
        ),
      429 => const PingResult(false, 'Rate limited — credential may be valid'),
      _ => PingResult(false, 'Provider returned HTTP $status'),
    };
  }

  /// A short cause. Deliberately not `'$e'` — a client exception can quote the
  /// failed request, and on some clients that includes headers.
  String _reason(Object e) => switch (e) {
        _ when e.toString().contains('TimeoutException') =>
          'no response in ${timeout.inSeconds}s',
        http.ClientException() => 'connection failed',
        _ => e.runtimeType.toString(),
      };
}
