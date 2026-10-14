import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/widgets/nodes/implementations/llm/caption_task.dart';
import 'package:double_vision/widgets/nodes/implementations/llm/code_doc_task.dart';
import 'package:double_vision/widgets/nodes/implementations/llm/llm_task.dart';
import 'package:flutter_test/flutter_test.dart';

AaPayload _aa(Map<String, Map<String, String>> rows) {
  final r = <String>[], c = <String>[], v = <Object>[];
  rows.forEach((row, cells) {
    cells.forEach((col, val) {
      r.add(row);
      c.add(col);
      v.add(val);
    });
  });
  return AaPayload(rows: r, cols: c, vals: v);
}

const _schema = {'schema': CaptionTask.schemaId};

AaPayload _export({String segCaption = 'a boy', String panelCaption = ''}) => _aa({
      'page': {..._schema, 'kind': 'page', 'image_mime': 'image/jpeg', 'image_b64': 'PAGE'},
      'panel:p1': {
        ..._schema, 'kind': 'panel', 'caption': panelCaption,
        'image_mime': 'image/jpeg', 'image_b64': 'PANEL',
      },
      'seg:m1': {
        ..._schema, 'kind': 'segment', 'caption': segCaption, 'pass': '1',
        'panel_id': 'p1', 'image_mime': 'image/png', 'image_b64': 'SEG',
      },
    });

void main() {
  group('CaptionTask.accepts', () {
    const t = CaptionTask();
    test('recognises the Seg Forge export by its schema marker', () {
      expect(t.accepts(_export()), isTrue);
    });
    test('does not take a code index', () {
      final code = _aa({'f': {'symbol_name': 'x', 'raw_code': 'y'}});
      expect(t.accepts(code), isFalse);
      expect(const CodeDocTask().accepts(code), isTrue);
    });
    test('the code task does not take the export', () {
      expect(const CodeDocTask().accepts(_export()), isFalse);
    });
    test('a different schema version is not accepted', () {
      expect(
        t.accepts(_aa({'page': {'schema': 'sf.llm_payload/v2'}})),
        isFalse,
      );
    });
  });

  group('CaptionTask.buildJobs', () {
    test('a segment sends page, panel, segment in that order', () {
      final jobs = CaptionTask.buildJobs(_export(), segmentPrompt: 'Improve: {{caption}}');
      expect(jobs, hasLength(1));
      expect(jobs.single.key, 'seg:m1');
      expect(jobs.single.images.map((i) => i.base64Data), ['PAGE', 'PANEL', 'SEG']);
      expect(jobs.single.prompt, contains('Improve: a boy'));
      expect(jobs.single.prompt, contains('Artifact 2'));
    });

    test('a template without {{caption}} still carries the caption', () {
      final jobs = CaptionTask.buildJobs(_export(), segmentPrompt: 'Be precise.');
      expect(jobs.single.prompt, contains('My caption:\na boy'));
    });

    test('an empty caption is skipped, never invented', () {
      final jobs = CaptionTask.buildJobs(_export(segCaption: '  '), segmentPrompt: 'x');
      expect(jobs, isEmpty);
    });

    test('a missing segment prompt is an error, not a guess', () {
      expect(
        () => CaptionTask.buildJobs(_export()),
        throwsA(isA<LLMTaskError>()),
      );
    });

    test('a captioned panel needs the panel prompt and uses page + panel', () {
      expect(
        () => CaptionTask.buildJobs(_export(panelCaption: 'a bed'), segmentPrompt: 'x'),
        throwsA(isA<LLMTaskError>()),
      );
      final jobs = CaptionTask.buildJobs(
        _export(panelCaption: 'a bed'),
        segmentPrompt: 'x',
        panelPrompt: 'Panel: {{caption}}',
      );
      final panel = jobs.firstWhere((j) => j.key == 'panel:p1');
      expect(panel.images.map((i) => i.base64Data), ['PAGE', 'PANEL']);
    });

    test('a segment outside any panel sends page + segment and says so', () {
      final aa = _aa({
        'page': {..._schema, 'kind': 'page', 'image_b64': 'PAGE'},
        'seg:m2': {
          ..._schema, 'kind': 'segment', 'caption': 'a cat', 'image_b64': 'SEG',
        },
      });
      final jobs = CaptionTask.buildJobs(aa, segmentPrompt: 'x');
      expect(jobs.single.images.map((i) => i.base64Data), ['PAGE', 'SEG']);
      expect(jobs.single.prompt, contains('no Artifact 2'));
    });
  });
}
