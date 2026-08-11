import 'dart:convert';

import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/services/vault/encrypted_idb_vault_store.dart';
import 'package:double_vision/services/vault/key_vault.dart';
import 'package:double_vision/services/vault/provider_ping.dart';
import 'package:double_vision/services/vault/vault_store.dart';
import 'package:double_vision/widgets/focus_panel.dart';
import 'package:double_vision/widgets/key_vault_drawer.dart';
import 'package:double_vision/widgets/nodes/implementations/secure_settings_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:idb_shim/idb_client_memory.dart';

/// Stand-in for the platform keychain. Records raw writes so a test can assert
/// what actually landed at rest.
class _FakeStore implements VaultStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

AuthProfile _profile({
  String id = 'p1',
  String name = 'Work Gemini Pro',
  AuthProvider provider = AuthProvider.googleGemini,
  bool sessionOnly = false,
}) =>
    AuthProfile(
      id: id,
      displayName: name,
      provider: provider,
      baseUrl: provider.baseUrl,
      credentialRef: AuthProfile.refFor(id),
      maxContextTokens: provider.defaultMaxContextTokens,
      sessionOnly: sessionOnly,
    );

/// Captures the request a ping made, so header/path assertions are exact.
class _Recorder extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final int status;

  _Recorder({this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"data":[]}')),
      status,
      request: request,
    );
  }
}

void main() {
  group('AuthProfile', () {
    test('toAa is a 1x5 metadata payload with no key field to leak', () {
      final aa = _profile().toAa();
      expect(aa.distinctRows(), ['p1']);
      expect(aa.cols, [
        'displayName',
        'provider',
        'baseUrl',
        'credentialRef',
        'maxContextTokens',
      ]);
      expect(aa.vals[3], 'credential:p1'); // handle, not a secret
      // Nothing in the serialized form or the payload can carry a key.
      expect(jsonEncode(_profile().toJson()).contains('sk-'), isFalse);
      expect(aa.vals.whereType<String>().any((v) => v.startsWith('sk-')),
          isFalse);
    });
  });

  group('KeyVault', () {
    test('persists profiles but routes the secret to its own entry', () async {
      final store = _FakeStore();
      final vault = KeyVault(persistent: store);

      await vault.saveProfile(_profile(), apiKey: 'sk-live-secret');

      // The profile index is plain JSON — assert the key is not in it.
      final index = store.values[VaultStore.profilesKey]!;
      expect(index.contains('Work Gemini Pro'), isTrue);
      expect(index.contains('sk-live-secret'), isFalse);
      // The secret lives under its own ref.
      expect(store.values['credential:p1'], 'sk-live-secret');
      expect(await vault.secretFor(_profile()), 'sk-live-secret');
    });

    test('session-only keys never reach the persistent store', () async {
      final store = _FakeStore();
      final vault = KeyVault(persistent: store);
      final p = _profile(sessionOnly: true);

      await vault.saveProfile(p, apiKey: 'sk-ram-only');

      expect(store.values.containsKey('credential:p1'), isFalse);
      expect(store.values.values.any((v) => v.contains('sk-ram-only')), isFalse);
      expect(await vault.secretFor(p), 'sk-ram-only');
      // A restart loses it — a fresh vault over the same persistent store.
      expect(await KeyVault(persistent: store).secretFor(p), isNull);
    });

    test('flipping sessionOnly migrates the secret and deletes the old copy',
        () async {
      final store = _FakeStore();
      final vault = KeyVault(persistent: store);
      await vault.saveProfile(_profile(), apiKey: 'sk-move-me');
      expect(store.values['credential:p1'], 'sk-move-me');

      // Persistent → session: the at-rest copy must be gone, not just ignored.
      await vault.saveProfile(_profile(sessionOnly: true));
      expect(store.values.containsKey('credential:p1'), isFalse);
      expect(await vault.secretFor(_profile(sessionOnly: true)), 'sk-move-me');

      // And back again.
      await vault.saveProfile(_profile());
      expect(store.values['credential:p1'], 'sk-move-me');
      expect(await vault.session.read('credential:p1'), isNull);
    });

    test('saving without a key keeps the stored one', () async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(), apiKey: 'sk-keep');
      await vault.saveProfile(_profile(name: 'Renamed'));

      expect(await vault.secretFor(_profile()), 'sk-keep');
      expect((await vault.profiles()).single.displayName, 'Renamed');
    });

    test('delete removes the profile and both possible secret copies', () async {
      final store = _FakeStore();
      final vault = KeyVault(persistent: store);
      await vault.saveProfile(_profile(), apiKey: 'sk-gone');

      await vault.deleteProfile('p1');

      expect(await vault.profiles(), isEmpty);
      expect(store.values.containsKey('credential:p1'), isFalse);
      expect(await vault.session.read('credential:p1'), isNull);
    });

    test('a corrupt profile index degrades to empty instead of throwing',
        () async {
      final store = _FakeStore()..values[VaultStore.profilesKey] = 'not json';
      expect(await KeyVault(persistent: store).profiles(), isEmpty);
    });
  });

  group('EncryptedIdbVaultStore', () {
    test('round-trips through real AES-GCM and stores only ciphertext',
        () async {
      final store = EncryptedIdbVaultStore(factory: idbFactoryMemory);
      addTearDown(store.close);

      await store.write('credential:p1', 'sk-web-secret');
      expect(await store.read('credential:p1'), 'sk-web-secret');
      expect(await store.keys(), {'credential:p1'});

      // Reach into the raw record: it must be sealed, not plaintext.
      final raw = (await store.debugRawRecord('credential:p1'))!;

      expect(raw.keys, containsAll(['cipherText', 'nonce', 'mac']));
      expect('$raw'.contains('sk-web-secret'), isFalse);
    });

    test('each write uses a fresh nonce', () async {
      final store = EncryptedIdbVaultStore(factory: idbFactoryMemory);
      addTearDown(store.close);

      await store.write('a', 'same-value');
      final first = (await store.debugRawRecord('a'))!['nonce'];
      await store.write('a', 'same-value');
      final second = (await store.debugRawRecord('a'))!['nonce'];

      expect(first, isNot(second));
    });

    test('a tampered record fails closed rather than decrypting', () async {
      final store = EncryptedIdbVaultStore(factory: idbFactoryMemory);
      addTearDown(store.close);
      await store.write('credential:p1', 'sk-original');

      final record = (await store.debugRawRecord('credential:p1'))!;
      await store.debugPutRaw('credential:p1', {
        ...record,
        'cipherText': base64Encode(
          base64Decode(record['cipherText'] as String)..[0] ^= 0xFF,
        ),
      });

      expect(await store.read('credential:p1'), isNull);
    });
  });

  group('ProviderPing', () {
    test('Anthropic uses GET /v1/models with x-api-key + anthropic-version',
        () async {
      final recorder = _Recorder();
      final result = await ProviderPing(clientFactory: () => recorder)
          .test(_profile(provider: AuthProvider.anthropic), 'sk-ant-key');

      final request = recorder.requests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://api.anthropic.com/v1/models');
      expect(request.headers['x-api-key'], 'sk-ant-key');
      expect(request.headers['anthropic-version'], '2023-06-01');
      // No bearer header — Anthropic authenticates with x-api-key.
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(result.ok, isTrue);
    });

    test('per-provider endpoint and auth header', () async {
      Future<http.BaseRequest> ping(AuthProvider provider) async {
        final recorder = _Recorder();
        await ProviderPing(clientFactory: () => recorder)
            .test(_profile(provider: provider), 'the-key');
        return recorder.requests.single;
      }

      final openai = await ping(AuthProvider.openAiCompatible);
      expect(openai.url.path, '/v1/models');
      expect(openai.headers['Authorization'], 'Bearer the-key');

      final gemini = await ping(AuthProvider.googleGemini);
      expect(gemini.url.path, '/v1beta/models');
      expect(gemini.headers['x-goog-api-key'], 'the-key');

      final ollama = await ping(AuthProvider.ollamaLocal);
      expect(ollama.url.toString(), 'http://localhost:11434/api/tags');
      expect(ollama.headers.containsKey('Authorization'), isFalse);
    });

    test('a missing key short-circuits before any request', () async {
      final recorder = _Recorder();
      final result = await ProviderPing(clientFactory: () => recorder)
          .test(_profile(provider: AuthProvider.anthropic), null);

      expect(result.ok, isFalse);
      expect(result.message, contains('No API key'));
      expect(recorder.requests, isEmpty);
    });

    test('Ollama needs no key', () async {
      final result = await ProviderPing(clientFactory: () => _Recorder())
          .test(_profile(provider: AuthProvider.ollamaLocal), null);
      expect(result.ok, isTrue);
    });

    test('status codes map to distinguishable causes', () async {
      Future<PingResult> withStatus(int status) =>
          ProviderPing(clientFactory: () => _Recorder(status: status))
              .test(_profile(provider: AuthProvider.anthropic), 'k');

      expect((await withStatus(401)).message, contains('Rejected credential'));
      expect((await withStatus(404)).message, contains('base URL'));
      expect((await withStatus(429)).message, contains('Rate limited'));
      expect((await withStatus(500)).message, contains('HTTP 500'));
    });

    test('a trailing slash on the base URL does not double up', () async {
      final recorder = _Recorder();
      await ProviderPing(clientFactory: () => recorder).test(
        const AuthProfile(
          id: 'p',
          displayName: 'x',
          provider: AuthProvider.anthropic,
          baseUrl: 'https://api.anthropic.com//',
          credentialRef: 'credential:p',
          maxContextTokens: 1,
        ),
        'k',
      );
      expect(recorder.requests.single.url.toString(),
          'https://api.anthropic.com/v1/models');
    });
  });

  group('KeyVaultDrawer', () {
    testWidgets('a stored key is never rendered back into the field',
        (tester) async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(), apiKey: 'sk-super-secret');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KeyVaultDrawer(vault: vault, profile: _profile()),
        ),
      ));
      await tester.pumpAndSettle();

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      for (final f in fields) {
        expect(f.controller?.text ?? '', isNot(contains('sk-super-secret')));
      }
      expect(find.text('A key is on file — type to replace it'), findsOneWidget);
      expect(find.textContaining('sk-super-secret'), findsNothing);
    });

    testWidgets('saving commits the profile and hands back the secret',
        (tester) async {
      final store = _FakeStore();
      final vault = KeyVault(persistent: store);
      AuthProfile? saved;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KeyVaultDrawer(vault: vault, onSaved: (p) => saved = p),
        ),
      ));

      await tester.enterText(find.byType(TextField).first, 'Local Ollama');
      await tester.enterText(
          find.ancestor(
            of: find.text('API Key'),
            matching: find.byType(TextField),
          ),
          'sk-typed');
      await tester.tap(find.text('Save Profile'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.displayName, 'Local Ollama');
      expect(await vault.secretFor(saved!), 'sk-typed');
      // Field cleared on success — the widget stops holding a copy.
      final key = tester.widget<TextField>(find.ancestor(
        of: find.text('API Key'),
        matching: find.byType(TextField),
      ));
      expect(key.controller!.text, isEmpty);
    });

    testWidgets('validation blocks an empty name', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyVaultDrawer(vault: KeyVault(persistent: _FakeStore()))),
      ));

      await tester.tap(find.text('Save Profile'));
      await tester.pumpAndSettle();

      expect(find.text('Display Name is required'), findsOneWidget);
    });

    testWidgets('the masked field toggles', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyVaultDrawer(vault: KeyVault(persistent: _FakeStore()))),
      ));

      expect(find.byTooltip('Show key'), findsOneWidget);
      await tester.tap(find.byTooltip('Show key'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide key'), findsOneWidget);
    });
  });

  group('SecureSettingsNode', () {
    Future<KeyVault> seeded({bool withKey = true}) async {
      final vault = KeyVault(persistent: _FakeStore());
      await vault.saveProfile(_profile(), apiKey: withKey ? 'sk-x' : null);
      return vault;
    }

    testWidgets('emits metadata only, on authOutput', (tester) async {
      final vault = await seeded();
      final emitted = <AaPayload>[];
      OutputPort? out;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SecureSettingsNode(
            node: const WorkflowNode(id: 5, type: 'secureSettingsNode'),
            initialParams: const {'selectedProfileId': 'p1'},
            vault: vault,
            onOutputPort: (p) {
              out = p;
              p.connect(emitted.add, emitCurrentState: false);
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(out!.id, 'authOutput');
      expect(find.text('authOutput'), findsOneWidget);
      expect(find.text('Secure Settings'), findsOneWidget);

      // Selecting republishes; the payload must be metadata only.
      await tester.tap(find.text('Work Gemini Pro').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Gemini Pro').last);
      await tester.pumpAndSettle();

      expect(emitted, isNotEmpty);
      final aa = emitted.last;
      expect(aa.cols, contains('credentialRef'));
      expect(aa.vals, contains('credential:p1'));
      expect(aa.vals.contains('sk-x'), isFalse);
    });

    testWidgets('a profile with no key reads error and stays off the wire',
        (tester) async {
      final vault = await seeded(withKey: false);
      final emitted = <AaPayload>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SecureSettingsNode(
            node: const WorkflowNode(id: 5, type: 'secureSettingsNode'),
            initialParams: const {'selectedProfileId': 'p1'},
            vault: vault,
            onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('no key on file'), findsOneWidget);
      expect(emitted, isEmpty);
    });

    testWidgets('params persist the profile pointer, never the key',
        (tester) async {
      final vault = await seeded();
      Map<String, String>? params;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SecureSettingsNode(
            node: const WorkflowNode(id: 5, type: 'secureSettingsNode'),
            vault: vault,
            onParams: (p) => params = p,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Work Gemini Pro').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Gemini Pro').last);
      await tester.pumpAndSettle();

      expect(params, {'selectedProfileId': 'p1'});
      expect(jsonEncode(params).contains('sk-'), isFalse);
    });

    testWidgets('Add opens the vault drawer as this node\'s panel',
        (tester) async {
      final vault = await seeded();
      FocusContent? content;
      var views = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SecureSettingsNode(
            node: const WorkflowNode(id: 5, type: 'secureSettingsNode'),
            vault: vault,
            onContent: (_, c) => content = c,
            onView: (_) => views++,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(content, isNull); // nothing conjured before the user asks

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(views, 1);
      expect(content!.kind, FocusContentKind.panel);
      expect(content!.child, isA<KeyVaultDrawer>());
      expect(content!.subtitle, 'New profile');
    });
  });
}
