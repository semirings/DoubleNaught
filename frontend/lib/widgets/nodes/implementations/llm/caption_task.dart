import 'package:aa_preview_table/aa_preview_table.dart';

import '../../../../services/remote/remote_request.dart';
import 'llm_task.dart';

/// Improves the user's own captions on a Seg Forge export.
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
/// ## Output
///
/// One row per improved caption, images dropped (they are large and the
/// consumer already has them): `improved_caption`, plus `caption` (the user's
/// original, so the two can be compared), `kind`, `panel_id`, `pass`.
class CaptionTask extends LLMTask {
  /// Floor for the reply cap. The node's Max Tokens defaults to 256, which a
  /// reasoning model (e.g. gemini-pro) can spend entirely on thinking, leaving
  /// captions cut off mid-phrase ("…plumed helmet,").
  static const int _minReplyTokens = 2048;

  const CaptionTask();

  static const schemaId = 'sf.llm_payload/v1';

  @override
  String get id => 'caption';

  @override
  String get label => 'caption improvement';

  @override
  String get doneNoun => 'captions improved';

  /// Captioning needs a vision model; the backend's local text model cannot.
  @override
  bool get supportsLocal => false;

  @override
  bool accepts(AaPayload aa) {
    for (var i = 0; i < aa.cols.length && i < aa.vals.length; i++) {
      if (aa.cols[i] == 'schema' && '${aa.vals[i]}' == schemaId) return true;
    }
    return false;
  }

  /// Sparse triples → `row → {col → value}`, in first-seen row order.
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

  /// Fills `{{caption}}` and `{{text_tag}}`; when the template has no
  /// `{{caption}}`, the caption is appended so it is never silently dropped.
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

  /// Builds one job per captioned segment (using [segmentPrompt]) and per
  /// captioned panel (using [panelPrompt]). Rows with an empty caption are
  /// skipped: there is nothing of the user's to improve.
  ///
  /// Throws [LLMTaskError] when a prompt is needed but missing — never falls
  /// back to a guess.
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

    final run = await ctx.runJobs(jobs, key, minTokens: _minReplyTokens);
    if (run == null) return null;
    if (run.replies.isEmpty) {
      throw LLMTaskError(allCallsFailed(run.failed, run.firstError));
    }
    return LLMResult(
      aa: _output(aa, run.replies),
      rowsProcessed: run.replies.length,
      failed: run.failed,
    );
  }

  static AaPayload _output(AaPayload aa, Map<String, String> replies) {
    final rows = rowsOf(aa);
    final r = <String>[];
    final c = <String>[];
    final v = <Object>[];
    void put(String row, String col, String val) {
      r.add(row);
      c.add(col);
      v.add(val);
    }

    for (final e in replies.entries) {
      final src = rows[e.key] ?? const <String, String>{};
      put(e.key, 'improved_caption', e.value.trim());
      for (final col in const ['caption', 'kind', 'panel_id', 'pass']) {
        final val = src[col];
        if (val != null && val.isNotEmpty) put(e.key, col, val);
      }
      // Only rows that become training images carry their file name, page and
      // pixels on — Save Antelora writes them; panels and the page never ship.
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
