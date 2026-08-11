import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/auth_profile.dart';

/// What came back from a remote service, normalised across providers.
class RemoteResult {
  /// `ok`, `error`, or `cancelled` — the `status` column of the emitted AA.
  final String status;

  /// The assistant/service text, or empty when the call failed.
  final String text;

  /// Empty on success. Never contains the credential.
  final String errorMsg;

  final int executionTimeMs;

  /// Bytes of response body actually read — surfaced as node telemetry.
  final int bytes;

  const RemoteResult({
    required this.status,
    this.text = '',
    this.errorMsg = '',
    required this.executionTimeMs,
    this.bytes = 0,
  });

  bool get ok => status == 'ok';
}

/// Progress states the node's status bar renders.
enum RemotePhase { idle, connecting, streaming, done, error }

/// Builds, dispatches, and normalises a single request to whichever provider a
/// profile names — see `DESIGN.md` → "Remote Service node".
///
/// Each provider gets its documented chat/generate endpoint and auth scheme:
///
/// | Provider | Endpoint | Credential carried as |
/// |---|---|---|
/// | Anthropic | `POST /v1/messages` | `x-api-key` + `anthropic-version: 2023-06-01` |
/// | OpenAI/Compatible | `POST /v1/chat/completions` | `Authorization: Bearer …` |
/// | Google Gemini | `POST /v1beta/models/{model}:generateContent` | `x-goog-api-key` |
/// | Ollama Local | `POST /api/generate` | none — local daemon |
///
/// The response **body** is read as a stream so the node can report bytes as
/// they arrive; the request itself is non-streaming (`stream: false`). Token-level
/// SSE would mean four different event dialects and is deliberately out of scope
/// — "Streaming response…" here means the body is arriving, not that tokens are
/// being rendered one by one.
class RemoteRequest {
  /// Model ids that are safe to pre-fill. Anthropic's is the current default
  /// per Anthropic's own guidance; the others vary per account and deployment,
  /// so they stay blank rather than shipping a guess that 404s.
  static const Map<AuthProvider, String> defaultModels = {
    AuthProvider.anthropic: 'claude-opus-5',
    AuthProvider.googleGemini: '',
    AuthProvider.openAiCompatible: '',
    AuthProvider.ollamaLocal: '',
  };

  /// Cap on the reply. Anthropic requires `max_tokens`; the others treat it as
  /// advisory.
  static const int maxTokens = 4096;

  final http.Client client;
  final Duration timeout;

  /// Reports phase transitions and bytes received, for the node's status bar.
  final void Function(RemotePhase phase, int bytes)? onProgress;

  RemoteRequest({
    required this.client,
    this.timeout = const Duration(seconds: 120),
    this.onProgress,
  });

  static String pathFor(AuthProvider provider, String model) =>
      switch (provider) {
        AuthProvider.anthropic => '/v1/messages',
        AuthProvider.openAiCompatible => '/v1/chat/completions',
        // Gemini names the model in the path, not the body.
        AuthProvider.googleGemini =>
          '/v1beta/models/$model:generateContent',
        AuthProvider.ollamaLocal => '/api/generate',
      };

  static Map<String, String> headersFor(
    AuthProvider provider,
    String? apiKey,
  ) =>
      switch (provider) {
        AuthProvider.anthropic => {
            'content-type': 'application/json',
            'x-api-key': apiKey ?? '',
            // Required on every Anthropic request; omitting it fails for a
            // reason that reads like a bad key.
            'anthropic-version': '2023-06-01',
          },
        AuthProvider.openAiCompatible => {
            'content-type': 'application/json',
            'Authorization': 'Bearer ${apiKey ?? ''}',
          },
        AuthProvider.googleGemini => {
            'content-type': 'application/json',
            'x-goog-api-key': apiKey ?? '',
          },
        AuthProvider.ollamaLocal => {'content-type': 'application/json'},
      };

  static Map<String, Object?> bodyFor(
    AuthProvider provider,
    String model,
    String prompt,
  ) =>
      switch (provider) {
        AuthProvider.anthropic => {
            'model': model,
            'max_tokens': maxTokens,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          },
        AuthProvider.openAiCompatible => {
            'model': model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'stream': false,
          },
        AuthProvider.googleGemini => {
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
          },
        AuthProvider.ollamaLocal => {
            'model': model,
            'prompt': prompt,
            'stream': false,
          },
      };

  /// Pull the reply text out of a decoded success body.
  ///
  /// Anthropic gets an extra guard: a request its safety classifiers decline
  /// returns **HTTP 200** with `stop_reason: "refusal"` and possibly an empty
  /// `content` array, so reading `content[0]` unconditionally would throw on a
  /// perfectly well-formed response.
  static RemoteResult extract(
    AuthProvider provider,
    Map<String, Object?> json, {
    required int elapsedMs,
    int bytes = 0,
  }) {
    String? text;
    switch (provider) {
      case AuthProvider.anthropic:
        if (json['stop_reason'] == 'refusal') {
          final details = json['stop_details'];
          final category =
              details is Map ? '${details['category'] ?? 'unspecified'}' : 'unspecified';
          return RemoteResult(
            status: 'error',
            errorMsg: 'Declined by provider safety policy ($category)',
            executionTimeMs: elapsedMs,
            bytes: bytes,
          );
        }
        final content = json['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map && block['type'] == 'text') {
              text = '${block['text']}';
              break;
            }
          }
        }
      case AuthProvider.openAiCompatible:
        final choices = json['choices'];
        if (choices is List && choices.isNotEmpty) {
          final message = (choices.first as Map)['message'];
          if (message is Map) text = '${message['content']}';
        }
      case AuthProvider.googleGemini:
        final candidates = json['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final parts = ((candidates.first as Map)['content'] as Map?)?['parts'];
          if (parts is List && parts.isNotEmpty) {
            text = '${(parts.first as Map)['text']}';
          }
        }
      case AuthProvider.ollamaLocal:
        final response = json['response'];
        if (response is String) text = response;
    }

    if (text == null || text.isEmpty) {
      return RemoteResult(
        status: 'error',
        errorMsg: 'No text in the provider response',
        executionTimeMs: elapsedMs,
        bytes: bytes,
      );
    }
    return RemoteResult(
      status: 'ok',
      text: text,
      executionTimeMs: elapsedMs,
      bytes: bytes,
    );
  }

  /// Dispatch [prompt] to the service [profile] names.
  ///
  /// Never throws: every failure — bad URL, refused credential, timeout, a
  /// cancel — comes back as a [RemoteResult] so the node always has an AA to
  /// emit. Cancel is `client.close()` from the caller, which surfaces here as a
  /// broken connection and is reported as `cancelled` rather than an error.
  Future<RemoteResult> send({
    required AuthProfile profile,
    required String model,
    required String prompt,
    String? apiKey,
  }) async {
    final started = DateTime.now();
    int elapsed() => DateTime.now().difference(started).inMilliseconds;

    var base = profile.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.tryParse('$base${pathFor(profile.provider, model)}');
    if (base.isEmpty || uri == null || !uri.hasScheme) {
      return RemoteResult(
        status: 'error',
        errorMsg: 'Not a valid base URL: "${profile.baseUrl}"',
        executionTimeMs: elapsed(),
      );
    }

    final needsKey = profile.provider != AuthProvider.ollamaLocal;
    if (needsKey && (apiKey == null || apiKey.isEmpty)) {
      return RemoteResult(
        status: 'error',
        errorMsg: 'No credential redeemable for this profile',
        executionTimeMs: elapsed(),
      );
    }
    if (model.isEmpty) {
      return RemoteResult(
        status: 'error',
        errorMsg: 'Set a model id for ${profile.provider.label}',
        executionTimeMs: elapsed(),
      );
    }

    onProgress?.call(RemotePhase.connecting, 0);
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(headersFor(profile.provider, apiKey))
        ..body = jsonEncode(bodyFor(profile.provider, model, prompt));

      final response = await client.send(request).timeout(timeout);

      // Headers are in; the body is on its way.
      onProgress?.call(RemotePhase.streaming, 0);
      final chunks = <int>[];
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        onProgress?.call(RemotePhase.streaming, chunks.length);
      }
      final bytes = chunks.length;
      final bodyText = utf8.decode(chunks, allowMalformed: true);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        onProgress?.call(RemotePhase.error, bytes);
        return RemoteResult(
          status: 'error',
          errorMsg: _httpError(response.statusCode, bodyText),
          executionTimeMs: elapsed(),
          bytes: bytes,
        );
      }

      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, Object?>) {
        onProgress?.call(RemotePhase.error, bytes);
        return RemoteResult(
          status: 'error',
          errorMsg: 'Provider returned a non-object body',
          executionTimeMs: elapsed(),
          bytes: bytes,
        );
      }

      final result = extract(
        profile.provider,
        decoded,
        elapsedMs: elapsed(),
        bytes: bytes,
      );
      onProgress?.call(
        result.ok ? RemotePhase.done : RemotePhase.error,
        bytes,
      );
      return result;
    } on TimeoutException {
      onProgress?.call(RemotePhase.error, 0);
      return RemoteResult(
        status: 'error',
        errorMsg: 'No response in ${timeout.inSeconds}s',
        executionTimeMs: elapsed(),
      );
    } on http.ClientException catch (e) {
      // A cancel closes the client mid-flight, which lands here. Distinguishing
      // it from a genuine network fault is the caller's job — it knows whether
      // it asked to stop — so report the shape and let the node relabel.
      onProgress?.call(RemotePhase.error, 0);
      return RemoteResult(
        status: 'error',
        errorMsg: 'Connection failed: ${e.message}',
        executionTimeMs: elapsed(),
      );
    } on FormatException {
      onProgress?.call(RemotePhase.error, 0);
      return RemoteResult(
        status: 'error',
        errorMsg: 'Provider response was not valid JSON',
        executionTimeMs: elapsed(),
      );
    } catch (e) {
      onProgress?.call(RemotePhase.error, 0);
      return RemoteResult(
        status: 'error',
        errorMsg: e.runtimeType.toString(),
        executionTimeMs: elapsed(),
      );
    }
  }

  /// Turn a non-2xx into something actionable, including the provider's own
  /// error text when it supplies one.
  ///
  /// Bodies are quoted but truncated, and only ever the *response* — a request
  /// echo could carry the Authorization header.
  static String _httpError(int status, String body) {
    final reason = switch (status) {
      401 || 403 => 'credential rejected',
      404 => 'endpoint or model not found',
      429 => 'rate limited',
      >= 500 => 'provider error',
      _ => 'request rejected',
    };
    final detail = _providerMessage(body);
    return detail == null
        ? 'HTTP $status — $reason'
        : 'HTTP $status — $reason · $detail';
  }

  static String? _providerMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final error = json['error'];
        final message = error is Map ? error['message'] : (error ?? json['message']);
        if (message != null) {
          final text = '$message';
          return text.length > 180 ? '${text.substring(0, 180)}…' : text;
        }
      }
    } catch (_) {
      // Not JSON — fall through.
    }
    return null;
  }
}
