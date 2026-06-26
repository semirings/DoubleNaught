import 'package:flutter/widgets.dart';

import '../models/workflow.dart';

/// Lets an [OutputConnector] report an in-progress connection drag up to the
/// canvas (so it can paint a live preview curve) without threading callbacks
/// through every node widget. Looked up with [ConnectionDragScope.of].
///
/// The actual edge creation is still handled by the existing `DragTarget` on
/// the input port — this scope only drives the visual preview.
class ConnectionDragScope extends InheritedWidget {
  /// A drag began from the output port [source].
  final void Function(PortRef source) onDragStart;

  /// The pointer moved to [globalPointer] during the drag.
  final void Function(Offset globalPointer) onDragUpdate;

  /// The drag ended (dropped or cancelled); clear the preview.
  final void Function() onDragEnd;

  const ConnectionDragScope({
    super.key,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required super.child,
  });

  static ConnectionDragScope? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ConnectionDragScope>();

  @override
  bool updateShouldNotify(ConnectionDragScope oldWidget) => false;
}
