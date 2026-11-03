import 'dart:convert';

import 'package:aa_preview_table/aa_preview_table.dart';

import '../../../../services/remote/remote_request.dart';
import 'llm_task.dart';

/// Improves the user's own captions on a Seg Forge export, then checks the
/// result against the prompt-governance ontology (Ontology Guardrail) and
/// corrects anything it flags.
///
/// The user writes a caption per segment in SF; this task sends that caption
/// back to a vision model together with the pictures it describes, and asks
/// for a better one. It never invents a caption where the user wrote none.
///
/// ## The data contract (`sf.llm_payload/v1`)
///
/// A sparse AA (parallel `rows`/`cols`/`vals`). Every row carries
/// `schema = sf.llm_payload/v1`, which is the *only* thing [accepts] looks at,
/// so no other data can be mistaken for a Seg Forge export.
///
/// | row            | `kind`    | columns besides `schema`/`kind`                          |
/// |----------------|-----------|----------------------------------------------------------|
/// | `page`         | `page`    | `image_mime`, `image_b64` — Artifact 1, balloon-scrubbed |
/// | `panel:<id>`   | `panel`   | `caption`, `image_mime`, `image_b64` — Artifact 2        |
/// | `seg:<mask_id>`| `segment` | `caption`, `pass`, `panel_id`, `text_tag`, `image_*` — Artifact 3 |
///
/// The original page is never part of the payload.
///
/// ## Three rounds, three output columns
///
/// 1. **Improve** — the vision model rewrites the user's caption.
/// 2. **Extract** — a text-only pass reads the improved caption back and
///    reports which ontology class it belongs to (`Character`/`Creature`/
///    `Prop`/`Setting`) and whether it names its subject. This is the model
///    self-reporting the structure of its own output, which is never perfect
///    — a caption whose extraction doesn't parse just skips the guardrail
///    rather than getting a guessed verdict.
/// 3. **Validate + correct** — recognized rows go to the backend's
///    `/ontology/validate` (OntologyAnvil.jl) in one batched call; rows it
///    flags get one more model call with the violation text, asking for a
///    fix. Rows that pass (or weren't checkable) carry their better caption
///    straight through.
///
/// ## Output
///
/// One row per improved caption, images dropped (they are large and the
/// consumer already has them): `good_caption` (the user's original),
/// `better_caption` (the model's rewrite), `best_caption` (guardrail-checked
/// and, if needed, corrected), plus `kind`, `panel_id`, `pass`.
class CaptionTask extends LLMTask {
  static const int _minReplyTokens = 2048;
  const CaptionTask();
  static const schemaId = 'sf.llm_payload/v1';

  @override
  String get id => 'caption';
  @override
  String get label => 'caption improvement';
  @override
  String get doneNoun => 'captions improved';
  @override
  bool get supportsLocal => false;

  @override
  bool accepts(AaPayload aa) {
    for (var i = 0; i < aa.cols.length && i < aa.vals.length; i++) {
      if (aa.cols[i] == 'schema' && '${aa.vals[i]}' == schemaId) return true;
    }
    return false;
  }

  static Map<String, Map<String, String>> rowsOf(AaPayload aa) {
    final out = <String, Map<String, String>>{};
    for (var i = 0; i < aa.rows.length && i < aa.cols.length && i < aa.vals.length; i++) {
      (out[aa.rows[i]] ??= <String, String>{})[aa.cols[i]] = '${aa.vals[i]}';
    }
    return out;
  }

  static RemoteImage? _imageOf(Map<String, String>? row) {
    final data = row?['image_b64'];
    if (data == null || data.isEmpty) return null;
    return RemoteImage(
      mimeType: row!['image_mime'] ?? 'image/png',
      base64Data: data,
    );
  }

  static String fill(String template, {required String caption, String? textTag}) {
    var out = template.replaceAll('{{text_tag}}', textTag ?? '');
    if (out.contains('{{caption}}')) {
      return out.replaceAll('{{caption}}', caption);
    }
    return '$out\n\nMy caption:\n$caption';
  }

  static const _footer =
      '\n\nReply with only the improved caption text — no preamble, no '
      'quotes, no markdown.';

  static List<LLMJob> buildJobs(
    AaPayload aa, {
    String? segmentPrompt,
    String? panelPrompt,
  }) {
    final rows = rowsOf(aa);
    final page = _imageOf(rows['page']);
    final jobs = <LLMJob>[];

    final segs = rows.entries.where((e) =>
        e.value['kind'] == 'segment' && (e.value['caption'] ?? '').trim().isNotEmpty);
    final panels = rows.entries.where((e) =>
        e.value['kind'] == 'panel' && (e.value['caption'] ?? '').trim().isNotEmpty);

    if (segs.isNotEmpty && (segmentPrompt ?? '').trim().isEmpty) {
      throw const LLMTaskError('Connect a Prompt node to promptInput — '
          'segment captions need instructions');
    }
    if (panels.isNotEmpty && (panelPrompt ?? '').trim().isEmpty) {
      throw const LLMTaskError('Connect a Prompt node to panelPromptInput — '
          'panel captions need instructions');
    }
    if (page == null && (segs.isNotEmpty || panels.isNotEmpty)) {
      throw const LLMTaskError('The Seg Forge export has no page image');
    }

    for (final e in segs) {
      final panelId = e.value['panel_id'] ?? '';
      final panel = panelId.isEmpty ? null : _imageOf(rows['panel:$panelId']);
      final seg = _imageOf(e.value);
      if (seg == null) continue;
      final preamble = panel == null
          ? 'Attached images, in order: Artifact 1 (the full page), '
              'Artifact 3 (the segmented subject). This segment is not inside '
              'a panel, so there is no Artifact 2.\n\n'
          : 'Attached images, in order: Artifact 1 (the full page), '
              'Artifact 2 (the panel crop), Artifact 3 (the segmented subject).\n\n';
      jobs.add(LLMJob(
        key: e.key,
        prompt: '$preamble'
            '${fill(segmentPrompt!, caption: e.value['caption']!.trim(), textTag: e.value['text_tag'])}'
            '$_footer',
        images: [page!, ?panel, seg],
      ));
    }

    for (final e in panels) {
      final panel = _imageOf(e.value);
      if (panel == null) continue;
      jobs.add(LLMJob(
        key: e.key,
        prompt: 'Attached images, in order: Artifact 1 (the full page), '
            'Artifact 2 (the panel crop).\n\n'
            '${fill(panelPrompt!, caption: e.value['caption']!.trim())}'
            '$_footer',
        images: [page!, panel],
      ));
    }
    return jobs;
  }

  /// Text-only: ask the model what ontology class its own (just-written)
  /// caption describes, and whether it names its subject. Self-reported, so
  /// a row whose reply doesn't parse as the expected JSON just skips the
  /// guardrail rather than getting a verdict based on a guess.
  static String _extractPrompt(String betterCaption) => '''
Read this image caption and answer with JSON only, nothing else — no preamble, no markdown fences.

Caption:
"""$betterCaption"""

Respond with exactly this shape:
{"class": "Character" | "Creature" | "Prop" | "Setting" | null, "has_entity_name": true | false}

- "class": the single category the caption's main subject belongs to. Use null if it doesn't clearly fit one of the four.
- "has_entity_name": true only if the caption gives that subject a specific name or other distinguishing identifier — not just "a man" or "the creature".
''';

  static String _correctPrompt(String betterCaption, List<String> violations) => '''
This image caption failed an ontology check:

Caption:
"""$betterCaption"""

Problems found:
${violations.map((v) => '- $v').join('\n')}

Rewrite the caption to fix these problems while keeping everything else about it the same. Reply with only the corrected caption text — no preamble, no quotes, no markdown.
''';

  static Map<String, dynamic>? _parseJson(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      final nl = t.indexOf('\n');
      if (nl != -1) t = t.substring(nl + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
      t = t.trim();
    }
    try {
      final decoded = jsonDecode(t);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static const _validClasses = {'Character', 'Creature', 'Prop', 'Setting'};

  static ({String? klass, bool hasEntityName})? _factsFrom(String reply) {
    final j = _parseJson(reply);
    if (j == null) return null;
    final klass = j['class'];
    final hasName = j['has_entity_name'] == true;
    if (klass is String && _validClasses.contains(klass)) {
      return (klass: klass, hasEntityName: hasName);
    }
    return (klass: null, hasEntityName: hasName);
  }

  static Map<String, dynamic> _validateBody(
    Map<String, ({String klass, bool hasEntityName})> checkable,
  ) {
    final r = <String>[];
    final c = <String>[];
    final v = <Object>[];
    for (final e in checkable.entries) {
      r.add(e.key);
      c.add('class|${e.value.klass}');
      v.add(true);
      if (e.value.hasEntityName) {
        r.add(e.key);
        c.add('slot|entity_name');
        v.add(true);
      }
    }
    return {
      'aa': {'rows': r, 'cols': c, 'vals': v},
    };
  }

  static Map<String, ({bool valid, List<String> violations})> _parseVerdicts(
    Map<String, dynamic> reply,
  ) {
    final out = <String, ({bool valid, List<String> violations})>{};
    final aa = reply['aa'];
    if (aa is! Map) return out;
    final rows = List<String>.from(aa['rows'] ?? const []);
    final cols = List<String>.from(aa['cols'] ?? const []);
    final vals = List.from(aa['vals'] ?? const []);
    final byRow = <String, Map<String, String>>{};
    for (var i = 0; i < rows.length && i < cols.length && i < vals.length; i++) {
      (byRow[rows[i]] ??= <String, String>{})[cols[i]] = '${vals[i]}';
    }
    for (final e in byRow.entries) {
      final violations = (e.value['violations'] ?? '')
          .split(' | ')
          .where((s) => s.isNotEmpty)
          .toList();
      out[e.key] = (valid: e.value['valid'] == 'true', violations: violations);
    }
    return out;
  }

  @override
  Future<LLMResult?> runLocal(LLMRunContext ctx, AaPayload aa) =>
      throw const LLMTaskError(
          'Caption improvement needs a remote vision model — choose a remote Model');

  @override
  Future<LLMResult?> runRemote(LLMRunContext ctx, AaPayload aa) async {
    final jobs = buildJobs(
      aa,
      segmentPrompt: ctx.promptHint,
      panelPrompt: ctx.panelPromptHint,
    );
    if (jobs.isEmpty) {
      throw const LLMTaskError('No captions to improve — write captions in Seg Forge first');
    }

    final key = await ctx.apiKey();
    if (ctx.isCancelled()) return null;

    // Round 1: improve.
    final improveRun = await ctx.runJobs(jobs, key, minTokens: _minReplyTokens);
    if (improveRun == null) return null;
    if (improveRun.replies.isEmpty) {
      throw LLMTaskError(allCallsFailed(improveRun.failed, improveRun.firstError));
    }
    final betterCaptions = improveRun.replies;

    // Round 2: extract class + entity_name presence from each better caption.
    final extractJobs = [
      for (final e in betterCaptions.entries)
        LLMJob(key: e.key, prompt: _extractPrompt(e.value)),
    ];
    final extractRun = await ctx.runJobs(extractJobs, key, minTokens: 128);
    if (extractRun == null) return null;

    final facts = <String, ({String? klass, bool hasEntityName})>{};
    for (final e in extractRun.replies.entries) {
      final parsed = _factsFrom(e.value);
      if (parsed != null) facts[e.key] = parsed;
    }

    // Round 3: validate every row whose extraction yielded a recognized class.
    final checkable = <String, ({String klass, bool hasEntityName})>{
      for (final e in facts.entries)
        if (e.value.klass != null) e.key: (klass: e.value.klass!, hasEntityName: e.value.hasEntityName),
    };
    var verdicts = <String, ({bool valid, List<String> violations})>{};
    if (checkable.isNotEmpty) {
      final reply = await ctx.postJson('/ontology/validate', _validateBody(checkable));
      if (ctx.isCancelled()) return null;
      if (reply != null) verdicts = _parseVerdicts(reply);
    }

    // Round 4: correct only the rows the guardrail actually flagged.
    final toCorrect = verdicts.entries.where((e) => !e.value.valid).toList();
    final correctJobs = [
      for (final e in toCorrect)
        LLMJob(
          key: e.key,
          prompt: _correctPrompt(betterCaptions[e.key] ?? '', e.value.violations),
        ),
    ];
    var corrected = <String, String>{};
    if (correctJobs.isNotEmpty) {
      final correctRun = await ctx.runJobs(correctJobs, key, minTokens: _minReplyTokens);
      if (correctRun == null) return null;
      corrected = correctRun.replies;
    }

    final bestCaptions = <String, String>{
      for (final k in betterCaptions.keys) k: corrected[k] ?? betterCaptions[k]!,
    };

    return LLMResult(
      aa: _output(aa, betterCaptions, bestCaptions),
      rowsProcessed: betterCaptions.length,
      failed: improveRun.failed,
    );
  }

  static AaPayload _output(
    AaPayload aa,
    Map<String, String> betterCaptions,
    Map<String, String> bestCaptions,
  ) {
    final rows = rowsOf(aa);
    final r = <String>[];
    final c = <String>[];
    final v = <Object>[];
    void put(String row, String col, String val) {
      r.add(row);
      c.add(col);
      v.add(val);
    }

    for (final e in betterCaptions.entries) {
      final src = rows[e.key] ?? const <String, String>{};
      put(e.key, 'better_caption', e.value.trim());
      put(e.key, 'best_caption', (bestCaptions[e.key] ?? e.value).trim());
      final original = src['caption'];
      if (original != null && original.isNotEmpty) {
        put(e.key, 'good_caption', original);
      }
      for (final col in const ['kind', 'panel_id', 'pass']) {
        final val = src[col];
        if (val != null && val.isNotEmpty) put(e.key, col, val);
      }
      if ((src['file_name'] ?? '').isNotEmpty) {
        for (final col in const ['file_name', 'page_name', 'image_b64']) {
          final val = src[col];
          if (val != null && val.isNotEmpty) put(e.key, col, val);
        }
      }
    }
    return AaPayload(rows: r, cols: c, vals: v);
  }
}
