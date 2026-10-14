import 'package:double_vision/services/seg_forge_mapping.dart';
import 'package:double_vision/widgets/nodes/implementations/llm/caption_task.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _export() => {
      'schema': 'sf.llm_payload/v1',
      'session_id': 's',
      'page': {'page_b64': 'PAGE', 'page_path': '/x/artifact1.jpg'},
      'panels': [
        {'panel_id': 'p1', 'bbox': [0, 0, 1, 1], 'panel_crop': 'PANEL'},
      ],
      'segments': [
        {
          'mask_id': 'm1', 'caption': 'a boy', 'pass': 1, 'bbox': [0, 0, 1, 1],
          'panel_id': 'p1', 'segment_crop': 'SEG', 'pre_wb': false,
        },
        {
          'mask_id': 'm2', 'caption': '', 'pass': 1, 'bbox': [0, 0, 1, 1],
          'panel_id': null, 'segment_crop': 'SEG2', 'pre_wb': false,
        },
      ],
    };

void main() {
  test('the Seg Forge export becomes an AA the caption task recognises', () {
    final aa = SegForgeMapping.llmPayload(_export());
    expect(const CaptionTask().accepts(aa), isTrue);
    expect(aa.rows.length, aa.cols.length);
    expect(aa.rows.length, aa.vals.length);
  });

  test('rows are page, panel:<id>, seg:<mask_id>; no (row,col) repeats', () {
    final aa = SegForgeMapping.llmPayload(_export());
    final rows = CaptionTask.rowsOf(aa);
    expect(rows.keys, ['page', 'panel:p1', 'seg:m1', 'seg:m2']);
    final pairs = {for (var i = 0; i < aa.rows.length; i++) '${aa.rows[i]}|${aa.cols[i]}'};
    expect(pairs.length, aa.rows.length);
  });

  test('empty values are omitted, not emitted blank', () {
    final rows = CaptionTask.rowsOf(SegForgeMapping.llmPayload(_export()));
    expect(rows['seg:m2']!.containsKey('caption'), isFalse);
    expect(rows['seg:m2']!.containsKey('panel_id'), isFalse);
    expect(rows['seg:m1']!['pass'], '1');
  });

  test('end to end: the mapped payload yields one job for the captioned segment', () {
    final jobs = CaptionTask.buildJobs(
      SegForgeMapping.llmPayload(_export()),
      segmentPrompt: 'Improve: {{caption}}',
    );
    expect(jobs.map((j) => j.key), ['seg:m1']);
    expect(jobs.single.images.map((i) => i.base64Data), ['PAGE', 'PANEL', 'SEG']);
  });

  test('segment rows carry the training file name and the page label', () {
    final export = {
      ..._export(),
      'session_id': 'abc',
      'session_name': 'Page 000',
      'original_filename': 'image.png',
    }..['segments'] = [
        {
          'mask_id': '2:u-1', 'caption': 'a boy', 'pass': 2, 'bbox': [0, 0, 1, 1],
          'panel_id': 'p1', 'segment_crop': 'SEG', 'pre_wb': false,
        },
      ];
    final rows = CaptionTask.rowsOf(SegForgeMapping.llmPayload(export));
    expect(rows['seg:2:u-1']!['file_name'], 'images/abc_2_u-1.png');
    expect(rows['seg:2:u-1']!['page_name'], 'Page 000');
    expect(rows['page']!.containsKey('file_name'), isFalse);
  });

  test('the page label is the session name, else the image name', () {
    expect(SegForgeMapping.pageLabel(' Page 001 ', 'x.png'), 'Page 001');
    expect(SegForgeMapping.pageLabel('', 'scans/nemo_1905.jpg'), 'nemo_1905');
    expect(SegForgeMapping.pageLabel('', ''), '');
  });
}
