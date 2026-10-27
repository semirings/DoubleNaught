import 'package:flutter/material.dart';

/// The standardized primary-action button for every node that has one — see
/// `UX_UI/GLOBAL_UX_CONTRACT.md` §2. Always labeled "Execute", with the
/// arrowhead icon to the **right** of the label, never the left. This is the
/// single shared implementation so no node hand-rolls its own button (every
/// node previously used a different verb — "Load", "Format", "Enrich with
/// LLM" — which this replaces).
///
/// States: `disabled` (![enabled]), `enabled` (idle, interactive), `lit`
/// (enabled and currently pressed — the "pressed/active" visual feedback from
/// the contract), and `executing` (see [executing]).
///
/// Idle (enabled/disabled/lit) renders as a green outline — the same
/// `0xFF43A047` as the toolbar's "Go" button in `workflow_page.dart`, so a
/// node's own primary action reads as the same color as the global run
/// trigger, just scoped to one node instead of the whole graph. Disabled
/// dims that green toward black (identical recipe to Go's own disabled
/// state) rather than switching to an unrelated gray. [executing] is
/// unchanged — solid orange, labeled "Cancel" — and the button reverts to
/// the green outline the instant [executing] goes false again, no separate
/// handling needed.
class ExecuteButton extends StatefulWidget {
  /// Whether the button accepts taps. Per the contract, this becomes true
  /// the moment the node's required inputs are satisfied (and valid, where a
  /// field has validation) — independent of any Wait checkbox. Ignored while
  /// [executing] is true, which always renders tappable.
  final bool enabled;

  /// True for the full duration of execution. While true, the button
  /// becomes **Cancel** — amber/orange fill, "Cancel" label, the arrowhead
  /// replaced with a stop-square — regardless of [enabled]. [onPressed] is
  /// then interpreted by the caller as "cancel," and per the contract must
  /// immediately abort the in-flight operation (a hard abort, not a
  /// cooperative flag checked later) rather than merely stop watching it.
  /// Defaults to false so existing callers with no cancel path are
  /// unaffected.
  final bool executing;

  /// Invoked on tap. Ignored whenever [enabled] is false and [executing] is
  /// false.
  final VoidCallback? onPressed;

  const ExecuteButton({
    super.key,
    required this.enabled,
    this.executing = false,
    required this.onPressed,
  });

  @override
  State<ExecuteButton> createState() => _ExecuteButtonState();
}

class _ExecuteButtonState extends State<ExecuteButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  // `_runGreen` is literally `_SelectionBar._runColor` in workflow_page.dart
  // (the toolbar's "Go" button) — kept as its own literal here rather than
  // imported, since this is a leaf widget with no dependency on that page,
  // but it must stay equal to it by eye. `_cancelFill` / `_textBright` are
  // unchanged from the original palette (`UX_UI/_template.py`'s
  // BUTTON_CANCEL_COL / TEXT_COL) — the executing/Cancel state was already
  // solid orange and stays that way.
  static const _runGreen = Color(0xFF43A047);
  static const _cancelFill = Color.fromRGBO(242, 140, 51, 1);
  static const _textBright = Color.fromRGBO(224, 222, 235, 1);

  /// Same dimming recipe as `_SelectionBar._outlined()`'s disabled state:
  /// blend toward black rather than switching to a separate gray, so the
  /// border and the label/icon always agree on one muted hue instead of
  /// looking like two different disabled treatments fighting each other.
  Color _dim(Color c) => Color.lerp(c, Colors.black, 0.55)!;

  @override
  Widget build(BuildContext context) {
    if (widget.executing) {
      // Cancel is deliberately not the arrowhead's tap-flash treatment —
      // there is no "lit" sub-state for Cancel, just tappable. Solid fill,
      // no outline — unchanged from before.
      return _shell(
        fill: _cancelFill,
        border: null,
        textColor: _textBright,
        label: 'Cancel',
        icon: Icons.stop_rounded,
        onTap: widget.onPressed,
      );
    }

    final lit = widget.enabled && _pressed;
    final accent = widget.enabled ? _runGreen : _dim(_runGreen);
    // Idle is an outline, not a fill — transparent at rest, a faint tint of
    // the same green while pressed-and-enabled ("lit"), never a solid block.
    final fill = lit ? accent.withValues(alpha: 0.16) : Colors.transparent;
    return _shell(
      fill: fill,
      border: accent,
      textColor: accent,
      label: 'Execute',
      icon: Icons.arrow_forward_rounded,
      onTap: widget.enabled ? widget.onPressed : null,
      onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
    );
  }

  Widget _shell({
    required Color fill,
    required Color? border,
    required Color textColor,
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    GestureTapDownCallback? onTapDown,
    VoidCallback? onTapCancel,
    GestureTapUpCallback? onTapUp,
  }) {
    return SizedBox(
      height: 40,
      width: double.infinity,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: border == null
              ? BorderSide.none
              : BorderSide(color: border, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onTapDown: onTapDown,
          onTapCancel: onTapCancel,
          onTapUp: onTapUp,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(icon, size: 16, color: textColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
