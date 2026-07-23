import 'dart:convert';
import 'dart:io';

import '../models/aa_payload.dart';
import 'inventory_api.dart' show InventoryEntry, InventoryFields;

/// Local, file-backed inventory persistence — no backend required.
///
/// The catalog lives in `inventory.json` under the workspace storage directory
/// (`../storage/` relative to the process working directory, matching
/// [StorageService]). A missing or unreadable file is treated as an empty
/// catalog rather than an error, so the node starts clean on first run.
///
/// Note `dart:io` makes this desktop/mobile only.
class InventoryStore {
  /// Absolute directory for the local JSON catalog. Absolute (not CWD-relative)
  /// because a bundled macOS app runs with a working directory of `/`. Defaults
  /// to the repo's `storage/` so the file is visible in the workspace; override
  /// per run with `--dart-define=DN_STORAGE_DIR=/path` (run.sh DV passes it).
  ///
  /// Writing here requires the app to be **un-sandboxed** — the debug build
  /// disables `com.apple.security.app-sandbox` for exactly this reason.
  static const _storageDir = String.fromEnvironment(
    'DN_STORAGE_DIR',
    defaultValue: '/Users/gcr/populi.Wk/DoubleNaught/storage',
  );

  /// Explicit file path, for tests or a deliberate override.
  final String? overridePath;

  File? _cachedFile;

  InventoryStore({this.overridePath});

  /// The backing file, resolved once and cached.
  Future<File> resolveFile() async {
    final cached = _cachedFile;
    if (cached != null) return cached;
    final file = File(overridePath ?? '$_storageDir/inventory.json');
    _cachedFile = file;
    return file;
  }

  static const List<String> _columns = [
    'url',
    'author',
    'work_title',
    'work_selector',
    'description',
  ];

  /// Read the catalog. Returns an empty list when the file is absent, empty, or
  /// malformed — never throws for those cases.
  Future<List<InventoryEntry>> load() async {
    final file = await resolveFile();
    if (!await file.exists()) return const [];
    final raw = (await file.readAsString()).trim();
    if (raw.isEmpty) return const [];

    final decoded = jsonDecode(raw);
    // Preferred shape: a plain JSON array of entry objects.
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>) _entryFromJson(item),
      ];
    }
    // Tolerate a catalog previously written by the backend in D4M/AA form so an
    // existing file does not crash the node.
    if (decoded is Map<String, dynamic> && decoded['cols'] is List) {
      return _entriesFromAa(AaPayload.fromJson(decoded));
    }
    return const [];
  }

  /// Append a new entry and persist, returning the full updated catalog.
  Future<List<InventoryEntry>> create(InventoryFields fields) async {
    final entries = [...await load()];
    entries.add(
      InventoryEntry(
        entryId: _newEntryId(),
        url: fields.url.trim(),
        author: fields.author,
        // A bare location carries no curated title; derive one.
        workTitle: fields.workTitle.trim().isNotEmpty
            ? fields.workTitle.trim()
            : deriveWorkTitle(fields.url),
        workSelector: fields.workSelector,
        description: fields.description,
      ),
    );
    await _save(entries);
    return entries;
  }

  /// Replace the fields of [entryId] and persist.
  Future<List<InventoryEntry>> update(
      String entryId, InventoryFields fields) async {
    final entries = [
      for (final e in await load())
        if (e.entryId == entryId)
          InventoryEntry(
            entryId: e.entryId,
            url: fields.url.trim(),
            author: fields.author,
            workTitle: fields.workTitle.trim().isNotEmpty
                ? fields.workTitle.trim()
                : deriveWorkTitle(fields.url),
            workSelector: fields.workSelector,
            description: fields.description,
          )
        else
          e,
    ];
    await _save(entries);
    return entries;
  }

  /// Remove [entryId] and persist.
  Future<List<InventoryEntry>> delete(String entryId) async {
    final entries = [
      for (final e in await load())
        if (e.entryId != entryId) e,
    ];
    await _save(entries);
    return entries;
  }

  /// Build the single-entry D4M/AA payload emitted on the `entry` port. Mirrors
  /// the shape the backend produced, so downstream AA nodes are unaffected.
  AaPayload selectAa(InventoryEntry entry) {
    final values = <String>[
      entry.url,
      entry.author,
      entry.workTitle,
      entry.workSelector,
      entry.description,
      DateTime.now().toUtc().toIso8601String(),
    ];
    final cols = [..._columns, 'selected_timestamp'];
    return AaPayload(
      rows: List<String>.filled(cols.length, entry.entryId),
      cols: cols,
      vals: values,
    );
  }

  /// Best-effort title from a location: its final path segment without an
  /// extension.
  static String deriveWorkTitle(String url) {
    var cleaned = url.trim();
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.isEmpty) return 'Untitled';
    var tail = cleaned.split('/').last;
    tail = tail.split('?').first.split('#').first;
    final stem = tail.contains('.') ? tail.substring(0, tail.lastIndexOf('.')) : tail;
    return stem.isEmpty ? 'Untitled' : stem;
  }

  Future<void> _save(List<InventoryEntry> entries) async {
    final file = await resolveFile();
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    final payload = [for (final e in entries) _entryToJson(e)];
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload));
  }

  String _newEntryId() =>
      'entry-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Map<String, dynamic> _entryToJson(InventoryEntry e) => {
        'entryId': e.entryId,
        'url': e.url,
        'author': e.author,
        'workTitle': e.workTitle,
        'workSelector': e.workSelector,
        'description': e.description,
      };

  InventoryEntry _entryFromJson(Map<String, dynamic> json) => InventoryEntry(
        entryId: (json['entryId'] ?? json['entry_id'] ?? _newEntryId()) as String,
        url: (json['url'] ?? '') as String,
        author: (json['author'] ?? '') as String,
        workTitle: (json['workTitle'] ?? json['work_title'] ?? '') as String,
        workSelector:
            (json['workSelector'] ?? json['work_selector'] ?? '') as String,
        description: (json['description'] ?? '') as String,
      );

  /// Convert a legacy backend-written AA catalog into entries.
  List<InventoryEntry> _entriesFromAa(AaPayload aa) {
    final byRow = <String, Map<String, String>>{};
    for (var i = 0; i < aa.cols.length && i < aa.rows.length; i++) {
      byRow.putIfAbsent(aa.rows[i], () => {})[aa.cols[i]] =
          aa.vals[i].toString();
    }
    return [
      for (final entry in byRow.entries)
        InventoryEntry(
          entryId: entry.key,
          url: entry.value['url'] ?? '',
          author: entry.value['author'] ?? '',
          workTitle: entry.value['work_title'] ?? '',
          workSelector: entry.value['work_selector'] ?? '',
          description: entry.value['description'] ?? '',
        ),
    ];
  }
}
