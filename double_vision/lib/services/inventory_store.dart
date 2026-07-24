import '../models/aa_payload.dart';
import 'aa_file.dart';
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
  /// AA-at-rest storage for the catalog (`storage/inventory.json`). See [AaFile]
  /// for path resolution (DN_STORAGE_DIR) and the un-sandboxed-write requirement.
  final AaFile _file;

  /// [overridePath] points the catalog at a specific file (tests); otherwise it
  /// resolves to `storage/inventory.json`.
  InventoryStore({String? overridePath})
    : _file = AaFile('inventory.json', overridePath: overridePath);

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
    final decoded = await _file.loadRaw();
    // AA envelope: canonical parallel {rows, cols, vals}.
    if (decoded is Map<String, dynamic> && decoded['cols'] is List) {
      return _entriesFromAa(AaFile.decode(decoded));
    }
    // Legacy shape: a plain JSON array of entry objects. Still read so existing
    // files load; the next mutation rewrites the file as AA.
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>) _entryFromJson(item),
      ];
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
    String entryId,
    InventoryFields fields,
  ) async {
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
    final stem = tail.contains('.')
        ? tail.substring(0, tail.lastIndexOf('.'))
        : tail;
    return stem.isEmpty ? 'Untitled' : stem;
  }

  /// Row-key prefix for a persisted inventory entry in the AA (`entry:<id>`).
  static const String _rowPrefix = 'entry:';

  // Persist as an associative array (rows/cols/vals) — the same AA contract used
  // on the `entry` port and by the model catalog — via the shared AA file.
  Future<void> _save(List<InventoryEntry> entries) =>
      _file.save(_toAa(entries));

  /// Encode the catalog as a single AA: one row `entry:<entryId>` per entry,
  /// one column triple per field.
  AaPayload _toAa(List<InventoryEntry> entries) {
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];
    for (final e in entries) {
      final row = '$_rowPrefix${e.entryId}';
      final values = <String, String>{
        'url': e.url,
        'author': e.author,
        'work_title': e.workTitle,
        'work_selector': e.workSelector,
        'description': e.description,
      };
      for (final col in _columns) {
        rows.add(row);
        cols.add(col);
        vals.add(values[col] ?? '');
      }
    }
    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  String _newEntryId() =>
      'entry-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  InventoryEntry _entryFromJson(Map<String, dynamic> json) => InventoryEntry(
    entryId: (json['entryId'] ?? json['entry_id'] ?? _newEntryId()) as String,
    url: (json['url'] ?? '') as String,
    author: (json['author'] ?? '') as String,
    workTitle: (json['workTitle'] ?? json['work_title'] ?? '') as String,
    workSelector:
        (json['workSelector'] ?? json['work_selector'] ?? '') as String,
    description: (json['description'] ?? '') as String,
  );

  /// Parse an AA catalog into entries, grouping triples by row and preserving
  /// first-appearance order. The `entry:` row prefix is stripped back to the raw
  /// entryId; a row without the prefix (older/backend-written AA) is used as-is.
  List<InventoryEntry> _entriesFromAa(AaPayload aa) {
    final byRow = AaFile.groupByRow(aa);
    return [
      for (final e in byRow.entries)
        InventoryEntry(
          entryId: e.key.startsWith(_rowPrefix)
              ? e.key.substring(_rowPrefix.length)
              : e.key,
          url: e.value['url'] ?? '',
          author: e.value['author'] ?? '',
          workTitle: e.value['work_title'] ?? '',
          workSelector: e.value['work_selector'] ?? '',
          description: e.value['description'] ?? '',
        ),
    ];
  }
}
