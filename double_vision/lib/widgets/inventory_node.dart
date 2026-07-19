import 'dart:async';

import 'package:flutter/material.dart';

import '../models/aa_payload.dart';
import '../models/workflow.dart';
import '../services/inventory_api.dart';
import 'double_naught_node_wrapper.dart';
import 'output_connector.dart';

/// A workflow **source node** that maintains a persistent, editable list of URL
/// entries and outputs a single selected entry as a D4M/AA payload to a
/// downstream URLNode. It replaces URLNode's manual re-entry with a managed,
/// reusable inventory of sources.
///
/// The list, CRUD, and persistence live on the backend (`/inventory`); this
/// widget renders the list, drives the toolbar actions, and publishes the
/// selected entry on its `entry` output (broadcast, replaying the last selection
/// to late subscribers, per the source-node convention).
class InventoryNode extends StatefulWidget {
  /// Wide enough to show the entry columns.
  static const double _width = 460;

  static const List<String> authors = ['gilbert', 'chesterton', 'churchill'];

  final WorkflowNode node;

  /// Called once with the node's output stream — the `entry` connector.
  final void Function(Stream<AaPayload> entry)? onConnect;

  /// Output port indices with an outgoing edge — drives the connected highlight.
  final Set<int> connectedOutputs;

  /// Backend client. Injectable for tests; defaults to the shared instance.
  final InventoryApi api;

  const InventoryNode({
    super.key,
    required this.node,
    this.onConnect,
    this.connectedOutputs = const {},
    this.api = const InventoryApi(),
  });

  @override
  State<InventoryNode> createState() => _InventoryNodeState();
}

enum _SortBy { author, workTitle }

class _InventoryNodeState extends State<InventoryNode> {
  List<InventoryEntry> _entries = [];
  String? _selectedId;
  _SortBy _sortBy = _SortBy.author;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  late final StreamController<AaPayload> _output;
  AaPayload? _lastOutput;
  String? _sentId; // entry most recently emitted downstream

  InventoryEntry? get _selected {
    for (final e in _entries) {
      if (e.entryId == _selectedId) return e;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _output = StreamController<AaPayload>.broadcast(onListen: _replayLast);
    widget.onConnect?.call(_output.stream);
    _load();
  }

  @override
  void dispose() {
    _output.close();
    super.dispose();
  }

  void _replayLast() {
    final payload = _lastOutput;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(payload);
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.api.list();
      if (!mounted) return;
      setState(() {
        _entries = _sorted(entries);
        if (_selected == null) _selectedId = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<InventoryEntry> _sorted(List<InventoryEntry> entries) {
    final sorted = [...entries];
    int cmp(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    sorted.sort((a, b) => switch (_sortBy) {
          _SortBy.author =>
            cmp(a.author, b.author) != 0 ? cmp(a.author, b.author) : cmp(a.workTitle, b.workTitle),
          _SortBy.workTitle => cmp(a.workTitle, b.workTitle),
        });
    return sorted;
  }

  Future<void> _add() async {
    final fields = await _showEntryForm(context);
    if (fields == null) return;
    await _mutate(() => widget.api.create(fields));
  }

  Future<void> _edit() async {
    final entry = _selected;
    if (entry == null) return;
    final fields = await _showEntryForm(context, initial: entry);
    if (fields == null) return;
    await _mutate(() => widget.api.update(entry.entryId, fields));
  }

  Future<void> _delete() async {
    final entry = _selected;
    if (entry == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text(entry.description.isNotEmpty ? entry.description : entry.workTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mutate(() async {
      final entries = await widget.api.delete(entry.entryId);
      _selectedId = null;
      return entries;
    });
  }

  Future<void> _mutate(Future<List<InventoryEntry>> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final entries = await action();
      if (!mounted) return;
      setState(() => _entries = _sorted(entries));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select() async {
    final entry = _selected;
    if (entry == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = await widget.api.select(entry.entryId);
      if (!mounted) return;
      _lastOutput = payload;
      _output.add(payload);
      setState(() => _sentId = entry.entryId);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasOutput = _lastOutput != null;

    return DoubleNaughtNodeWrapper(
      title: 'Inventory',
      icon: Icons.inventory_2_outlined,
      width: InventoryNode._width,
      outputPorts: [
        OutputConnector(
          label: 'entry',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _toolbar(theme),
          const SizedBox(height: 8),
          _sortRow(theme),
          const SizedBox(height: 6),
          _header(theme),
          const Divider(height: 8),
          _list(theme),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text('Error: $_error',
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
          ],
          if (_sentId != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sent “${_entries.firstWhere((e) => e.entryId == _sentId, orElse: () => _blank).workTitle}” to URLNode',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static const _blank = InventoryEntry(
      entryId: '', url: '', author: '', workTitle: '', workSelector: '', description: '');

  Widget _toolbar(ThemeData theme) {
    final hasSelection = _selected != null;
    return Wrap(
      spacing: 6,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add'),
        ),
        OutlinedButton.icon(
          onPressed: (_busy || !hasSelection) ? null : _edit,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('Edit'),
        ),
        OutlinedButton.icon(
          onPressed: (_busy || !hasSelection) ? null : _delete,
          style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Delete'),
        ),
        FilledButton.icon(
          onPressed: (_busy || !hasSelection) ? null : _select,
          icon: const Icon(Icons.send, size: 16),
          label: const Text('Select'),
        ),
      ],
    );
  }

  Widget _sortRow(ThemeData theme) {
    return Row(
      children: [
        Text('Sort:', style: theme.textTheme.labelSmall),
        const SizedBox(width: 8),
        DropdownButton<_SortBy>(
          value: _sortBy,
          isDense: true,
          style: theme.textTheme.labelSmall,
          items: const [
            DropdownMenuItem(value: _SortBy.author, child: Text('author')),
            DropdownMenuItem(value: _SortBy.workTitle, child: Text('work title')),
          ],
          onChanged: (v) => setState(() {
            _sortBy = v ?? _sortBy;
            _entries = _sorted(_entries);
          }),
        ),
      ],
    );
  }

  // Column flex weights, shared by the header and the rows.
  static const _flex = {
    'description': 3,
    'author': 2,
    'work_title': 3,
    'work_selector': 3,
    'url': 3,
  };

  Widget _cell(String text, int flex, ThemeData theme, {bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall
            ?.copyWith(fontWeight: bold ? FontWeight.w600 : FontWeight.w400),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600);
    Widget h(String t, int flex) =>
        Expanded(flex: flex, child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: style));
    return Row(
      children: [
        h('description', _flex['description']!),
        h('author', _flex['author']!),
        h('work_title', _flex['work_title']!),
        h('work_selector', _flex['work_selector']!),
        h('url', _flex['url']!),
      ],
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('No entries. Use Add to create one.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _entries.length,
        itemBuilder: (context, i) {
          final e = _entries[i];
          final selected = e.entryId == _selectedId;
          return InkWell(
            onTap: () => setState(() => _selectedId = e.entryId),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              color: selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
              child: Row(
                children: [
                  _cell(e.description, _flex['description']!, theme, bold: true),
                  _cell(e.author, _flex['author']!, theme),
                  _cell(e.workTitle, _flex['work_title']!, theme),
                  _cell(e.workSelector, _flex['work_selector']!, theme),
                  _cell(e.url, _flex['url']!, theme),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shows the Add/Edit form dialog; returns the entered [InventoryFields], or
/// null if cancelled. Pre-fills from [initial] when editing.
Future<InventoryFields?> _showEntryForm(BuildContext context, {InventoryEntry? initial}) {
  return showDialog<InventoryFields>(
    context: context,
    builder: (_) => _EntryFormDialog(initial: initial),
  );
}

class _EntryFormDialog extends StatefulWidget {
  final InventoryEntry? initial;
  const _EntryFormDialog({this.initial});

  @override
  State<_EntryFormDialog> createState() => _EntryFormDialogState();
}

class _EntryFormDialogState extends State<_EntryFormDialog> {
  late final TextEditingController _url;
  late final TextEditingController _title;
  late final TextEditingController _selector;
  late final TextEditingController _description;
  String? _author;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    _url = TextEditingController(text: e?.url ?? '');
    _title = TextEditingController(text: e?.workTitle ?? '');
    _selector = TextEditingController(text: e?.workSelector ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    _author = e?.author;
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _selector.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    if (_url.text.trim().isEmpty || _title.text.trim().isEmpty || _author == null) {
      setState(() => _validationError = 'URL, Author and Work Title are required');
      return;
    }
    Navigator.pop(
      context,
      InventoryFields(
        url: _url.text.trim(),
        author: _author!,
        workTitle: _title.text.trim(),
        workSelector: _selector.text.trim(),
        description: _description.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, [String? hint]) => InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        );
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add entry' : 'Edit entry'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _url, decoration: deco('URL', 'https://…')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _author,
                decoration: deco('Author'),
                hint: const Text('select author'),
                items: [
                  for (final a in InventoryNode.authors)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (v) => setState(() => _author = v),
              ),
              const SizedBox(height: 12),
              TextField(controller: _title, decoration: deco('Work Title')),
              const SizedBox(height: 12),
              TextField(
                  controller: _selector,
                  decoration: deco('Work Selector (optional)', 'e.g. THE MIKADO; OR, …')),
              const SizedBox(height: 12),
              TextField(controller: _description, decoration: deco('Description')),
              if (_validationError != null) ...[
                const SizedBox(height: 10),
                Text(_validationError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
