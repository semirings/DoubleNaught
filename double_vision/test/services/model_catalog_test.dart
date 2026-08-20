import 'dart:convert';

import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/services/remote/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

AuthProfile _profile(AuthProvider provider, {String id = 'p1'}) => AuthProfile(
      id: id,
      displayName: 'Work ${provider.label}',
      provider: provider,
      baseUrl: provider.baseUrl,
      credentialRef: AuthProfile.refFor(id),
      maxContextTokens: 1000,
    );

/// Serves a canned catalogue body for GET requests.
class _CatalogClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final int status;
  final String body;

  _CatalogClient({this.status = 200, this.body = '{}'});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

/// [ModelCatalog] fetches a provider's available models — used by Model
/// Classifier and Load Model, and formerly by the pre-rewrite "Remote
/// Service" node (see `llm_documenter_node_test.dart` for that history).
void main() {
  group('ModelCatalog.parse', () {
    test('Anthropic / OpenAI read data[].id', () {
      const body = {
        'data': [
          {'id': 'model-b'},
          {'id': 'model-a'},
        ],
      };
      expect(ModelCatalog.parse(AuthProvider.anthropic, body),
          ['model-a', 'model-b']);
      expect(ModelCatalog.parse(AuthProvider.openAiCompatible, body),
          ['model-a', 'model-b']);
    });

    test('Gemini strips the models/ prefix and drops non-generative entries',
        () {
      const body = {
        'models': [
          {
            'name': 'models/gemini-pro-x',
            'supportedGenerationMethods': ['generateContent', 'countTokens'],
          },
          {
            // Embedding-only: picking it would fail at dispatch.
            'name': 'models/text-embedding-1',
            'supportedGenerationMethods': ['embedContent'],
          },
        ],
      };
      expect(ModelCatalog.parse(AuthProvider.googleGemini, body),
          ['gemini-pro-x']);
    });

    test('Ollama reads models[].name', () {
      expect(
        ModelCatalog.parse(AuthProvider.ollamaLocal, const {
          'models': [
            {'name': 'qwen2.5:7b'},
          ],
        }),
        ['qwen2.5:7b'],
      );
    });

    test('a shape with no ids yields an empty list, not an error', () {
      expect(ModelCatalog.parse(AuthProvider.anthropic, const {}), isEmpty);
      expect(
          ModelCatalog.parse(AuthProvider.googleGemini,
              const {'models': 'not a list'}),
          isEmpty);
    });
  });

  group('ModelCatalog.list', () {
    test('hits the provider catalogue endpoint with its auth scheme', () async {
      final client = _CatalogClient(
        body: '{"models":[{"name":"models/gemini-x",'
            '"supportedGenerationMethods":["generateContent"]}]}',
      );
      final result = await ModelCatalog(clientFactory: () => client).list(
        profile: _profile(AuthProvider.googleGemini),
        apiKey: 'the-key',
      );

      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1beta/models');
      expect(request.headers['x-goog-api-key'], 'the-key');
      expect(result.ids, ['gemini-x']);
      expect(result.error, isNull);
    });

    test('Anthropic lists with x-api-key + anthropic-version', () async {
      final client = _CatalogClient(body: '{"data":[{"id":"claude-x"}]}');
      final result = await ModelCatalog(clientFactory: () => client).list(
        profile: _profile(AuthProvider.anthropic),
        apiKey: 'k',
      );
      expect(client.requests.single.url.path, '/v1/models');
      expect(client.requests.single.headers['anthropic-version'], '2023-06-01');
      expect(result.ids, ['claude-x']);
    });

    test('failures come back as a message, never an exception', () async {
      final unauthorized = await ModelCatalog(
        clientFactory: () => _CatalogClient(status: 401),
      ).list(profile: _profile(AuthProvider.anthropic), apiKey: 'k');
      expect(unauthorized.ids, isEmpty);
      expect(unauthorized.error, contains('HTTP 401'));

      final noKey = await ModelCatalog(
        clientFactory: () => _CatalogClient(),
      ).list(profile: _profile(AuthProvider.anthropic), apiKey: null);
      expect(noKey.error, contains('No credential redeemable'));

      final garbage = await ModelCatalog(
        clientFactory: () => _CatalogClient(body: 'not json'),
      ).list(profile: _profile(AuthProvider.anthropic), apiKey: 'k');
      expect(garbage.error, contains('Could not list models'));

      final empty = await ModelCatalog(
        clientFactory: () => _CatalogClient(body: '{"data":[]}'),
      ).list(profile: _profile(AuthProvider.anthropic), apiKey: 'k');
      expect(empty.error, contains('no usable models'));
    });
  });
}
