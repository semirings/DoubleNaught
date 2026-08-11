import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/aa_payload.dart';
import 'aa_dataframe.dart';
import 'prompt_canvas_editor.dart';

ImageProvider? resolveImageProvider(String targetUrl) {
  final trimmed = targetUrl.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return NetworkImage(trimmed);
  }
  if (uri != null && uri.scheme == 'file') {
    return FileImage(File(uri.toFilePath()));
  }
  return FileImage(File(trimmed));
}

/// What a Focus Panel tab shows.
enum FocusContentKind { image, text, aa, promptEditor }

/// A piece of heavy content routed to the Focus Panel by a node.
class FocusContent {
  final FocusContentKind kind;
  final String? text;
  final Uint8List? imageBytes;
  final String? imageUrl;
  final AaPayload? aa;
  final String? subtitle;

  /// For [FocusContentKind.promptEditor]: the *live* controller owned by the
  /// contributing node's `State`. The panel edits that state directly rather
  /// than a snapshot of it, which is what makes the node's inline field and this
  /// tab two views of one document.
  final TextEditingController? controller;

  const FocusContent._({
    required this.kind,
    this.text,
    this.imageBytes,
    this.imageUrl,
    this.aa,
    this.subtitle,
    this.controller,
  });

  const FocusContent.image({Uint8List? bytes, String? url, String? subtitle})
    : this._(
        kind: FocusContentKind.image,
        imageBytes: bytes,
        imageUrl: url,
        subtitle: subtitle,
      );

  const FocusContent.text(String value, {String? subtitle})
    : this._(kind: FocusContentKind.text, text: value, subtitle: subtitle);

  const FocusContent.aa(AaPayload value, {String? subtitle})
    : this._(kind: FocusContentKind.aa, aa: value, subtitle: subtitle);

  /// A live text-editing workspace backed by [controller] — the Prompt Node's
  /// expanded editor.
  const FocusContent.promptEditor(
    TextEditingController controller, {
    String? subtitle,
  }) : this._(
         kind: FocusContentKind.promptEditor,
         controller: controller,
         subtitle: subtitle,
       );
}

/// One tab in the Focus Panel, owned by the node with [nodeId].
class FocusTab {
  final int nodeId;
  final String title;
  final FocusContent content;

  const FocusTab({
    required this.nodeId,
    required this.title,
    required this.content,
  });
}

/// The right-margin slideout Focus Panel.
///
/// For AA tabs, the panel exposes a [View] / [Edit] toggle. In Edit mode a
/// working copy of the AA is presented in a row-editor; [onAaEdited] is called
/// with the committed [AaPayload] when the user presses Apply.
class FocusPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onToggle;
  final List<FocusTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelectTab;
  final double openWidth;

  /// Called after the user presses Apply in AA-edit mode.
  /// [nodeId] identifies the tab whose AA was edited.
  final void Function(int nodeId, AaPayload edited)? onAaEdited;

  const FocusPanel({
    super.key,
    required this.isOpen,
    required this.onToggle,
    this.tabs = const [],
    this.selectedIndex = 0,
    required this.onSelectTab,
    this.openWidth = 420,
    this.onAaEdited,
  });

  @override
  State<FocusPanel> createState() => _FocusPanelState();
}

class _FocusPanelState extends State<FocusPanel> {
  bool _editMode = false;

  // Working copy — null when not editing.
  // Each triple is stored as a mutable map so cells are individually editable.
  List<Map<String, String>>? _working;
  String? _validationError;

  // Track the tab we entered edit mode for; reset if the tab changes.
  int? _editingTabIndex;

  FocusTab? get _currentTab {
    if (widget.tabs.isEmpty) return null;
    final i = widget.selectedIndex.clamp(0, widget.tabs.length - 1);
    return widget.tabs[i];
  }

  void _enterEdit() {
    final tab = _currentTab;
    if (tab == null || tab.content.aa == null) return;
    final aa = tab.content.aa!;
    setState(() {
      _editMode = true;
      _editingTabIndex = widget.selectedIndex;
      _validationError = null;
      _working = [
        for (var i = 0; i < aa.rows.length; i++)
          {
            'row': aa.rows[i],
            'col': aa.cols[i],
            'val': aa.vals[i].toString(),
          }
      ];
    });
  }

  void _cancelEdit() {
    setState(() {
      _editMode = false;
      _working = null;
      _editingTabIndex = null;
      _validationError = null;
    });
  }

  void _applyEdit() {
    final tab = _currentTab;
    if (tab == null || _working == null) return;

    // Validate: no blank row or col keys; no duplicate (row, col) pairs.
    final seen = <String>{};
    for (final triple in _working!) {
      final row = triple['row']!.trim();
      final col = triple['col']!.trim();
      if (row.isEmpty || col.isEmpty) {
        setState(() => _validationError =
            'Row and column keys must not be empty.');
        return;
      }
      final key = '$row\x00$col';
      if (!seen.add(key)) {
        setState(
            () => _validationError = 'Duplicate triple ($row, $col).');
        return;
      }
    }

    final edited = AaPayload(
      rows: [for (final t in _working!) t['row']!.trim()],
      cols: [for (final t in _working!) t['col']!.trim()],
      vals: [for (final t in _working!) t['val']!],
    );

    widget.onAaEdited?.call(tab.nodeId, edited);
    setState(() {
      _editMode = false;
      _working = null;
      _editingTabIndex = null;
      _validationError = null;
    });
  }

  // Reset edit state when the selected tab changes away from the one being edited.
  void _checkTabChange() {
    if (_editMode &&
        _editingTabIndex != null &&
        _editingTabIndex != widget.selectedIndex) {
      _cancelEdit();
    }
  }

  @override
  Widget build(BuildContext context) {
    _checkTabChange();
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        _Rail(isOpen: widget.isOpen, onToggle: widget.onToggle),
        ClipRect(
          child: Container(
            width: widget.isOpen ? widget.openWidth : 0,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border(left: BorderSide(color: scheme.outlineVariant)),
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: widget.openWidth,
              maxWidth: widget.openWidth,
              child: _body(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (widget.tabs.isEmpty) {
      return Center(
        child: Text(
          'Nothing to display yet',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final index = widget.selectedIndex.clamp(0, widget.tabs.length - 1);
    final tab = widget.tabs[index];
    final isAa = tab.content.kind == FocusContentKind.aa;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
            tabs: widget.tabs,
            selectedIndex: index,
            onSelect: widget.onSelectTab),

        // Subtitle row (with optional View/Edit toggle for AA tabs).
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Row(
            children: [
              if (tab.content.subtitle != null &&
                  tab.content.subtitle!.isNotEmpty)
                Expanded(
                  child: Text(
                    tab.content.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                const Spacer(),
              if (isAa && !_editMode)
                TextButton.icon(
                  onPressed: _enterEdit,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              if (isAa && _editMode) ...[
                TextButton(
                  onPressed: _cancelEdit,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _applyEdit,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  ),
                  child: const Text('Apply'),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        ),

        if (_validationError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              _validationError!,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.error),
            ),
          ),

        Expanded(
          child: _editMode && isAa && _working != null
              ? _AaEditor(
                  working: _working!,
                  onChanged: (w) => setState(() => _working = w),
                )
              : _content(context, tab.content),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, FocusContent content) {
    final theme = Theme.of(context);
    switch (content.kind) {
      case FocusContentKind.aa:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: AaDataFrame(aa: content.aa!),
        );
      case FocusContentKind.promptEditor:
        return PromptCanvasEditor(controller: content.controller!);
      case FocusContentKind.text:
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              content.text ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        );
      case FocusContentKind.image:
        final provider = content.imageUrl != null
            ? resolveImageProvider(content.imageUrl!)
            : null;
        Widget image;
        if (provider != null) {
          image = Image(
            image: provider,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                _placeholder(theme, 'That image could not be loaded.'),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
          );
        } else if (content.imageBytes != null) {
          image = Image.memory(
            content.imageBytes!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          );
        } else {
          return _placeholder(theme, 'No image loaded');
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Center(child: image),
        );
    }
  }

  Widget _placeholder(ThemeData theme, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// AA triple editor
// ---------------------------------------------------------------------------

/// Inline editor for an AA working copy (a list of `{row, col, val}` maps).
/// Renders a scrollable table of text fields; supports editing, adding, and
/// deleting triples.
class _AaEditor extends StatefulWidget {
  final List<Map<String, String>> working;
  final ValueChanged<List<Map<String, String>>> onChanged;

  const _AaEditor({required this.working, required this.onChanged});

  @override
  State<_AaEditor> createState() => _AaEditorState();
}

class _AaEditorState extends State<_AaEditor> {
  // Controllers keyed by (index, field).
  final Map<String, TextEditingController> _ctrls = {};

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(_AaEditor old) {
    super.didUpdateWidget(old);
    if (old.working.length != widget.working.length) {
      _disposeControllers();
      _syncControllers();
    }
  }

  void _syncControllers() {
    for (var i = 0; i < widget.working.length; i++) {
      for (final field in ['row', 'col', 'val']) {
        final k = '$i:$field';
        _ctrls.putIfAbsent(
          k,
          () => TextEditingController(text: widget.working[i][field] ?? ''),
        );
      }
    }
  }

  void _disposeControllers() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  TextEditingController _ctrl(int i, String field) {
    final k = '$i:$field';
    return _ctrls.putIfAbsent(
      k,
      () => TextEditingController(text: widget.working[i][field] ?? ''),
    );
  }

  void _notify() {
    // Flush controller text → working copy before notifying.
    final updated = <Map<String, String>>[];
    for (var i = 0; i < widget.working.length; i++) {
      updated.add({
        'row': _ctrl(i, 'row').text,
        'col': _ctrl(i, 'col').text,
        'val': _ctrl(i, 'val').text,
      });
    }
    widget.onChanged(updated);
  }

  void _addTriple() {
    final updated = List<Map<String, String>>.from(widget.working)
      ..add({'row': '', 'col': '', 'val': ''});
    widget.onChanged(updated);
  }

  void _deleteTriple(int index) {
    // Remove controller entries for this row before re-indexing.
    for (final field in ['row', 'col', 'val']) {
      _ctrls.remove('$index:$field')?.dispose();
    }
    final updated = List<Map<String, String>>.from(widget.working)
      ..removeAt(index);
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final headerStyle = theme.textTheme.labelMedium
        ?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 48, 4),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text('Row key', style: headerStyle)),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: Text('Column key', style: headerStyle)),
              const SizedBox(width: 8),
              Expanded(flex: 4, child: Text('Value', style: headerStyle)),
            ],
          ),
        ),
        const Divider(height: 1),

        // Triple rows.
        Expanded(
          child: ListView.builder(
            itemCount: widget.working.length,
            itemBuilder: (context, i) => _tripleRow(context, i),
          ),
        ),

        const Divider(height: 1),

        // Add-triple button.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _addTriple,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add triple'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tripleRow(BuildContext context, int i) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 3, child: _cell(_ctrl(i, 'row'))),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: _cell(_ctrl(i, 'col'))),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _cell(_ctrl(i, 'val'))),
          IconButton(
            onPressed: () => _deleteTriple(i),
            icon: const Icon(Icons.remove_circle_outline, size: 16),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            tooltip: 'Delete triple',
            color: Theme.of(context).colorScheme.error,
          ),
        ],
      ),
    );
  }

  Widget _cell(TextEditingController ctrl) => TextField(
        controller: ctrl,
        onChanged: (_) => _notify(),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        ),
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      );
}

// ---------------------------------------------------------------------------
// Tab strip and rail (unchanged)
// ---------------------------------------------------------------------------

class _TabStrip extends StatelessWidget {
  final List<FocusTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _TabStrip({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              InkWell(
                onTap: () => onSelect(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == selectedIndex
                            ? scheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    tabs[i].title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: i == selectedIndex
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: i == selectedIndex
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onToggle;

  const _Rail({required this.isOpen, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 28,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          Tooltip(
            message: isOpen ? 'Hide display panel' : 'Show display panel',
            child: IconButton(
              onPressed: onToggle,
              iconSize: 18,
              padding: const EdgeInsets.symmetric(vertical: 10),
              constraints: const BoxConstraints(),
              icon: Icon(isOpen ? Icons.chevron_right : Icons.chevron_left),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Center(
                child: Text(
                  'Display',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
