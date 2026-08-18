import 'dart:convert';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/remote/model_catalog.dart';
import 'package:double_vision/services/remote/remote_request.dart';
import 'package:double_vision/services/vault/key_vault.dart';
import 'package:double_vision/services/vault/vault_store.dart';
import 'package:double_vision/widgets/nodes/implementations/llm_documenter_node_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _FakeStore implements VaultStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

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

AuthProfile _profile(AuthProvider provider, {String id = 'p1'}) => AuthProfile(
      id: id,
      displayName: 'Work ${provider.label}',
      provider: provider,
      baseUrl: provider.baseUrl,
      credentialRef: AuthProfile.refFor(id),
      maxContextTokens: 1000,
    );

/// The 1×5 AA a Secure Settings node publishes.
AaPayload _authAa(AuthProfile p) => p.toAa();

/// The model box, scoped by label — the Service dropdown is also a TextField and
/// renders before it, so `find.byType(TextField).first` is the wrong one.
Finder _modelField() => find.ancestor(
      of: find.text('Model / Resource id'),
      matching: find.byType(TextField),
    );

String _modelText(WidgetTester tester) =>
    tester.widget<TextField>(_modelField()).controller!.text;

void main() {
  _catalogTests();

  group('ServiceRef.fromAa', () {
    test('reads a single 1x5 profile payload', () {
      final refs = ServiceRef.fromAa(_authAa(_profile(AuthProvider.anthropic)));
      expect(refs, hasLength(1));
      expect(refs.single.profileId, 'p1');
      expect(refs.single.provider, AuthProvider.anthropic);
      expect(refs.single.baseUrl, 'https://api.anthropic.com');
      expect(refs.single.credentialRef, 'credential:p1');
      expect(refs.single.label, 'Work Anthropic · Anthropic');
      expect(refs.single.isValid, isTrue);
    });

    test('reads a multi-row payload listing several services', () {
      final a = _profile(AuthProvider.anthropic, id: 'a');
      final b = _profile(AuthProvider.ollamaLocal, id: 'b');
      final merged = AaPayload(
        rows: [..._authAa(a).rows, ..._authAa(b).rows],
        cols: [..._authAa(a).cols, ..._authAa(b).cols],
        vals: [..._authAa(a).vals, ..._authAa(b).vals],
      );

      final refs = ServiceRef.fromAa(merged)
        ..sort((x, y) => x.profileId.compareTo(y.profileId));
      expect(refs.map((r) => r.profileId), ['a', 'b']);
      expect(refs.last.provider, AuthProvider.ollamaLocal);
    });

    test('a profile with no endpoint is not selectable', () {
      const bare = AaPayload(
        rows: ['x', 'x'],
        cols: ['displayName', 'provider'],
        vals: ['No URL', 'anthropic'],
      );
      expect(ServiceRef.fromAa(bare).single.isValid, isFalse);
    });
  });

  group('RemoteRequest wire shapes', () {
    Future<_Recorder> dispatch(
      AuthProvider provider, {
      String model = 'm-1',
      String responseBody = '{}',
    }) async {
      final recorder = _Recorder(body: responseBody);
      await RemoteRequest(client: recorder).send(
        profile: _profile(provider),
        model: model,
        prompt: 'hello there',
        apiKey: 'the-key',
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

  group('LLMDocumenterNodeWidget', () {
    /// Mounts the node, returning the registered ports and captured emissions.
    Future<
        ({
          InputPort data,
          InputPort auth,
          List<AaPayload> emitted,
          _Recorder client,
        })> pump(
      WidgetTester tester, {
      required KeyVault vault,
      _Recorder? client,
      Map<String, String>? params,
    }) async {
      InputPort? data;
      InputPort? auth;
      final emitted = <AaPayload>[];
      final recorder = client ?? _Recorder(body: '{"response":"remote said hi"}');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LLMDocumenterNodeWidget(
              node: const WorkflowNode(id: 9, type: 'remoteServiceNode'),
              initialParams: params,
              vault: vault,
              clientFactory: () => recorder,
              onInputPort: (p) => data = p,
              onAuthInputPort: (p) => auth = p,
              onOutputPort: (p) =>
                  p.connect(emitted.add, emitCurrentState: false),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (
        data: data!,
        auth: auth!,
        emitted: emitted,
        client: recorder,
      );
    }

    Future<KeyVault> vaultWith(AuthProvider provider) async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(provider), apiKey: 'sk-stored');
      return vault;
    }

    testWidgets('declares dataInput, authInput and dataOutput', (tester) async {
      final ports = await pump(tester, vault: await vaultWith(AuthProvider.ollamaLocal));

      expect(find.text('LLM Documenter'), findsOneWidget);
      expect(find.text('dataInput'), findsOneWidget);
      expect(find.text('authInput'), findsOneWidget);
      expect(find.text('dataOutput'), findsOneWidget);
      expect(ports.data.id, 'dataInput');
      expect(ports.auth.id, 'authInput');
    });

    testWidgets('authInput fills the dropdown and auto-selects', (tester) async {
      final vault = await vaultWith(AuthProvider.anthropic);
      final ports = await pump(tester, vault: vault);

      expect(find.textContaining('Waiting for authInput'), findsOneWidget);

      ports.auth.connect(OutputPort('auth')..emit(_authAa(_profile(AuthProvider.anthropic))));
      await tester.pumpAndSettle();

      expect(find.textContaining('Waiting for authInput'), findsNothing);
      expect(find.text('Work Anthropic · Anthropic'), findsWidgets);
      // Anthropic's model default is the one value safe to pre-fill.
      expect(_modelText(tester), 'claude-opus-5');
    });

    testWidgets('submitting dispatches and emits the 1x5 result matrix',
        (tester) async {
      final vault = await vaultWith(AuthProvider.ollamaLocal);
      final ports = await pump(tester, vault: vault);

      ports.auth.connect(
          OutputPort('auth')..emit(_authAa(_profile(AuthProvider.ollamaLocal))));
      ports.data.connect(OutputPort('data')
        ..emit(const AaPayload(
          rows: ['r'],
          cols: ['text'],
          vals: ['summarise this'],
        )));
      await tester.pumpAndSettle();

      await tester.enterText(_modelField(), 'qwen');
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();

      // The upstream payload became the prompt.
      expect(jsonDecode(ports.client.bodies.single)['prompt'], 'summarise this');

      final aa = ports.emitted.single;
      expect(aa.distinctRows().single, startsWith('request:'));
      expect(aa.cols, [
        'text',
        'serviceProvider',
        'status',
        'executionTimeMs',
        'errorMsg',
      ]);
      expect(aa.value('text'), 'remote said hi');
      expect(aa.value('serviceProvider'), 'ollamaLocal');
      expect(aa.value('status'), 'ok');
      expect(aa.intValue('executionTimeMs'), isNotNull);
      expect(aa.value('errorMsg'), isEmpty);
      expect(find.textContaining('Complete'), findsOneWidget);
    });

    testWidgets('a failure still emits a result AA', (tester) async {
      final vault = await vaultWith(AuthProvider.ollamaLocal);
      final ports = await pump(
        tester,
        vault: vault,
        client: _Recorder(status: 500, body: '{"error":{"message":"boom"}}'),
      );

      ports.auth.connect(
          OutputPort('auth')..emit(_authAa(_profile(AuthProvider.ollamaLocal))));
      ports.data.connect(OutputPort('data')
        ..emit(const AaPayload(rows: ['r'], cols: ['text'], vals: ['go'])));
      await tester.pumpAndSettle();

      await tester.enterText(_modelField(), 'qwen');
      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();

      final aa = ports.emitted.single;
      expect(aa.value('status'), 'error');
      expect(aa.value('errorMsg'), contains('provider error'));
      expect(aa.value('text'), isEmpty);
      expect(find.textContaining('Error'), findsOneWidget);
    });

    testWidgets('an empty dataInput is refused before any request',
        (tester) async {
      final vault = await vaultWith(AuthProvider.ollamaLocal);
      final ports = await pump(tester, vault: vault);

      ports.auth.connect(
          OutputPort('auth')..emit(_authAa(_profile(AuthProvider.ollamaLocal))));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No text in the dataInput'), findsOneWidget);
      expect(ports.client.requests, isEmpty);
      expect(ports.emitted, isEmpty);
    });

    testWidgets('a ref this vault cannot redeem fails with a clear message',
        (tester) async {
      // Vault holds nothing — the AA references a profile from another machine.
      final ports = await pump(tester, vault: KeyVault(persistent: _FakeStore()));

      ports.auth.connect(
          OutputPort('auth')..emit(_authAa(_profile(AuthProvider.anthropic))));
      ports.data.connect(OutputPort('data')
        ..emit(const AaPayload(rows: ['r'], cols: ['text'], vals: ['go'])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submit Request'));
      await tester.pumpAndSettle();

      expect(ports.emitted.single.value('errorMsg'),
          contains('No credential redeemable'));
      expect(ports.client.requests, isEmpty);
    });

    testWidgets('Submit is disabled until a service is selected',
        (tester) async {
      final ports = await pump(tester, vault: await vaultWith(AuthProvider.ollamaLocal));

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      ports.auth.connect(
          OutputPort('auth')..emit(_authAa(_profile(AuthProvider.ollamaLocal))));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });
  });
}

// ── Model catalogue ─────────────────────────────────────────────────────────

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

void _catalogTests() {
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

  group('the node offers the catalogue', () {
    testWidgets('fetching fills the model field from the menu', (tester) async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(AuthProvider.googleGemini),
          apiKey: 'sk-stored');
      InputPort? auth;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LLMDocumenterNodeWidget(
              node: const WorkflowNode(id: 9, type: 'remoteServiceNode'),
              vault: vault,
              onAuthInputPort: (p) => auth = p,
              catalog: ModelCatalog(
                clientFactory: () => _CatalogClient(
                  body: '{"models":['
                      '{"name":"models/gemini-fast",'
                      '"supportedGenerationMethods":["generateContent"]},'
                      '{"name":"models/gemini-deep",'
                      '"supportedGenerationMethods":["generateContent"]}]}',
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // No service selected yet — nothing to list.
      // IconButton builds the Tooltip, so it is the tooltip's ancestor.
      expect(
        tester
            .widget<IconButton>(find.ancestor(
              of: find.byTooltip('Available models'),
              matching: find.byType(IconButton),
            ))
            .onPressed,
        isNull,
      );

      auth!.connect(OutputPort('auth')
        ..emit(_authAa(_profile(AuthProvider.googleGemini))));
      await tester.pumpAndSettle();

      // Gemini ships no default id, so the field starts empty by design.
      expect(_modelText(tester), isEmpty);

      await tester.tap(find.byTooltip('Available models'));
      await tester.pumpAndSettle();

      // The provider's own ids, prefix stripped and sorted.
      expect(find.text('gemini-deep'), findsOneWidget);
      expect(find.text('gemini-fast'), findsOneWidget);

      await tester.tap(find.text('gemini-fast'));
      await tester.pumpAndSettle();

      expect(_modelText(tester), 'gemini-fast');
    });

    testWidgets('a failed listing reports why and leaves the field alone',
        (tester) async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(AuthProvider.googleGemini),
          apiKey: 'sk-stored');
      InputPort? auth;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LLMDocumenterNodeWidget(
              node: const WorkflowNode(id: 9, type: 'remoteServiceNode'),
              vault: vault,
              onAuthInputPort: (p) => auth = p,
              catalog: ModelCatalog(
                clientFactory: () => _CatalogClient(status: 403),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      auth!.connect(OutputPort('auth')
        ..emit(_authAa(_profile(AuthProvider.googleGemini))));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Available models'));
      await tester.pumpAndSettle();

      expect(find.textContaining('HTTP 403'), findsOneWidget);
      expect(_modelText(tester), isEmpty);
    });
  });
}
