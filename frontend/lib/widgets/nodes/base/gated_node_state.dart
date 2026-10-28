import 'package:flutter/material.dart';

import 'base_node_widget.dart';
import 'execute_button.dart';
import 'wait_checkbox.dart';
import 'wait_gated_execution.dart';

/// Base for every node that fires via [WaitGatedExecution] — reactive-or-
/// gated execution with a Wait checkbox, per `UX_UI/GLOBAL_UX_CONTRACT.md`
/// §3 ("every node ... has the identical Wait checkbox + Execute button +
/// status row").
///
/// Mixing [WaitGatedExecution] directly into a `BaseNodeState` only
/// supplies the firing *logic* (`wait`, `onWaitChanged`, `maybeAutoFire`) —
/// nothing about it renders the checkbox, because the mixin is pure
/// behavior and [WaitCheckbox] is a separate, ordinary widget that has to
/// be placed in `buildNodeBody` by hand, the same way [ExecuteButton] and
/// [BaseNodeState.statusRow] are. That split let the checkbox go missing
/// three different ways in this codebase (Collect Antelora, Generate,
/// Caption all had the mixin but never built the widget) while two other
/// nodes (the VLM and Image LoRA trainers) had it mixed in but briefly
/// missing too before being patched by hand.
///
/// Extending [GatedNodeState] instead of writing
/// `extends BaseNodeState<T> with WaitGatedExecution<T>` yourself gets you
/// the same logic plus [buildWaitAndExecute] — the Wait checkbox and the
/// Execute/Cancel button as one unit, in the order and spacing the
/// contract requires. Splice it into your `buildNodeBody`'s children with
/// `...buildWaitAndExecute(busy: busy)` instead of constructing
/// [WaitCheckbox] and [ExecuteButton] separately, so the pair can't be
/// split apart by a future edit either.
abstract class GatedNodeState<T extends BaseNodeWidget>
    extends BaseNodeState<T> with WaitGatedExecution<T> {
  /// The Wait checkbox followed by the Execute/Cancel button, per the
  /// contract's standard spacing (10px above the checkbox, 6px between the
  /// two controls).
  ///
  /// [busy] is this node's own `status == NodeStatus.working` — pass it
  /// through rather than recomputing it, since most bodies need it for
  /// other widgets too. [onCancel] is the hard-abort handler invoked when
  /// the button is pressed mid-run; omit it only for a node with nothing
  /// cancellable in flight (the button is then simply disabled while
  /// busy).
  List<Widget> buildWaitAndExecute({
    required bool busy,
    VoidCallback? onCancel,
  }) =>
      [
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? onCancel : onExecutePressed,
        ),
      ];
}
