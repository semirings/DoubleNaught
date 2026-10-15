import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:http/http.dart' as http;

import '../../../../models/auth_profile.dart';
import '../../../../services/remote/remote_request.dart';

/// A task the LLM node can perform on an incoming AA.
///
/// The node owns everything that is the same whatever the task — credential
/// matching, the model picker, Max Tokens / Temperature, Wait/Execute gating,
/// cancellation, status and the output port. A task owns only what differs:
/// recognising its data, building the per-row jobs, and merging the replies.
///
/// This is composition rather than a node subclass on purpose: one node whose
/// behaviour is chosen by the data it is handed (the user plugs data in and
/// decides nothing), so there is exactly one set of plumbing to keep correct.
abstract class LLMTask {
  const LLMTask();

  /// Stable id, shown on the node and used in error messages.
  String get id;

  /// Human label, e.g. "code documentation".
  String get label;

  /// Whether [aa] is this task's data. A recogniser must be exact — it is the
  /// only thing standing between a payload and the wrong behaviour.
  bool accepts(AaPayload aa);

  /// Whether a local (no-credential) model can do this task at all.
  bool get supportsLocal;

  /// Noun for the finished status line: "3 documented".
  String get doneNoun;

  /// Runs on the backend's own local model. Null means the run was cancelled.
  Future<LLMResult?> runLocal(LLMRunContext ctx, AaPayload aa);

  /// Runs against a remote provider. Null means the run was cancelled.
  Future<LLMResult?> runRemote(LLMRunContext ctx, AaPayload aa);
}

/// One prompt for one row, keyed so the reply can be merged back.
class LLMJob {
  final String key;
  final String prompt;

  /// Images sent with the prompt; empty for text-only tasks.
  final List<RemoteImage> images;
  const LLMJob({
    required this.key,
    required this.prompt,
    this.images = const [],
  });
}

class LLMResult {
  final AaPayload aa;
  final int rowsProcessed;
  final int failed;
  const LLMResult({
    required this.aa,
    required this.rowsProcessed,
    this.failed = 0,
  });
}

/// A failure a task wants shown verbatim on the node.
class LLMTaskError implements Exception {
  final String message;
  const LLMTaskError(this.message);

  @override
  String toString() => message;
}

/// What the node hands a task for one run.
class LLMRunContext {
  final http.Client client;
  final Uri Function(String path) endpoint;
  final int? maxTokens;
  final double? temperature;
  final String model;
  final AuthProfile? profile;

  /// Redeems the API key from the vault on demand; the key never leaves the
  /// Dart side.
  final Future<String?> Function() apiKey;

  /// The text from the optional `promptInput`, or null.
  final String? promptHint;

  /// The text from `panelPromptInput`, or null. Only tasks that distinguish
  /// panels from segments read it.
  final String? panelPromptHint;

  /// True once this run was cancelled or superseded. Checked after every await.
  final bool Function() isCancelled;

  /// Called after each job with (finished, total) so the node can show progress.
  final void Function(int done, int total)? onProgress;

  const LLMRunContext({
    required this.client,
    required this.endpoint,
    required this.maxTokens,
    required this.temperature,
    required this.model,
    required this.profile,
    required this.apiKey,
    required this.promptHint,
    this.panelPromptHint,
    required this.isCancelled,
    this.onProgress,
  });

  /// POSTs [body] as JSON to [path] and returns the decoded reply. Null when
  /// the run was cancelled meanwhile; throws [LLMTaskError] on a non-200,
  /// preferring the backend's own `detail` text.
  Future<Map<String, dynamic>?> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = http.Request('POST', endpoint(path))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    final response = await client.send(request);
    final text = await response.stream.bytesToString();
    if (isCancelled()) return null;
    if (response.statusCode != 200) {
      throw LLMTaskError(
        (jsonDecode(text)['detail'] ?? 'HTTP ${response.statusCode}')
            .toString(),
      );
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Sends every job to the remote provider, one at a time. Null when the run
  /// was cancelled. Individual failures are counted, not fatal; the caller
  /// decides what "all failed" means.
  ///
  /// [minTokens] raises the reply cap to at least that many. A reasoning model
  /// spends its output budget on thinking before it writes a word, so a small
  /// cap that suits a short answer can cut the answer itself off mid-phrase.
  Future<({Map<String, String> replies, int failed, String? firstError})?> runJobs(
    List<LLMJob> jobs,
    String? key, {
    int minTokens = 0,
  }) async {
    final cap = (maxTokens ?? 0) >= minTokens && maxTokens != null
        ? maxTokens
        : (minTokens > 0 ? minTokens : maxTokens);
    final remote = RemoteRequest(client: client);
    final replies = <String, String>{};
    var failed = 0;
    String? firstError;
    onProgress?.call(0, jobs.length);
    for (final job in jobs) {
      if (isCancelled()) return null; // cancelled mid-loop
      final result = await remote.send(
        profile: profile!,
        model: model,
        prompt: job.prompt,
        apiKey: key,
        maxTokens: cap,
        temperature: temperature,
        images: job.images,
      );
      if (isCancelled()) return null; // cancelled while awaiting
      if (result.ok && result.text.isNotEmpty) {
        replies[job.key] = result.text;
      } else {
        failed++;
        // Keep the first reason: when every call fails it is the same one, and
        // it is the only thing that says whether to fix a key, a model or a quota.
        firstError ??= result.ok
            ? 'the model returned no text'
            : (result.errorMsg.isEmpty ? result.status : result.errorMsg);
      }
      onProgress?.call(replies.length + failed, jobs.length);
    }
    return (replies: replies, failed: failed, firstError: firstError);
  }
}

/// "All N remote call(s) failed: <reason>" — the reason trimmed to one line.
String allCallsFailed(int count, String? reason, {String suffix = ''}) {
  final why = (reason ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = why.length > 240 ? '${why.substring(0, 237)}...' : why;
  return 'All $count remote call(s) failed${short.isEmpty ? '' : ': $short'}$suffix';
}
