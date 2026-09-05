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

  // Fixed literal colors matching `UX_UI/_template.py`'s
  // BUTTON_DISABLED_COL / BUTTON_NORMAL_COL / BUTTON_LIT_COL /
  // BUTTON_CANCEL_COL / TEXT_COL / TEXT_DIM_COL — not theme-derived,
  // identical across every node.
  static const _disabledFill = Color.fromRGBO(33, 33, 38, 1);
  static const _normalFill = Color.fromRGBO(51, 48, 69, 1);
  static const _litFill = Color.fromRGBO(148, 87, 250, 1);
  static const _cancelFill = Color.fromRGBO(242, 140, 51, 1);
  static const _textBright = Color.fromRGBO(224, 222, 235, 1);
  static const _textDim = Color.fromRGBO(140, 138, 153, 1);

  @override
  Widget build(BuildContext context) {
    if (widget.executing) {
      // Cancel is deliberately not the arrowhead's tap-flash treatment —
      // there is no "lit" sub-state for Cancel, just tappable.
      return _shell(
        fill: _cancelFill,
        textColor: _textBright,
        label: 'Cancel',
        icon: Icons.stop_rounded,
        onTap: widget.onPressed,
      );
    }

    final lit = widget.enabled && _pressed;
    final fill =
        !widget.enabled ? _disabledFill : (lit ? _litFill : _normalFill);
    final textColor = widget.enabled ? _textBright : _textDim;
    return _shell(
      fill: fill,
      textColor: textColor,
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
        borderRadius: BorderRadius.circular(8),
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
