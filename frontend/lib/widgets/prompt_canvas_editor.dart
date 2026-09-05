import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The Prompt Node's **expanded** editing surface, mounted as that node's tab in
/// the right-hand Focus Panel (see `DESIGN.md` → "Prompt Node").
///
/// This is a *view* onto state owned elsewhere: [controller] belongs to the node
/// widget's `State`, and the node's compact inline field is attached to the very
/// same controller. Sync between the two surfaces is therefore structural — a
/// keystroke here lands in the node body on the next frame, and vice versa,
/// without any mirroring code that could drift.
///
/// The gutter numbers **logical** lines and measures each one's wrapped height,
/// so a number stays level with the first visual row of its line whether wrap is
/// on or off.
class PromptCanvasEditor extends StatefulWidget {
  final TextEditingController controller;

  /// Clipboard seam. Defaults to the real [Clipboard]; tests inject a fake
  /// rather than driving the platform channel.
  final Future<String?> Function()? readClipboard;
  final Future<void> Function(String text)? writeClipboard;

  const PromptCanvasEditor({
    super.key,
    required this.controller,
    this.readClipboard,
    this.writeClipboard,
  });

  @override
  State<PromptCanvasEditor> createState() => _PromptCanvasEditorState();
}

class _PromptCanvasEditorState extends State<PromptCanvasEditor> {
  static const _style = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.45,
  );

  /// Shared by the gutter and the field so numbers scroll with the text.
  final ScrollController _scroll = ScrollController();

  bool _wrap = true;
  String? _toast;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(PromptCanvasEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// Repaint the gutter as lines are added or removed. The controller itself is
  /// owned by the node, so this listener only drives local chrome.
  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  // ── Clipboard actions ────────────────────────────────────────────────────

  Future<void> _copyAll() async {
    final text = widget.controller.text;
    if (text.isEmpty) return;
    final write = widget.writeClipboard ??
        (String t) => Clipboard.setData(ClipboardData(text: t));
    await write(text);
    _flash('Copied ${text.length} chars');
  }

  Future<void> _paste() async {
    final read = widget.readClipboard ??
        () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final pasted = await read();
    if (pasted == null || pasted.isEmpty) {
      _flash('Clipboard is empty');
      return;
    }
    // Insert at the caret when there is one, replacing any selection, so Paste
    // behaves like the editor's own ⌘V rather than always appending.
    final value = widget.controller.value;
    final sel = value.selection;
    if (sel.isValid) {
      final text = value.text.replaceRange(sel.start, sel.end, pasted);
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: sel.start + pasted.length),
      );
    } else {
      widget.controller.text = value.text + pasted;
    }
    _flash('Pasted ${pasted.length} chars');
  }

  void _clear() {
    if (widget.controller.text.isEmpty) return;
    widget.controller.clear();
    _flash('Cleared');
  }

  void _flash(String message) {
    if (!mounted) return;
    setState(() => _toast = message);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = widget.controller.text.split('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(theme, scheme, lines.length),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: scheme.surfaceContainerLowest,
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Gutter width tracks the widest line number so the text
                    // column does not shift as the document grows past 9, 99, …
                    final digits = '${lines.length}'.length;
                    final gutterWidth = 16.0 + digits * 7.0;
                    final textWidth =
                        constraints.maxWidth - gutterWidth - 12;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _gutter(lines, gutterWidth, textWidth, scheme),
                        Expanded(child: _field(scheme)),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(ThemeData theme, ColorScheme scheme, int lineCount) {
    final chars = widget.controller.text.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _toast ?? '$lineCount lines · $chars chars',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: _toast != null ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _wrap = !_wrap),
            icon: Icon(_wrap ? Icons.wrap_text : Icons.short_text, size: 18),
            tooltip: _wrap ? 'Word wrap: on' : 'Word wrap: off',
            visualDensity: VisualDensity.compact,
            isSelected: _wrap,
          ),
          IconButton(
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            tooltip: 'Copy All',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: _paste,
            icon: const Icon(Icons.content_paste_outlined, size: 18),
            tooltip: 'Paste',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// Line-number column. Each entry is sized to its logical line's *rendered*
  /// height, so wrapped lines push the following numbers down by exactly the
  /// number of visual rows they occupy.
  Widget _gutter(
    List<String> lines,
    double width,
    double textWidth,
    ColorScheme scheme,
  ) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < lines.length; i++)
            SizedBox(
              height: _lineHeight(lines[i], textWidth),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.right,
                  style: _style.copyWith(color: scheme.outline),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Rendered height of one logical line — one row when wrap is off, however
  /// many rows the text needs when it is on.
  double _lineHeight(String line, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: line.isEmpty ? ' ' : line, style: _style),
      textDirection: TextDirection.ltr,
      maxLines: _wrap ? null : 1,
    )..layout(maxWidth: _wrap && maxWidth > 0 ? maxWidth : double.infinity);
    return painter.height;
  }

  Widget _field(ColorScheme scheme) {
    final field = TextField(
      controller: widget.controller,
      maxLines: null,
      expands: false,
      style: _style,
      cursorColor: scheme.primary,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: 'Compose a prompt…',
      ),
    );
    // With wrap off the field must be free to exceed the viewport, so it goes
    // in a horizontal scroller instead of being width-constrained.
    return _wrap
        ? field
        : Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(child: field),
            ),
          );
  }
}
