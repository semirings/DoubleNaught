import 'dart:async';
import 'dart:convert';

import 'package:double_vision/config/node_registry.dart';
import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/pages/workflow_page.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/remote/model_catalog.dart';
import 'package:double_vision/services/vault/key_vault.dart';
import 'package:double_vision/services/vault/vault_store.dart';
import 'package:double_vision/widgets/nodes/nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeStore implements VaultStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _profile = AuthProfile(
  id: 'p1',
  displayName: 'Work Gemini',
  provider: AuthProvider.googleGemini,
  baseUrl: 'https://generativelanguage.googleapis.com',
  credentialRef: 'credential:p1',
  maxContextTokens: 1048576,
);

Future<KeyVault> _vaultWithProfile() async {
  final vault = KeyVault(persistent: _FakeStore());
  await vault.saveProfile(_profile, apiKey: 'sk-stored');
  return vault;
}

// This node was originally "Remote Service": a vault-backed node dispatching
// to a user-picked provider (Anthropic/OpenAI/Gemini/Ollama) via
// `RemoteRequest`, with a live `ModelCatalog` fetch for the model picker.
// That design was fully replaced by a from-scratch rewrite (the backend grew
// `llm_better_doc.py`, a local-model AST enricher) before the node was
// renamed to "LLM Documenter" — the two are unrelated beyond the name.
// `RemoteRequest` and `ModelCatalog` are still real, live code (used by other
// nodes and kept in their own test files at test/services/); this file only
// covers what LLMDocumenterNodeWidget actually does today.

const _schema = [
  'symbol_name',
  'kind',
  'file_path',
  'line_range',
  'docstring',
  'raw_code',
  'better_docstring',
];

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _enrichBody({
  int rowsProcessed = 1,
  List<String> rows = const ['a.jl:0:0'],
}) {
  final outRows = <String>[];
  final outCols = <String>[];
  final outVals = <String>[];
  for (final key in rows) {
    for (final column in _schema) {
      outRows.add(key);
      outCols.add(column);
      outVals.add(column == 'better_docstring' ? 'Adds one to x.' : '');
    }
  }
  return {
    'enrichedIndex': {'rows': outRows, 'cols': outCols, 'vals': outVals},
    'rowsProcessed': rowsProcessed,
  };
}

/// A 7-column index in wire form, one row.
const _index = AaPayload(
  rows: ['a.jl:0:0', 'a.jl:0:0'],
  cols: ['symbol_name', 'raw_code'],
  vals: ['add_one', 'add_one(x) = x + 1'],
);

Future<
    ({
      InputPort input,
      InputPort auth,
      InputPort prompt,
      List<AaPayload> emitted,
      List<Map<String, dynamic>> requests,
    })> _pump(
  WidgetTester tester, {
  http.Client Function()? clientFactory,
  Map<String, String>? initialParams,
  bool inputConnected = false,
  KeyVault? vault,
  ModelCatalog? modelCatalog,
}) async {
  InputPort? port;
  InputPort? authPort;
  InputPort? promptPort;
  final emitted = <AaPayload>[];
  final requests = <Map<String, dynamic>>[];

  final factory = clientFactory ??
      () => MockClient((request) async {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonResponse(_enrichBody());
          });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LLMDocumenterNodeWidget(
            node: const WorkflowNode(id: 1, type: 'llmDocumenterNode'),
            initialParams: initialParams,
            clientFactory: factory,
            inputConnected: inputConnected,
            onAuthInputPort: (p) => authPort = p,
            onPromptInputPort: (p) => promptPort = p,
            vault: vault,
            modelCatalog: modelCatalog,
            onInputPort: (p) => port = p,
            onOutputPort: (p) => p.connect(emitted.add, emitCurrentState: false),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    input: port!,
    auth: authPort!,
    prompt: promptPort!,
    emitted: emitted,
    requests: requests,
  );
}

Future<void> _send(WidgetTester tester, InputPort port, AaPayload aa) async {
  port.connect(OutputPort('upstream')..emit(aa));
  await tester.pumpAndSettle();
}

/// The remote Model-id text field specifically — scoped by its "Model ("
/// label, since the Model *choice* dropdown (Local/Gemini) is itself
/// backed by a `TextField` and would otherwise collide with
/// `find.byType(TextField).first`.
Finder _remoteModelField() => find.ancestor(
      of: find.textContaining('Model ('),
      matching: find.byType(TextField),
    );

/// Opens the Model choice dropdown and picks [label] ('Gemini' or the local
/// SLM id).
Future<void> _pickModelChoice(WidgetTester tester, String label) async {
  await tester.tap(find.ancestor(
    of: find.text('Model'),
    matching: find.byType(TextField),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('catalog registration', () {
    test('LLM Documenter is registered', () {
      final entry = nodeTypes.singleWhere((t) => t.type == 'llmDocumenterNode');
      expect(entry.name, 'LLM Documenter');
    });
  });

  group('readiness', () {
    testWidgets('starts with Execute disabled and no removed hint text',
        (tester) async {
      await _pump(tester);

      expect(find.text('LLM Documenter'), findsOneWidget);
      expect(find.textContaining('Waiting for astIndex'), findsNothing);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
    });

    testWidgets('the Model choice defaults to Gemini, with the local SLM '
        'still selectable', (tester) async {
      await _pump(tester);

      expect(find.text('Gemini'), findsOneWidget);
      expect(find.text('mlx-community/Phi-4-mini-instruct-4bit'), findsNothing,
          reason: 'not shown until the Local choice is picked');

      await _pickModelChoice(tester, 'mlx-community/Phi-4-mini-instruct-4bit');
      expect(find.text('mlx-community/Phi-4-mini-instruct-4bit'), findsOneWidget);
    });

    testWidgets('with the Local choice, a connected payload alone enables '
        'Execute — no credential needed', (tester) async {
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
      );
      await _send(tester, h.input, _index);

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('with the default Gemini choice, a connected payload alone '
        'is NOT enough — Execute stays disabled without a matching '
        'credential (no silent fallback to local)', (tester) async {
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );
      expect(find.textContaining('Connect a Secure Settings credential'),
          findsOneWidget);
    });

    testWidgets('connecting a credential for a DIFFERENT provider than the '
        'one selected does not enable Execute either', (tester) async {
      const anthropicProfile = AuthProfile(
        id: 'p2',
        displayName: 'Work Anthropic',
        provider: AuthProvider.anthropic,
        baseUrl: 'https://api.anthropic.com',
        credentialRef: 'credential:p2',
        maxContextTokens: 1000000,
      );
      final h = await _pump(tester, inputConnected: true);
      await _send(tester, h.input, _index);
      await _send(tester, h.auth, anthropicProfile.toAa());

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
        reason: 'Gemini is selected but the connected credential is Anthropic',
      );
    });

    testWidgets('Execute updates live: connecting a matching credential, or '
        'switching to Local, enables it without reconnecting astIndex',
        (tester) async {
      final h = await _pump(tester, inputConnected: true, vault: await _vaultWithProfile());
      await _send(tester, h.input, _index);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _send(tester, h.auth, _profile.toAa());
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'a matching credential just connected, live',
      );

      h.auth.disconnect();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _pickModelChoice(tester, 'mlx-community/Phi-4-mini-instruct-4bit');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'switching to Local needs no credential at all',
      );
    });
  });

  group('Wait/Execute mechanism', () {
    testWidgets(
        'reactive (Wait unchecked, the default): fires as soon as a '
        'payload arrives',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );

      await _send(tester, h.input, _index);

      expect(h.emitted, hasLength(1));
      expect(find.textContaining('done'), findsOneWidget);
    });

    testWidgets('gated (Wait checked): a ready payload does not auto-fire',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});

      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();

      await _send(tester, h.input, _index);

      expect(h.emitted, isEmpty, reason: 'gated — nothing fires until Execute');
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
      );
    });

    testWidgets('clicking Execute fires immediately and unchecks Wait',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});

      await tester.tap(find.byType(WaitCheckbox)); // gate it
      await tester.pumpAndSettle();
      await _send(tester, h.input, _index);

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      expect(h.emitted, hasLength(1));
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
      );
    });

    testWidgets(
        'manually unchecking Wait fires immediately when already ready',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await _send(tester, h.input, _index);
      expect(h.emitted, isEmpty);

      await tester.tap(find.byType(WaitCheckbox)); // uncheck while ready
      await tester.pumpAndSettle();
      expect(h.emitted, hasLength(1));
    });

    testWidgets(
        'unchecking Wait while NOT ready just becomes reactive — fires '
        'later once ready, not immediately',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});

      await tester.tap(find.byType(WaitCheckbox)); // check: gated
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WaitCheckbox)); // uncheck — not ready yet
      await tester.pumpAndSettle();
      expect(h.emitted, isEmpty);

      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(1), reason: 'now reactive and ready');
    });

    testWidgets('Wait is locked (unresponsive) while executing', (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index); // auto-fires

      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).locked,
        isTrue,
      );
      await tester.tap(find.byType(WaitCheckbox));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WaitCheckbox>(find.byType(WaitCheckbox)).checked,
        isFalse,
        reason: 'locked — the tap must not have toggled it',
      );

      response.complete(_jsonResponse(_enrichBody()));
      await tester.pumpAndSettle();
    });
  });

  group('enrichment', () {
    testWidgets('emits the enriched index and reports counts', (tester) async {
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
        clientFactory: () => MockClient(
          (request) async => _jsonResponse(_enrichBody(rowsProcessed: 3)),
        ),
      );
      await _send(tester, h.input, _index);

      expect(find.textContaining('done'), findsOneWidget);
      expect(find.textContaining('3 documented'), findsOneWidget);
      expect(h.emitted, hasLength(1));
      expect(h.emitted.single.cols, contains('better_docstring'));
    });

    testWidgets('sends the fixed model id and the numeric fields',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});
      await _send(tester, h.input, _index);

      final sent = h.requests.single;
      expect(sent['modelId'], 'mlx-community/Phi-4-mini-instruct-4bit');
      expect(sent['maxTokens'], 256);
      expect(sent['temperature'], 0.7);
    });

    testWidgets('unparseable Max Tokens / Temperature fall back to defaults '
        'rather than blocking Execute', (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});
      await _send(tester, h.input, _index);

      await tester.enterText(
        find.ancestor(
          of: find.text('Max Tokens'),
          matching: find.byType(TextField),
        ),
        'lots',
      );
      await tester.enterText(
        find.ancestor(
          of: find.text('Temperature'),
          matching: find.byType(TextField),
        ),
        'warm',
      );

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isTrue,
        reason: 'invalid numeric text falls back to a default, like Polyglot '
            "Exec's Timeout field — it does not gate Execute",
      );

      await tester.tap(find.byType(ExecuteButton));
      await tester.pumpAndSettle();

      final sent = h.requests.last;
      expect(sent['maxTokens'], 256);
      expect(sent['temperature'], 0.7);
    });

    testWidgets('a backend failure is reported and emits nothing',
        (tester) async {
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
        clientFactory: () => MockClient(
          (request) async =>
              http.Response('{"detail":"model unavailable"}', 500),
        ),
      );
      await _send(tester, h.input, _index);

      expect(find.textContaining('error'), findsOneWidget);
      expect(find.textContaining('model unavailable'), findsOneWidget);
      expect(h.emitted, isEmpty);
    });

    testWidgets(
        'disconnecting clears the previous result and disables Execute; a '
        'new payload re-fires fresh',
        (tester) async {
      final h = await _pump(tester, inputConnected: true,
        initialParams: const {'modelChoice': 'local'});
      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(1));

      h.input.disconnect();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).enabled,
        isFalse,
      );

      await _send(tester, h.input, _index);
      expect(h.emitted, hasLength(2),
          reason: 'reactive by default — the new payload fires fresh');
    });
  });

  group('Cancel — hard abort', () {
    testWidgets(
        'clicking Cancel reverts to idle immediately, before the request '
        'resolves — and a later-arriving success is discarded',
        (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index); // auto-fires

      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isTrue,
      );
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      expect(find.textContaining('idle'), findsOneWidget);
      expect(
        tester.widget<ExecuteButton>(find.byType(ExecuteButton)).executing,
        isFalse,
      );

      response.complete(_jsonResponse(_enrichBody()));
      await tester.pumpAndSettle();

      expect(h.emitted, isEmpty, reason: 'the cancelled run\'s result must not emit');
      expect(find.textContaining('idle'), findsOneWidget);
    });

    testWidgets('cancelling never surfaces error status', (tester) async {
      final response = Completer<http.Response>();
      final h = await _pump(
        tester,
        inputConnected: true,
        initialParams: const {'modelChoice': 'local'},
        clientFactory: () =>
            MockClient((_) => response.future),
      );

      await _send(tester, h.input, _index);
      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      response.completeError(Exception('socket closed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('error'), findsNothing);
      expect(find.textContaining('idle'), findsOneWidget);
    });
  });

  group('remote-provider dispatch (authInput connected)', () {
    /// A two-row index so per-row success/failure can differ across rows.
    const twoRowIndex = AaPayload(
      rows: ['a.jl:0:0', 'a.jl:0:0', 'a.jl:1:1', 'a.jl:1:1'],
      cols: ['symbol_name', 'raw_code', 'symbol_name', 'raw_code'],
      vals: ['add_one', 'add_one(x) = x + 1', 'sub_one', 'sub_one(x) = x - 1'],
    );

    Map<String, dynamic> mergedBody(Map<String, dynamic> astIndex, Map docstrings) {
      final rows = List<String>.from(astIndex['rows'] as List);
      final cols = List<String>.from(astIndex['cols'] as List);
      final vals = List.from(astIndex['vals'] as List);
      docstrings.forEach((row, text) {
        rows.add(row as String);
        cols.add('better_docstring');
        vals.add(text);
      });
      return {
        'enrichedIndex': {'rows': rows, 'cols': cols, 'vals': vals},
        'rowsProcessed': docstrings.length,
      };
    }

    /// A backend+remote fake: routes `/llm/build-prompts` and
    /// `/llm/merge-docstrings` to this backend's shape, and everything else
    /// (Gemini's own dispatch path) to [remoteHandler].
    http.Client Function() remoteFactory({
      required List<Map<String, dynamic>> buildPromptRequests,
      required List<Map<String, dynamic>> remoteRequests,
      required List<Map<String, dynamic>> mergeRequests,
      required http.Response Function(Map<String, dynamic> body) remoteHandler,
    }) {
      return () => MockClient((request) async {
            final path = request.url.path;
            final body = jsonDecode(request.body) as Map<String, dynamic>;

            if (path == '/llm/build-prompts') {
              buildPromptRequests.add(body);
              final astIndex = body['astIndex'] as Map<String, dynamic>;
              final rows = List<String>.from(astIndex['rows'] as List);
              final seen = <String>{};
              final prompts = [
                for (final r in rows)
                  if (seen.add(r)) {'rowKey': r, 'symbol': 'sym', 'prompt': 'Document $r'},
              ];
              return _jsonResponse({'prompts': prompts});
            }
            if (path == '/llm/merge-docstrings') {
              mergeRequests.add(body);
              return _jsonResponse(mergedBody(
                body['astIndex'] as Map<String, dynamic>,
                body['docstrings'] as Map,
              ));
            }
            remoteRequests.add(body);
            return remoteHandler(body);
          });
    }

    http.Response geminiOk(String text) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
            },
          ],
        });

    testWidgets('the remote model field is shown for the default Gemini '
        'choice even before a credential connects, labeled generically; '
        'connecting one specialises the label; switching to Local hides it',
        (tester) async {
      final h = await _pump(tester);
      expect(_remoteModelField(), findsOneWidget);
      expect(find.text('Model (Google Gemini)'), findsOneWidget,
          reason: 'falls back to the provider default label with no profile connected yet');

      await _send(tester, h.auth, _profile.toAa());
      expect(find.text('Model (Google Gemini)'), findsOneWidget,
          reason: 'now reflecting the actually-connected profile');

      h.auth.disconnect();
      await tester.pumpAndSettle();
      expect(_remoteModelField(), findsOneWidget, reason: 'Gemini is still the choice');

      await _pickModelChoice(tester, 'mlx-community/Phi-4-mini-instruct-4bit');
      expect(_remoteModelField(), findsNothing);
      expect(find.text('mlx-community/Phi-4-mini-instruct-4bit'), findsOneWidget);
    });

    testWidgets('firing with a connected profile dispatches build-prompts, '
        'one remote call per definition, then merge-docstrings', (tester) async {
      final buildPromptRequests = <Map<String, dynamic>>[];
      final remoteRequests = <Map<String, dynamic>>[];
      final mergeRequests = <Map<String, dynamic>>[];
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: remoteFactory(
          buildPromptRequests: buildPromptRequests,
          remoteRequests: remoteRequests,
          mergeRequests: mergeRequests,
          remoteHandler: (_) => geminiOk('Generated doc.'),
        ),
      );
      await _send(tester, h.auth, _profile.toAa());
      await tester.enterText(_remoteModelField(), 'gemini-pro');
      await _send(tester, h.input, twoRowIndex);

      expect(buildPromptRequests, hasLength(1));
      expect(remoteRequests, hasLength(2), reason: 'one per definition');
      expect(mergeRequests, hasLength(1));
      expect(mergeRequests.single['docstrings'], {
        'a.jl:0:0': 'Generated doc.',
        'a.jl:1:1': 'Generated doc.',
      });

      expect(h.emitted, hasLength(1));
      expect(h.emitted.single.cols, contains('better_docstring'));
      expect(find.textContaining('2 documented'), findsOneWidget);
    });

    testWidgets('the vault-redeemed key reaches the provider, never the backend',
        (tester) async {
      String? seenKeyHeader;
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: () => MockClient((request) async {
              if (request.url.path == '/llm/build-prompts') {
                return _jsonResponse({
                  'prompts': [
                    {'rowKey': 'a.jl:0:0', 'symbol': 'add_one', 'prompt': 'Document it'},
                  ],
                });
              }
              if (request.url.path == '/llm/merge-docstrings') {
                final body = jsonDecode(request.body) as Map<String, dynamic>;
                return _jsonResponse(mergedBody(
                  body['astIndex'] as Map<String, dynamic>,
                  body['docstrings'] as Map,
                ));
              }
              seenKeyHeader = request.headers['x-goog-api-key'];
              return geminiOk('Doc.');
            }),
      );
      await _send(tester, h.auth, _profile.toAa());
      await tester.enterText(_remoteModelField(), 'gemini-pro');
      await _send(tester, h.input, _index);

      expect(seenKeyHeader, 'sk-stored');
    });

    testWidgets('a connected Prompt node adds its text to build-prompts as a hint',
        (tester) async {
      final buildPromptRequests = <Map<String, dynamic>>[];
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: remoteFactory(
          buildPromptRequests: buildPromptRequests,
          remoteRequests: [],
          mergeRequests: [],
          remoteHandler: (_) => geminiOk('Doc.'),
        ),
      );
      await _send(tester, h.auth, _profile.toAa());
      await _send(
        tester,
        h.prompt,
        const AaPayload(rows: ['prompt:9'], cols: ['prompt'], vals: ['Explain for a junior dev.']),
      );
      await _send(tester, h.input, _index);

      expect(buildPromptRequests.single['promptHint'], 'Explain for a junior dev.');
    });

    testWidgets('a per-row failure is skipped, not fatal — the rest still merge',
        (tester) async {
      var call = 0;
      final mergeRequests = <Map<String, dynamic>>[];
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: () => MockClient((request) async {
              if (request.url.path == '/llm/build-prompts') {
                final astIndex =
                    (jsonDecode(request.body) as Map<String, dynamic>)['astIndex']
                        as Map<String, dynamic>;
                final rows = List<String>.from(astIndex['rows'] as List).toSet();
                return _jsonResponse({
                  'prompts': [
                    for (final r in rows) {'rowKey': r, 'symbol': 'sym', 'prompt': 'Doc $r'},
                  ],
                });
              }
              if (request.url.path == '/llm/merge-docstrings') {
                final body = jsonDecode(request.body) as Map<String, dynamic>;
                mergeRequests.add(body);
                return _jsonResponse(mergedBody(
                  body['astIndex'] as Map<String, dynamic>,
                  body['docstrings'] as Map,
                ));
              }
              call++;
              // The first remote call fails, the second succeeds.
              return call == 1
                  ? http.Response('{}', 500)
                  : geminiOk('Doc for the survivor.');
            }),
      );
      await _send(tester, h.auth, _profile.toAa());
      await tester.enterText(_remoteModelField(), 'gemini-pro');
      await _send(tester, h.input, twoRowIndex);

      expect(mergeRequests.single['docstrings'], hasLength(1));
      expect(find.textContaining('1 documented'), findsOneWidget);
      expect(find.textContaining('1 failed'), findsOneWidget);
      expect(h.emitted, hasLength(1));
    });

    testWidgets('every row failing is an error, and merge-docstrings is never called',
        (tester) async {
      final mergeRequests = <Map<String, dynamic>>[];
      final remoteRequests = <Map<String, dynamic>>[];
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: remoteFactory(
          buildPromptRequests: [],
          remoteRequests: remoteRequests,
          mergeRequests: mergeRequests,
          remoteHandler: (_) => http.Response('{}', 500),
        ),
      );
      await _send(tester, h.auth, _profile.toAa());
      await tester.enterText(_remoteModelField(), 'gemini-pro');
      await _send(tester, h.input, _index);

      expect(remoteRequests, hasLength(1), reason: 'the provider really was called');
      expect(mergeRequests, isEmpty);
      expect(h.emitted, isEmpty);
      expect(find.textContaining('error'), findsOneWidget);
    });

    testWidgets('Cancel mid-loop stops dispatching further rows and never merges',
        (tester) async {
      final secondCallStarted = Completer<void>();
      final releaseSecondCall = Completer<http.Response>();
      final mergeRequests = <Map<String, dynamic>>[];
      var remoteCallCount = 0;
      final h = await _pump(
        tester,
        inputConnected: true,
        vault: await _vaultWithProfile(),
        clientFactory: () => MockClient((request) async {
              if (request.url.path == '/llm/build-prompts') {
                return _jsonResponse({
                  'prompts': [
                    {'rowKey': 'a.jl:0:0', 'symbol': 's1', 'prompt': 'Doc 1'},
                    {'rowKey': 'a.jl:1:1', 'symbol': 's2', 'prompt': 'Doc 2'},
                  ],
                });
              }
              if (request.url.path == '/llm/merge-docstrings') {
                mergeRequests.add(jsonDecode(request.body) as Map<String, dynamic>);
                return _jsonResponse({
                  'enrichedIndex': {'rows': [], 'cols': [], 'vals': []},
                  'rowsProcessed': 0,
                });
              }
              remoteCallCount++;
              if (remoteCallCount == 1) return geminiOk('First doc.');
              secondCallStarted.complete();
              return releaseSecondCall.future;
            }),
      );
      await _send(tester, h.auth, _profile.toAa());
      await tester.enterText(_remoteModelField(), 'gemini-pro');
      await _send(tester, h.input, twoRowIndex); // auto-fires, blocks on row 2

      await secondCallStarted.future;
      await tester.tap(find.byType(ExecuteButton)); // Cancel
      await tester.pump();

      expect(find.textContaining('idle'), findsOneWidget);

      releaseSecondCall.complete(geminiOk('Too late.'));
      await tester.pumpAndSettle();

      expect(mergeRequests, isEmpty, reason: 'cancelled before a 3rd row could even start');
      expect(h.emitted, isEmpty);
      expect(find.textContaining('idle'), findsOneWidget);
    });

    testWidgets('the "Available models" fetch fills the model field on pick',
        (tester) async {
      final h = await _pump(
        tester,
        vault: await _vaultWithProfile(),
        modelCatalog: ModelCatalog(
          clientFactory: () => MockClient((request) async => _jsonResponse({
                'models': [
                  {
                    'name': 'models/gemini-fast',
                    'supportedGenerationMethods': ['generateContent'],
                  },
                ],
              })),
        ),
      );
      await _send(tester, h.auth, _profile.toAa());

      await tester.tap(find.byTooltip('Available models'));
      await tester.pumpAndSettle();

      expect(find.text('gemini-fast'), findsOneWidget);
      await tester.tap(find.text('gemini-fast'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(_remoteModelField()).controller!.text,
        'gemini-fast',
      );
    });
  });

  testWidgets('the Node Catalog instantiates it onto the canvas',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkflowPage()));
    await tester.tap(find.text('Node Catalog'));
    await tester.pumpAndSettle();

    final item = find.text('LLM Documenter').last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byType(LLMDocumenterNodeWidget), findsOneWidget);
    expect(find.textContaining('Waiting for astIndex'), findsNothing);
  });
}
