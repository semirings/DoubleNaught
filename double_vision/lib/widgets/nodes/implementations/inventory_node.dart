import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../models/content_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/inventory_api.dart';
import '../../../services/inventory_store.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// A workflow **source node** that maintains a persistent, editable list of URL
/// entries and outputs a single selected entry as a D4M/AA payload to a
/// downstream URLNode. It replaces URLNode's manual re-entry with a managed,
/// reusable inventory of sources.
///
/// The list, CRUD, and persistence live on the backend (`/inventory`); this
/// widget renders the list, drives the toolbar actions, and publishes the
/// selected entry on its `entry` output (broadcast, replaying the last selection
/// to late subscribers, per the source-node convention).
/// Vertical space reserved at the top of the body so the edge-anchored port
/// labels (`urlInput` left; `entry` / `content` right) clear the action bar.
/// Ports sit at `kPortLaneTop + idx * kPortSpacing`; the deepest here is idx 1.
const double _kPortLaneInset = 26;

class InventoryNode extends StatefulWidget {
  /// Compact: a single picker replaced the old multi-column table.
  static const double _width = 320;

  static const List<String> authors = ['gilbert', 'chesterton', 'churchill'];

  final WorkflowNode node;

  /// Called once with the node's output stream — the `entry` connector.
  final void Function(Stream<AaPayload> entry)? onConnect;

  /// Called once with the fetched-asset stream — the `content` connector.
  final void Function(Stream<ContentPayload> content)? onContentConnect;

  /// Raw locations arriving from an upstream URL Source node.
  final Stream<String>? locationInput;

  /// Called with the source endpoint when an edge is dropped on `urlInput`.
  final void Function(PortRef source)? onInputConnect;

  /// Output port indices with an outgoing edge — drives the connected highlight.
  final Set<int> connectedOutputs;

  /// Local file-backed catalog. Injectable for tests; defaults to
  /// `../storage/inventory.json`. No backend is involved.
  final InventoryStore? store;

  const InventoryNode({
    super.key,
    required this.node,
    this.onConnect,
    this.onContentConnect,
    this.locationInput,
    this.onInputConnect,
    this.connectedOutputs = const {},
    this.store,
  });

  @override
  State<InventoryNode> createState() => _InventoryNodeState();
}

enum _SortBy { author, workTitle }

class _InventoryNodeState extends State<InventoryNode> {
  /// The file-backed catalog; no network involved.
  late final InventoryStore _store = widget.store ?? InventoryStore();

  List<InventoryEntry> _entries = [];
  String? _selectedId;
  /// Ordering for the picker. Fixed now that the sort control is gone.
  final _SortBy _sortBy = _SortBy.author;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  late final StreamController<AaPayload> _output;
  AaPayload? _lastOutput;
  String? _sentId; // entry most recently emitted downstream

  /// Fetched-asset output, replaying the last payload to late subscribers.
  late final StreamController<ContentPayload> _contentOutput;
  ContentPayload? _lastContent;

  StreamSubscription<String>? _locationSub;
  bool _fetching = false;
  String? _contentStatus;

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
    _contentOutput =
        StreamController<ContentPayload>.broadcast(onListen: _replayLastContent);
    widget.onConnect?.call(_output.stream);
    widget.onContentConnect?.call(_contentOutput.stream);
    _subscribeLocations();
    _load();
  }

  @override
  void didUpdateWidget(InventoryNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locationInput != widget.locationInput) _subscribeLocations();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _output.close();
    _contentOutput.close();
    super.dispose();
  }

  void _replayLast() {
    final payload = _lastOutput;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_output.isClosed) _output.add(payload);
    });
  }

  void _replayLastContent() {
    final payload = _lastContent;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_contentOutput.isClosed) _contentOutput.add(payload);
    });
  }

  /// Locations arriving from an upstream URL Source node.
  void _subscribeLocations() {
    _locationSub?.cancel();
    _locationSub = widget.locationInput?.listen((location) {
      if (!mounted) return;
      _catalogLocation(location);
    });
  }

  /// Persist an incoming location as a new inventory row, refresh the picklist,
  /// make the new row the active selection, then fetch its content.
  Future<void> _catalogLocation(String location) async {
    final trimmed = location.trim();
    if (trimmed.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The backend derives a title and leaves the author unassigned; only the
      // location itself is required.
      final entries = await _store.create(InventoryFields(url: trimmed));
      if (!mounted) return;
      final added = entries.where((e) => e.url.trim() == trimmed);
      setState(() {
        _entries = _sorted(entries);
        // Task 2: the newly catalogued row becomes the active selection.
        if (added.isNotEmpty) _selectedId = added.last.entryId;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // Emit the catalog row, then the asset behind it.
    await _select();
    await _fetchActiveContent();
  }

  /// Fetch the bytes behind the active entry and stream them downstream.
  Future<void> _fetchActiveContent() async {
    final entry = _selected;
    if (entry == null || _fetching) return;
    final location = entry.url.trim();
    if (location.isEmpty) return;

    setState(() {
      _fetching = true;
      _contentStatus = null;
      _error = null;
    });
    try {
      final payload = await _readLocation(location, entry);
      if (!mounted) return;
      _lastContent = payload;
      _contentOutput.add(payload);
      setState(() => _contentStatus =
          'Fetched ${payload.byteCount} bytes${payload.contentType != null ? ' · ${payload.contentType}' : ''}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  /// Web addresses go over HTTP; anything else is read from local disk.
  Future<ContentPayload> _readLocation(
      String location, InventoryEntry entry) async {
    final uri = Uri.tryParse(location);
    final isWeb =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');

    if (isWeb) {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception(
            'Fetch failed for $location (status ${response.statusCode}).');
      }
      return ContentPayload(
        sourceUrl: location,
        bytes: response.bodyBytes,
        contentType: response.headers['content-type'],
        workTitle: entry.workTitle,
        author: entry.author,
      );
    }

    final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : location;
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('No file found at $path.');
    }
    final bytes = await file.readAsBytes();
    return ContentPayload(
      sourceUrl: location,
      bytes: Uint8List.fromList(bytes),
      contentType: _contentTypeFor(path),
      workTitle: entry.workTitle,
      author: entry.author,
    );
  }

  /// Best-effort MIME type from a file extension, for downstream routing.
  String? _contentTypeFor(String path) {
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'txt' => 'text/plain',
      'html' || 'htm' => 'text/html',
      'json' => 'application/json',
      _ => null,
    };
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _store.load();
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
    await _mutate(() => _store.create(fields));
  }

  Future<void> _edit() async {
    final entry = _selected;
    if (entry == null) return;
    final fields = await _showEntryForm(context, initial: entry);
    if (fields == null) return;
    await _mutate(() => _store.update(entry.entryId, fields));
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
      final entries = await _store.delete(entry.entryId);
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
      final payload = _store.selectAa(entry);
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
      inputPorts: [
        InputConnector(
          label: 'urlInput',
          idx: 0,
          active: widget.locationInput != null,
          onConnect: widget.onInputConnect,
        ),
      ],
      outputPorts: [
        OutputConnector(
          label: 'entry',
          idx: 0,
          active: hasOutput || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'content',
          idx: 1,
          active: _lastContent != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Clear the edge-anchored port lane (urlInput left; entry/content
          // right) so their labels never sit on top of the action buttons.
          const SizedBox(height: _kPortLaneInset),
          _actionBar(theme),
          const SizedBox(height: 8),
          _entryPicker(theme),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _errorBanner(theme),
          ],
          if (_sentId != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sent “${_entries.firstWhere((e) => e.entryId == _sentId, orElse: () => _blank).workTitle}” downstream',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
          if (_fetching) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('Fetching content', style: theme.textTheme.labelSmall),
              ],
            ),
          ] else if (_contentStatus != null) ...[
            const SizedBox(height: 8),
            Text(_contentStatus!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  static const _blank = InventoryEntry(
      entryId: '', url: '', author: '', workTitle: '', workSelector: '', description: '');

  /// Compact icon action bar — tooltips instead of wide text buttons.
  Widget _actionBar(ThemeData theme) {
    final hasSelection = _selected != null;
    final blocked = _busy || _fetching;

    Widget action(IconData icon, String tip, VoidCallback? onPressed) => IconButton(
          onPressed: onPressed,
          tooltip: tip,
          icon: Icon(icon, size: 18),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        );

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        action(Icons.add, 'Add an entry', blocked ? null : _add),
        action(Icons.edit_outlined, 'Edit the selected entry',
            (blocked || !hasSelection) ? null : _edit),
        action(Icons.delete_outline, 'Delete the selected entry',
            (blocked || !hasSelection) ? null : _delete),
        const SizedBox(width: 4),
        action(Icons.send, 'Send the selected entry downstream',
            (blocked || !hasSelection)
                ? null
                : () async {
                    await _select();
                    await _fetchActiveContent();
                  }),
        if (blocked)
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ],
    );
  }

  /// One dropdown showing "work title (author)" — replaces the wide column grid.
  Widget _entryPicker(ThemeData theme) {
    if (_loading) {
      return Text('Loading catalog', style: theme.textTheme.bodySmall);
    }
    if (_entries.isEmpty) {
      return Text(
        'No entries yet. Use Add, or connect a URL Source.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _selectedId,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      hint: Text('Select an entry', style: theme.textTheme.bodySmall),
      style: theme.textTheme.bodySmall,
      items: [
        for (final e in _sorted(_entries))
          DropdownMenuItem(
            value: e.entryId,
            child: Text(_entryLabel(e),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (_busy || _fetching)
          ? null
          : (id) => setState(() => _selectedId = id),
    );
  }

  /// "work title (author)", falling back gracefully when either is missing.
  String _entryLabel(InventoryEntry e) {
    final title = e.workTitle.trim().isNotEmpty ? e.workTitle.trim() : e.url;
    final author = e.author.trim();
    return author.isEmpty ? title : '$title ($author)';
  }

  /// One concise line — never a raw stack trace inside the node bounds.
  Widget _errorBanner(ThemeData theme) {
    final message = _error!.replaceAll('\n', ' ').trim();
    final concise = message.length > 90 ? '${message.substring(0, 90)}…' : message;
    return Tooltip(
      message: message,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              concise,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
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
