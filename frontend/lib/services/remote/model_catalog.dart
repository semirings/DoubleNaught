import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/auth_profile.dart';

/// The models a credential can actually reach, asked of the provider itself.
///
/// Model ids are per-account and per-deployment — a hardcoded list rots, and a
/// guessed id returns a 404 that reads like a broken node. So the node offers a
/// pick-list built from the provider's own catalogue endpoint:
///
/// | Provider | Request | Ids read from |
/// |---|---|---|
/// | Anthropic | `GET /v1/models` | `data[].id` |
/// | OpenAI/Compatible | `GET /v1/models` | `data[].id` |
/// | Google Gemini | `GET /v1beta/models` | `models[].name`, `models/` prefix stripped |
/// | Ollama Local | `GET /api/tags` | `models[].name` |
///
/// These are the same endpoints the Secure Settings node pings to validate a
/// credential, so a profile that tests green can list its models.
class ModelCatalog {
  final http.Client Function() clientFactory;
  final Duration timeout;

  const ModelCatalog({
    this.clientFactory = http.Client.new,
    this.timeout = const Duration(seconds: 20),
  });

  static String pathFor(AuthProvider provider) => switch (provider) {
        AuthProvider.anthropic => '/v1/models',
        AuthProvider.openAiCompatible => '/v1/models',
        AuthProvider.googleGemini => '/v1beta/models',
        AuthProvider.ollamaLocal => '/api/tags',
      };

  /// Model ids in a decoded catalogue body, sorted for a stable menu.
  ///
  /// Gemini additionally reports `supportedGenerationMethods` per model; entries
  /// that cannot `generateContent` (embedding-only models, for instance) are
  /// dropped, since picking one would fail at dispatch.
  static List<String> parse(AuthProvider provider, Map<String, Object?> json) {
    final ids = <String>[];
    switch (provider) {
      case AuthProvider.anthropic:
      case AuthProvider.openAiCompatible:
        final data = json['data'];
        if (data is List) {
          for (final entry in data) {
            if (entry is Map && entry['id'] != null) ids.add('${entry['id']}');
          }
        }
      case AuthProvider.googleGemini:
        final models = json['models'];
        if (models is List) {
          for (final entry in models) {
            if (entry is! Map) continue;
            final methods = entry['supportedGenerationMethods'];
            if (methods is List && !methods.contains('generateContent')) {
              continue;
            }
            final name = '${entry['name'] ?? ''}';
            if (name.isEmpty) continue;
            // "models/gemini-x" → "gemini-x": the generateContent path adds the
            // prefix back, so storing it would double up.
            ids.add(name.startsWith('models/') ? name.substring(7) : name);
          }
        }
      case AuthProvider.ollamaLocal:
        final models = json['models'];
        if (models is List) {
          for (final entry in models) {
            if (entry is Map && entry['name'] != null) {
              ids.add('${entry['name']}');
            }
          }
        }
    }
    return ids..sort();
  }

  /// Fetch the catalogue. Returns `(ids, error)` — never throws, so the caller
  /// can show a message beside the field instead of handling exceptions.
  Future<({List<String> ids, String? error})> list({
    required AuthProfile profile,
    String? apiKey,
  }) async {
    var base = profile.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.tryParse('$base${pathFor(profile.provider)}');
    if (base.isEmpty || uri == null || !uri.hasScheme) {
      return (ids: const <String>[], error: 'Not a valid base URL');
    }

    final needsKey = profile.provider != AuthProvider.ollamaLocal;
    if (needsKey && (apiKey == null || apiKey.isEmpty)) {
      return (
        ids: const <String>[],
        error: 'No credential redeemable for this profile',
      );
    }

    final client = clientFactory();
    try {
      final response = await client
          .get(uri, headers: _headers(profile.provider, apiKey))
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          ids: const <String>[],
          error: 'HTTP ${response.statusCode} listing models',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        return (ids: const <String>[], error: 'Unexpected catalogue body');
      }
      final ids = parse(profile.provider, decoded);
      return (
        ids: ids,
        error: ids.isEmpty ? 'Provider listed no usable models' : null,
      );
    } on TimeoutException {
      return (
        ids: const <String>[],
        error: 'No response in ${timeout.inSeconds}s',
      );
    } catch (e) {
      return (ids: const <String>[], error: 'Could not list models');
    } finally {
      client.close();
    }
  }

  /// Same schemes as the connection test — see `ProviderPing`.
  static Map<String, String> _headers(AuthProvider provider, String? apiKey) =>
      switch (provider) {
        AuthProvider.anthropic => {
            'x-api-key': apiKey ?? '',
            'anthropic-version': '2023-06-01',
          },
        AuthProvider.openAiCompatible => {
            'Authorization': 'Bearer ${apiKey ?? ''}',
          },
        AuthProvider.googleGemini => {'x-goog-api-key': apiKey ?? ''},
        AuthProvider.ollamaLocal => const {},
      };
}
