import 'package:flutter/material.dart';

/// The standardized "Wait" checkbox for nodes with reactive/gated execution
/// — see `UX_UI/GLOBAL_UX_CONTRACT.md` §3. Purely presentational plus a
/// callback: the reactive-vs-gated firing decision (auto-fire once ready,
/// fire-immediately-on-uncheck-if-already-ready, locking during execution,
/// etc.) belongs to the owning node's state — see [WaitGatedExecution] —
/// exactly as [ExecuteButton] renders a state without deciding readiness
/// itself.
class WaitCheckbox extends StatelessWidget {
  final bool checked;

  /// Called with the new value when the user taps the box or its label.
  /// Leave null (or set [locked]) to render it unresponsive.
  final ValueChanged<bool>? onChanged;

  /// True while the node is executing — per the contract, Wait cannot be
  /// toggled mid-run regardless of which path triggered execution.
  final bool locked;

  const WaitCheckbox({
    super.key,
    required this.checked,
    required this.onChanged,
    this.locked = false,
  });

  // Fixed literal colors matching `UX_UI/_template.py`'s
  // CONTENT_NORMAL_COL / CONTENT_LIT_COL / OUTLINE_NORMAL_COL / TEXT_COL /
  // TEXT_DIM_COL — not theme-derived, identical across every node.
  static const _uncheckedFill = Color.fromRGBO(43, 41, 54, 1);
  static const _checkedFill = Color.fromRGBO(148, 87, 250, 1);
  static const _disabledFill = Color.fromRGBO(26, 26, 31, 1);
  static const _outlineNormal = Color.fromRGBO(148, 148, 158, 1);
  static const _textBright = Color.fromRGBO(224, 222, 235, 1);
  static const _textDim = Color.fromRGBO(140, 138, 153, 1);

  @override
  Widget build(BuildContext context) {
    final enabled = !locked && onChanged != null;

    return InkWell(
      onTap: enabled ? () => onChanged!(!checked) : null,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: !enabled
                    ? _disabledFill
                    : (checked ? _checkedFill : _uncheckedFill),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: enabled
                      ? _outlineNormal
                      : _outlineNormal.withOpacity(0.4),
                  width: 1.2,
                ),
              ),
              child: checked
                  ? const Icon(Icons.check, size: 14, color: _textBright)
                  : null,
            ),
            const SizedBox(width: 6),
            Text(
              'Wait',
              style: TextStyle(
                color: enabled ? _textBright : _textDim,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
