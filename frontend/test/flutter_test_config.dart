import 'dart:async';

import 'package:double_vision/widgets/nodes/base/base_node_widget.dart';

/// Runs before every test file. The node working spinner animates forever,
/// which would stop `pumpAndSettle` from ever settling while a node is busy,
/// so tests render it frozen.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  BaseNodeState.animateWorkingSpinner = false;
  await testMain();
}
