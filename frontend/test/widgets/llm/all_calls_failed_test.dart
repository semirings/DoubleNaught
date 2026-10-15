import 'package:double_vision/widgets/nodes/implementations/llm/llm_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the failure message carries the first reason, on one line', () {
    expect(
      allCallsFailed(3, 'HTTP 429\n  quota   exceeded'),
      'All 3 remote call(s) failed: HTTP 429 quota exceeded',
    );
  });

  test('no reason leaves the plain message; a long one is trimmed', () {
    expect(allCallsFailed(3, null), 'All 3 remote call(s) failed');
    expect(allCallsFailed(3, 'x' * 500).length, lessThan(300));
    expect(
      allCallsFailed(2, 'boom', suffix: ' — nothing to merge'),
      'All 2 remote call(s) failed: boom — nothing to merge',
    );
  });
}
