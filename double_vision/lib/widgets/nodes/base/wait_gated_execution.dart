import 'base_node_widget.dart';

/// Shared reactive/gated (Wait checkbox) firing mechanism — see
/// `UX_UI/GLOBAL_UX_CONTRACT.md` §3. A [BaseNodeState] subclass with a Wait
/// checkbox mixes this in, implements [isReady] and [fire], calls
/// [maybeAutoFire] whenever something that could affect [isReady] changes,
/// and wires its [WaitCheckbox] to [wait] / [onWaitChanged] and its
/// `ExecuteButton` to `isReady && status != NodeStatus.working` /
/// [onExecutePressed].
///
/// This mixin owns *when* a node fires, exactly as [BaseNodeState] owns *how*
/// its status is rendered — neither owns *what* firing does, which stays
/// with the node's own [fire] override.
mixin WaitGatedExecution<T extends BaseNodeWidget> on BaseNodeState<T> {
  bool _wait = false;

  /// Unchecked (false, the default) = reactive: [fire] runs automatically
  /// the instant [isReady] becomes true. Checked = gated: only
  /// [onExecutePressed] or a manual uncheck-while-ready triggers it.
  bool get wait => _wait;

  /// Whether this node's required inputs are currently satisfied — node-
  /// specific (e.g. D4M: script non-empty and every declared port has data).
  bool get isReady;

  /// Actually run the node. Called by [onExecutePressed], by
  /// [maybeAutoFire], and by [onWaitChanged] on an uncheck that finds
  /// [isReady] already true.
  void fire();

  /// Call whenever a change could affect [isReady] (new port data, an edit
  /// to a required field, a port added/removed). Fires only on the
  /// unchecked-and-newly-ready condition; safe to call unconditionally, and
  /// a no-op while already executing.
  void maybeAutoFire() {
    if (!_wait && isReady && status != NodeStatus.working) {
      fire();
    }
  }

  /// The Execute button's `onPressed`. Fires immediately and, per the
  /// contract, unchecks Wait as a side effect.
  void onExecutePressed() {
    if (!isReady || status == NodeStatus.working) return;
    if (_wait) {
      setState(() => _wait = false);
    }
    fire();
  }

  /// The Wait checkbox's `onChanged`. Locked (ignored) mid-execution — the
  /// checkbox itself should also be built with `locked: status ==
  /// NodeStatus.working` so it renders unresponsive, not just behaves that
  /// way.
  void onWaitChanged(bool checked) {
    if (status == NodeStatus.working) return;
    setState(() => _wait = checked);
    if (!checked && isReady) fire();
  }
}
