import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/content_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/inventory_api.dart';
import '../../../services/inventory_store.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Vertical space at the top of the body to clear the deepest edge-anchored
/// port label. Ports sit at `kPortLaneTop + idx × kPortSpacing`; the deepest
/// port here is idx 1 (the `content` output), so clearance = 4 + 1 × 24 = 28.
const double _kPortLaneInset = 28;

enum _SortBy { author, workTitle }

class InventoryNode extends BaseNodeWidget {
  static const double _width = 320;

  static const List<String> authors = ['gilbert', 'chesterton', 'churchill'];

  /// Called once with the fetched-asset stream — the `content` connector.
  final void Function(Stream<ContentPayload> content)? onContentConnect;

  /// Raw locations arriving from an upstream URL Source node.
  final Stream<String>? locationInput;

  /// Local file-backed catalog. Injectable for tests.
  final InventoryStore? store;

  const InventoryNode({
    super.key,
    required super.node,
    super.onOutputPort,
    this.onContentConnect,
    this.locationInput,
    super.onInputConnect,
    super.connectedOutputs,
    this.store,
    super.initialParams,
    super.onParams,
  });

  @override
  State<InventoryNode> createState() => _InventoryNodeState();
}

class _InventoryNodeState extends BaseNodeState<InventoryNode> {
  @override String   get nodeTitle => 'Inventory';
  @override IconData get nodeIcon  => Icons.inventory_2_outlined;
  @override double   get nodeWidth => InventoryNode._width;

  late final InventoryStore _store = widget.store ?? InventoryStore();

  List<InventoryEntry> _entries    = [];
  String?              _selectedId;
  final _SortBy        _sortBy     = _SortBy.author;

  bool    _loading = true;
  bool    _busy    = false;
  String? _error;

  final OutputPort _out        = OutputPort('entry');
  AaPayload?       _lastOutput;
  String?          _sentId;

  final OutputPort _contentOut       = OutputPort('content');
  AaPayload?       _lastContentOutput;

  late final StreamController<ContentPayload> _contentOutput;
  ContentPayload? _lastContent;

  StreamSubscription<String>? _locationSub;
  bool    _fetching      = false;
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
    _contentOutput = StreamController<ContentPayload>.broadcast(
      onListen: _replayLastContent,
    );
    final saved = widget.initialParams?['selectedId'];
    if (saved != null && saved.isNotEmpty) _selectedId = saved;
    initOutputPort(_out);
    widget.onOutputPort?.call(_contentOut);
    widget.onContentConnect?.call(_contentOutput.stream);
    _subscribeLocations();
    _load();
  }

  void _reportParams() => saveParams({'selectedId': _selectedId ?? ''});

  @override
  void didUpdateWidget(InventoryNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locationInput != widget.locationInput) _subscribeLocations();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _out.dispose();
    _contentOut.dispose();
    _contentOutput.close();
    super.dispose();
  }

  void _replayLastContent() {
    final payload = _lastContent;
    if (payload == null) return;
    scheduleMicrotask(() {
      if (!_contentOutput.isClosed) _contentOutput.add(payload);
    });
  }

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
      _busy  = true;
      _error = null;
    });
    try {
      final entries = await _store.create(InventoryFields(url: trimmed));
      if (!mounted) return;
      final added = entries.where((e) => e.url.trim() == trimmed);
      setState(() {
        _entries = _sorted(entries);
        if (added.isNotEmpty) _selectedId = added.last.entryId;
      });
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
      return;
    } finally {
      if (mounted) { setState(() => _busy = false); }
    }
    await _select();
    await _fetchActiveContent();
  }

  Future<void> _fetchActiveContent() async {
    final entry    = _selected;
    if (entry == null || _fetching) return;
    final location = entry.url.trim();
    if (location.isEmpty) return;

    setState(() {
      _fetching      = true;
      _contentStatus = null;
      _error         = null;
    });
    try {
      final payload = await _readLocation(location, entry);
      if (!mounted) return;
      _lastContent = payload;
      _contentOutput.add(payload);

      final textContent = String.fromCharCodes(payload.bytes);
      _lastContentOutput = AaPayload(
        rows: const ['content'],
        cols: const [
          'raw_text', 'author', 'work_title', 'source_url', 'content_type',
        ],
        vals: [
          textContent,
          payload.author,
          payload.workTitle,
          payload.sourceUrl,
          payload.contentType ?? '',
        ],
      );
      _contentOut.emit(_lastContentOutput!);

      setState(() => _contentStatus =
          'Fetched ${payload.byteCount} bytes'
          '${payload.contentType != null ? ' · ${payload.contentType}' : ''}');
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
    } finally {
      if (mounted) { setState(() => _fetching = false); }
    }
  }

  Future<ContentPayload> _readLocation(
    String location,
    InventoryEntry entry,
  ) async {
    final uri   = Uri.tryParse(location);
    final isWeb = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');

    if (isWeb) {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception(
          'Fetch failed for $location (status ${response.statusCode}).',
        );
      }
      return ContentPayload(
        sourceUrl:   location,
        bytes:       response.bodyBytes,
        contentType: response.headers['content-type'],
        workTitle:   entry.workTitle,
        author:      entry.author,
      );
    }

    final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : location;
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('No file found at $path.');
    }
    final bytes = await file.readAsBytes();
    return ContentPayload(
      sourceUrl:   location,
      bytes:       Uint8List.fromList(bytes),
      contentType: _contentTypeFor(path),
      workTitle:   entry.workTitle,
      author:      entry.author,
    );
  }

  String? _contentTypeFor(String path) {
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'png'             => 'image/png',
      'jpg' || 'jpeg'   => 'image/jpeg',
      'gif'             => 'image/gif',
      'webp'            => 'image/webp',
      'txt'             => 'text/plain',
      'html' || 'htm'   => 'text/html',
      'json'            => 'application/json',
      _                 => null,
    };
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error   = null;
    });
    try {
      final entries = await _store.load();
      if (!mounted) return;
      setState(() {
        _entries = _sorted(entries);
        if (_selected == null) _selectedId = null;
      });
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
    } finally {
      if (mounted) { setState(() => _loading = false); }
    }
  }

  List<InventoryEntry> _sorted(List<InventoryEntry> entries) {
    final sorted = [...entries];
    int cmp(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    sorted.sort(
      (a, b) => switch (_sortBy) {
        _SortBy.author =>
          cmp(a.author, b.author) != 0
              ? cmp(a.author, b.author)
              : cmp(a.workTitle, b.workTitle),
        _SortBy.workTitle => cmp(a.workTitle, b.workTitle),
      },
    );
    return sorted;
  }

  Future<void> _select() async {
    final entry = _selected;
    if (entry == null || _busy) return;
    setState(() {
      _busy  = true;
      _error = null;
    });
    try {
      final payload = _store.selectAa(entry);
      if (!mounted) return;
      _lastOutput = payload;
      _out.emit(payload);
      setState(() => _sentId = entry.entryId);
    } catch (e) {
      if (mounted) { setState(() => _error = '$e'); }
    } finally {
      if (mounted) { setState(() => _busy = false); }
    }
  }

  void _onDropdownChanged(String? id) {
    setState(() => _selectedId = id);
    _reportParams();
    _selectAndFetch();
  }

  Future<void> _selectAndFetch() async {
    await _select();
    await _fetchActiveContent();
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'trigger',
          idx: 0,
          active: widget.locationInput != null,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'entry',
          idx: 0,
          active: _lastOutput != null || widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'content',
          idx: 1,
          active:
              _lastContentOutput != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Clear the deepest port label (content idx 1, slot bottom Y=74;
        // body starts Y=46; clearance = 28 px).
        const SizedBox(height: _kPortLaneInset),
        _entryPicker(theme),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed:
                (_busy || _fetching || _selected == null)
                    ? null
                    : _selectAndFetch,
            icon: (_busy || _fetching)
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined, size: 18),
            label: const Text('Select'),
          ),
        ),
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
                  'Sent "${_entries.firstWhere(
                    (e) => e.entryId == _sentId,
                    orElse: () => _blank,
                  ).workTitle}" downstream',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: Colors.green),
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
                width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('Fetching content', style: theme.textTheme.labelSmall),
            ],
          ),
        ] else if (_contentStatus != null) ...[
          const SizedBox(height: 8),
          Text(
            _contentStatus!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  static const _blank = InventoryEntry(
    entryId:      '',
    url:          '',
    author:       '',
    workTitle:    '',
    workSelector: '',
    description:  '',
  );

  Widget _entryPicker(ThemeData theme) {
    if (_loading) {
      return Text('Loading catalog', style: theme.textTheme.bodySmall);
    }
    if (_entries.isEmpty) {
      return Text(
        'No entries yet. Connect a URL Source to add one.',
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
            child: Text(
              _entryLabel(e),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (_busy || _fetching) ? null : _onDropdownChanged,
    );
  }

  String _entryLabel(InventoryEntry e) {
    final title  = e.workTitle.trim().isNotEmpty ? e.workTitle.trim() : e.url;
    final author = e.author.trim();
    return author.isEmpty ? title : '$title ($author)';
  }

  Widget _errorBanner(ThemeData theme) {
    final message = _error!.replaceAll('\n', ' ').trim();
    final concise = message.length > 90
        ? '${message.substring(0, 90)}…'
        : message;
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
