import 'dart:convert';

import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/services/remote/remote_request.dart';
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

/// Records the request and replies with a canned body.
class _Recorder extends http.BaseClient {
  final List<http.Request> requests = [];
  final List<String> bodies = [];
  final int status;
  final String body;

  _Recorder({this.status = 200, this.body = '{}'});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = request as http.Request;
    requests.add(r);
    bodies.add(r.body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

/// [RemoteRequest] dispatches a prompt to a provider's chat/completion
/// endpoint per its own wire format. Not currently wired into any node — the
/// "Remote Service" node that used it was rewritten into today's local-only
/// LLM Documenter (see `llm_documenter_node_test.dart` for that history) —
/// kept here since the class and its provider-specific wire handling are
/// still real, live code, independent of which node (if any) calls it.
void main() {
  group('RemoteRequest wire shapes', () {
    Future<_Recorder> dispatch(
      AuthProvider provider, {
      String model = 'm-1',
      String responseBody = '{}',
      int? maxTokens,
      double? temperature,
    }) async {
      final recorder = _Recorder(body: responseBody);
      await RemoteRequest(client: recorder).send(
        profile: _profile(provider),
        model: model,
        prompt: 'hello there',
        apiKey: 'the-key',
        maxTokens: maxTokens,
        temperature: temperature,
      );
      return recorder;
    }

    test('Anthropic: /v1/messages with x-api-key + anthropic-version',
        () async {
      final r = await dispatch(AuthProvider.anthropic, model: 'claude-opus-5');
      final request = r.requests.single;

      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'the-key');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(request.headers.containsKey('Authorization'), isFalse);

      final body = jsonDecode(r.bodies.single) as Map<String, Object?>;
      expect(body['model'], 'claude-opus-5');
      expect(body['max_tokens'], RemoteRequest.maxTokens);
      expect((body['messages'] as List).single, {
        'role': 'user',
        'content': 'hello there',
      });
    });

    test('OpenAI-compatible: /v1/chat/completions with a bearer', () async {
      final r = await dispatch(AuthProvider.openAiCompatible);
      expect(r.requests.single.url.path, '/v1/chat/completions');
      expect(r.requests.single.headers['Authorization'], 'Bearer the-key');
      expect(jsonDecode(r.bodies.single)['stream'], isFalse);
    });

    test('Gemini: model in the path, key in x-goog-api-key', () async {
      final r = await dispatch(AuthProvider.googleGemini, model: 'gem-x');
      expect(r.requests.single.url.path, '/v1beta/models/gem-x:generateContent');
      expect(r.requests.single.headers['x-goog-api-key'], 'the-key');
      // Gemini's body carries no model field — it is addressed by path.
      expect(jsonDecode(r.bodies.single).containsKey('model'), isFalse);
    });

    test('Ollama: /api/generate, no auth header', () async {
      final r = await dispatch(AuthProvider.ollamaLocal, model: 'qwen');
      expect(r.requests.single.url.toString(),
          'http://localhost:11434/api/generate');
      expect(r.requests.single.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(r.bodies.single)['prompt'], 'hello there');
    });

    group('maxTokens/temperature overrides', () {
      test('unset: the three non-Anthropic providers carry no token-limit '
          'field at all, exactly as before', () async {
        for (final provider in [
          AuthProvider.openAiCompatible,
          AuthProvider.googleGemini,
          AuthProvider.ollamaLocal,
        ]) {
          final r = await dispatch(provider);
          final body = jsonDecode(r.bodies.single) as Map<String, Object?>;
          expect(body.containsKey('max_tokens'), isFalse, reason: '$provider');
          expect(body.containsKey('generationConfig'), isFalse, reason: '$provider');
          expect(body.containsKey('options'), isFalse, reason: '$provider');
        }
      });

      test('unset: Anthropic still defaults to the class constant', () async {
        final r = await dispatch(AuthProvider.anthropic);
        expect(jsonDecode(r.bodies.single)['max_tokens'], RemoteRequest.maxTokens);
      });

      test('set: each provider carries the override in its own shape',
          () async {
        final anthropic = await dispatch(
          AuthProvider.anthropic,
          maxTokens: 512,
          temperature: 0.3,
        );
        final aBody = jsonDecode(anthropic.bodies.single) as Map<String, Object?>;
        expect(aBody['max_tokens'], 512);
        expect(aBody['temperature'], 0.3);

        final openAi = await dispatch(
          AuthProvider.openAiCompatible,
          maxTokens: 512,
          temperature: 0.3,
        );
        final oBody = jsonDecode(openAi.bodies.single) as Map<String, Object?>;
        expect(oBody['max_tokens'], 512);
        expect(oBody['temperature'], 0.3);

        final gemini = await dispatch(
          AuthProvider.googleGemini,
          maxTokens: 512,
          temperature: 0.3,
        );
        final gConfig = (jsonDecode(gemini.bodies.single)
            as Map<String, Object?>)['generationConfig'] as Map;
        expect(gConfig['maxOutputTokens'], 512);
        expect(gConfig['temperature'], 0.3);

        final ollama = await dispatch(
          AuthProvider.ollamaLocal,
          maxTokens: 512,
          temperature: 0.3,
        );
        final oOptions = (jsonDecode(ollama.bodies.single)
            as Map<String, Object?>)['options'] as Map;
        expect(oOptions['num_predict'], 512);
        expect(oOptions['temperature'], 0.3);
      });
    });
  });

  group('RemoteRequest response handling', () {
    Future<RemoteResult> send(
      AuthProvider provider,
      String body, {
      int status = 200,
      String? apiKey = 'k',
    }) =>
        RemoteRequest(client: _Recorder(status: status, body: body)).send(
          profile: _profile(provider),
          model: 'm',
          prompt: 'p',
          apiKey: apiKey,
        );

    test('extracts text per provider', () async {
      final anthropic = await send(AuthProvider.anthropic,
          '{"content":[{"type":"text","text":"from claude"}]}');
      expect(anthropic.status, 'ok');
      expect(anthropic.text, 'from claude');

      final openai = await send(AuthProvider.openAiCompatible,
          '{"choices":[{"message":{"content":"from openai"}}]}');
      expect(openai.text, 'from openai');

      final gemini = await send(AuthProvider.googleGemini,
          '{"candidates":[{"content":{"parts":[{"text":"from gemini"}]}}]}');
      expect(gemini.text, 'from gemini');

      final ollama =
          await send(AuthProvider.ollamaLocal, '{"response":"from ollama"}');
      expect(ollama.text, 'from ollama');
    });

    test('an Anthropic refusal is HTTP 200 and must not be read as content',
        () async {
      // The failure mode this guards: stop_reason refusal with an empty
      // content array — indexing content[0] would throw on a valid response.
      final result = await send(
        AuthProvider.anthropic,
        '{"stop_reason":"refusal","stop_details":{"category":"cyber"},'
        '"content":[]}',
      );

      expect(result.status, 'error');
      expect(result.errorMsg, contains('safety policy'));
      expect(result.errorMsg, contains('cyber'));
      expect(result.text, isEmpty);
    });

    test('status codes surface a cause plus the provider message', () async {
      final unauthorized = await send(
        AuthProvider.anthropic,
        '{"error":{"message":"invalid x-api-key"}}',
        status: 401,
      );
      expect(unauthorized.status, 'error');
      expect(unauthorized.errorMsg, contains('credential rejected'));
      expect(unauthorized.errorMsg, contains('invalid x-api-key'));

      expect((await send(AuthProvider.anthropic, '{}', status: 404)).errorMsg,
          contains('endpoint or model not found'));
      expect((await send(AuthProvider.anthropic, '{}', status: 429)).errorMsg,
          contains('rate limited'));
      expect((await send(AuthProvider.anthropic, '{}', status: 503)).errorMsg,
          contains('provider error'));
    });

    test('malformed bodies fail cleanly rather than throwing', () async {
      expect((await send(AuthProvider.anthropic, 'not json')).errorMsg,
          contains('not valid JSON'));
      expect((await send(AuthProvider.anthropic, '[]')).errorMsg,
          contains('non-object body'));
      expect((await send(AuthProvider.anthropic, '{"content":[]}')).errorMsg,
          contains('No text'));
    });

    test('a missing key or model short-circuits before dispatch', () async {
      final recorder = _Recorder();
      final noKey = await RemoteRequest(client: recorder).send(
        profile: _profile(AuthProvider.anthropic),
        model: 'm',
        prompt: 'p',
        apiKey: null,
      );
      expect(noKey.errorMsg, contains('No credential redeemable'));

      final noModel = await RemoteRequest(client: recorder).send(
        profile: _profile(AuthProvider.anthropic),
        model: '',
        prompt: 'p',
        apiKey: 'k',
      );
      expect(noModel.errorMsg, contains('Set a model id'));
      expect(recorder.requests, isEmpty);
    });

    test('reports the phases the status bar renders', () async {
      final phases = <RemotePhase>[];
      await RemoteRequest(
        client: _Recorder(body: '{"response":"hi"}'),
        onProgress: (phase, _) => phases.add(phase),
      ).send(
        profile: _profile(AuthProvider.ollamaLocal),
        model: 'm',
        prompt: 'p',
      );
      expect(phases.first, RemotePhase.connecting);
      expect(phases, contains(RemotePhase.streaming));
      expect(phases.last, RemotePhase.done);
    });
  });
}
