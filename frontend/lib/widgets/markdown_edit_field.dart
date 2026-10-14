import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// A multi-line text field with an Edit / Preview toggle.
///
/// ## One source of truth
///
/// The text lives in [controller] and nowhere else. Preview is a read-only
/// render of `controller.text`; it never writes back, so what a downstream
/// consumer (the LLM) receives is exactly what was typed — markdown rendering
/// is a view, not a transform. Switching modes never touches the controller,
/// so the caret/selection of the edit field survives a round trip as far as
/// Flutter keeps it.
///
/// Both modes are always mounted-by-need: the [TextField] is only built while
/// editing, the [MarkdownBody] only while previewing. The controller outlives
/// both, so switching cannot lose text.
class MarkdownEditField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final int minLines;
  final int maxLines;

  /// Start in preview mode. Ignored when the text is empty — an empty preview
  /// is a blank box with no way to tell it is editable.
  final bool startInPreview;

  /// Called whenever the mode changes (true = previewing).
  final ValueChanged<bool>? onModeChanged;

  const MarkdownEditField({
    super.key,
    required this.controller,
    this.hintText = '',
    this.minLines = 4,
    this.maxLines = 8,
    this.startInPreview = false,
    this.onModeChanged,
  });

  @override
  State<MarkdownEditField> createState() => _MarkdownEditFieldState();
}

class _MarkdownEditFieldState extends State<MarkdownEditField> {
  late bool _preview;

  /// One controller per scrolling surface, so each can carry a visible
  /// scrollbar. Without it the long text scrolls but nothing says there is more.
  final ScrollController _previewScroll = ScrollController();
  final ScrollController _editScroll = ScrollController();

  @override
  void dispose() {
    _previewScroll.dispose();
    _editScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _preview = widget.startInPreview && widget.controller.text.isNotEmpty;
  }

  void _setPreview(bool value) {
    if (value == _preview) return;
    setState(() => _preview = value);
    widget.onModeChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SegmentedButton<bool>(
            key: const ValueKey('md-mode-toggle'),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(value: false, label: Text('Edit')),
              ButtonSegment(value: true, label: Text('Preview')),
            ],
            selected: {_preview},
            onSelectionChanged: (s) => _setPreview(s.first),
          ),
        ),
        const SizedBox(height: 4),
        if (_preview)
          _buildPreview(theme)
        else
          Scrollbar(
            controller: _editScroll,
            thumbVisibility: true,
            child: TextField(
            controller: widget.controller,
            scrollController: _editScroll,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              hintText: widget.hintText,
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final text = widget.controller.text;
    // Same footprint as the editor, so toggling does not resize the node.
    // Taller text scrolls inside the box rather than growing the node.
    return GestureDetector(
      key: const ValueKey('md-preview'),
      behavior: HitTestBehavior.opaque,
      // Double-click is the Obsidian-style shortcut back to editing.
      onDoubleTap: () => _setPreview(false),
      child: Container(
        constraints: BoxConstraints(
          minHeight: widget.minLines * 16.0,
          maxHeight: widget.maxLines * 16.0,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: text.isEmpty
            ? Text(
                widget.hintText,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              )
            : Scrollbar(
                controller: _previewScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                controller: _previewScroll,
                child: MarkdownBody(
                  data: text,
                  // Selectable would swallow the double-tap-to-edit gesture.
                  selectable: false,
                  styleSheet:
                      MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: theme.textTheme.bodySmall,
                    code: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
                ),
              ),
      ),
    );
  }
}
