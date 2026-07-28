import 'dart:convert';
import 'dart:typed_data';

import 'package:double_vision/services/category_store.dart';
import 'package:double_vision/widgets/nodes/implementations/file_source_node.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

// The dense shape of storage/categories/categories.json.
const _denseCategoriesJson = '''
{
  "rows": ["cat:rhetorical", "cat:periodic", "cat:primitive"],
  "cols": ["label", "hypothesis_template", "threshold"],
  "vals": [
    "grandiloquent rhetorical speech", "This passage is {}", 0.75,
    "balanced periodic sentence",     "This passage is {}", 0.80,
    "direct primitive narrative",     "This passage is {}", 0.60
  ]
}
''';

void main() {
  test('detectAa parses a dense rcvs JSON file into a sparse AA', () {
    final aa = FileSourceNode.detectAa(
      _bytes(_denseCategoriesJson),
      'categories.json',
    );
    expect(aa, isNotNull);
    // Expanded to canonical sparse triples (3 categories × 3 columns).
    expect(aa!.rows.length, 9);
    expect(CategoryStore.labelsOf(aa), [
      'grandiloquent rhetorical speech',
      'balanced periodic sentence',
      'direct primitive narrative',
    ]);
  });

  test('detectAa parses a sparse rcvs JSON file', () {
    const sparse =
        '{"rows":["r"],"cols":["label"],"vals":["only category"]}';
    final aa = FileSourceNode.detectAa(_bytes(sparse), 'x.json');
    expect(aa, isNotNull);
    expect(CategoryStore.labelsOf(aa!), ['only category']);
  });

  test('detectAa ignores non-.json files even if the bytes are AA JSON', () {
    expect(
      FileSourceNode.detectAa(_bytes(_denseCategoriesJson), 'categories.txt'),
      isNull,
    );
    expect(FileSourceNode.detectAa(_bytes(_denseCategoriesJson), null), isNull);
  });

  test('detectAa returns null for JSON that is not an AA', () {
    expect(
      FileSourceNode.detectAa(_bytes('{"hello":"world"}'), 'x.json'),
      isNull,
    );
  });

  test('detectAa returns null for malformed JSON', () {
    expect(FileSourceNode.detectAa(_bytes('not json {'), 'x.json'), isNull);
  });
}
