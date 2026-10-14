import 'package:aa_preview_table/aa_preview_table.dart';

import 'llm_task.dart';

/// Documents code: takes the AST index from Function Extraction and adds a
/// `better_docstring` per definition.
///
/// Behaviour is exactly what LLM Documenter did before the node became
/// task-based — same endpoints, same bodies, same errors. The prompt and the
/// D4M merge stay the backend's (`/llm/build-prompts`, `/llm/merge-docstrings`);
/// only the model call itself runs client-side, because the vault-redeemed key
/// must never reach the backend.
class CodeDocTask extends LLMTask {
  const CodeDocTask();

  static const localModelId = 'mlx-community/Phi-4-mini-instruct-4bit';

  @override
  String get id => 'code_doc';

  @override
  String get label => 'code documentation';

  @override
  String get doneNoun => 'documented';

  @override
  bool get supportsLocal => true;

  /// The index has one row per definition and, among its columns, the two the
  /// backend's prompt builder reads: `raw_code` and `symbol_name`.
  @override
  bool accepts(AaPayload aa) =>
      aa.cols.contains('raw_code') && aa.cols.contains('symbol_name');

  Map<String, dynamic> _index(AaPayload p) =>
      {'rows': p.rows, 'cols': p.cols, 'vals': p.vals};

  AaPayload _enriched(Map<String, dynamic> result) => AaPayload(
        rows: List<String>.from(result['enrichedIndex']['rows'] ?? []),
        cols: List<String>.from(result['enrichedIndex']['cols'] ?? []),
        vals: List.from(result['enrichedIndex']['vals'] ?? []),
      );

  @override
  Future<LLMResult?> runLocal(LLMRunContext ctx, AaPayload aa) async {
    // Unparseable text falls back to the field's own default rather than
    // blocking the run — same convention as Polyglot Exec's Timeout field.
    final result = await ctx.postJson('/llm/enrich-ast', {
      'astIndex': _index(aa),
      'modelId': localModelId,
      'maxTokens': ctx.maxTokens ?? 256,
      'temperature': ctx.temperature ?? 0.7,
      'promptHint': ctx.promptHint ?? '',
    });
    if (result == null) return null;
    return LLMResult(
      aa: _enriched(result),
      rowsProcessed: (result['rowsProcessed'] ?? 0) as int,
    );
  }

  @override
  Future<LLMResult?> runRemote(LLMRunContext ctx, AaPayload aa) async {
    final key = await ctx.apiKey();
    if (ctx.isCancelled()) return null;

    final built = await ctx.postJson('/llm/build-prompts', {
      'astIndex': _index(aa),
      'promptHint': ctx.promptHint ?? '',
    });
    if (built == null) return null;

    final prompts =
        List<Map<String, dynamic>>.from((built['prompts'] as List?) ?? []);
    if (prompts.isEmpty) {
      throw const LLMTaskError('No documentable definitions in this index');
    }

    final run = await ctx.runJobs([
      for (final entry in prompts)
        LLMJob(
          key: entry['rowKey'] as String,
          prompt: entry['prompt'] as String,
        ),
    ], key);
    if (run == null) return null;

    if (run.replies.isEmpty) {
      throw LLMTaskError(
        'All ${run.failed} remote call(s) failed — nothing to merge',
      );
    }

    final merged = await ctx.postJson('/llm/merge-docstrings', {
      'astIndex': _index(aa),
      'docstrings': run.replies,
    });
    if (merged == null) return null;

    return LLMResult(
      aa: _enriched(merged),
      rowsProcessed: run.replies.length,
      failed: run.failed,
    );
  }
}
