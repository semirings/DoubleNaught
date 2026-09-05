import 'dart:convert';
import 'dart:io';

import '../config/env.dart';
import '../models/aa_payload.dart';

/// Shared load/save for an associative array persisted as a single JSON file —
/// the one implementation behind every AA-at-rest catalog (models, inventory,
/// …), so path resolution, empty/absent handling, and pretty-printing live in
/// exactly one place.
///
/// On disk the file is the canonical **AssociativeArrayTable** shape
/// (`AAschema/schemas/rcvs.json`) — parallel `{ "rows", "cols", "vals" }`. This
/// is the single AA JSON contract shared by D4M.dart, D4M.py, and the
/// DoubleTouch backend, so every party round-trips the identical JSON.
///
/// Files resolve under the repo `storage/` tree by default, overridable per run
/// with `--dart-define=DN_STORAGE_DIR=/path` (run.sh DV passes it). Uses
/// `dart:io`, so this is desktop/mobile only.
class AaFile {
  static String get _storageDir => getEnvVar(
    'DN_STORAGE_DIR',
    defaultValue: '/Users/gcr/populi.Wk/DoubleNaught/storage',
  );

  /// Filename within the storage directory (e.g. `models_aa.json`).
  final String fileName;

  /// Full path override, for tests or a deliberate location. When null the file
  /// resolves to `<storageDir>/<fileName>`.
  final String? overridePath;

  File? _cached;

  AaFile(this.fileName, {this.overridePath});

  /// The backing file, resolved once and cached.
  Future<File> resolveFile() async =>
      _cached ??= File(overridePath ?? '$_storageDir/$fileName');

  /// Read the file as an associative array. Absent, empty, or non-AA files yield
  /// an empty [AaPayload] rather than throwing.
  Future<AaPayload> load() async => decode(await loadRaw());

  /// Decode a parallel AA envelope; anything else → empty AA.
  ///
  /// Accepts both plural keys (`rows`/`cols`/`vals`) and singular variants
  /// (`row`/`col`/`val`) produced by D4M.py's `to_json()`.
  static AaPayload decode(Object? json) {
    if (json is! Map<String, dynamic>) return const AaPayload();
    // Normalise singular → plural so fromJson always sees consistent keys.
    final m = <String, dynamic>{
      'rows': json['rows'] ?? json['row'],
      'cols': json['cols'] ?? json['col'],
      'vals': json['vals'] ?? json['val'],
    };
    if (m['cols'] is! List) return const AaPayload();
    return AaPayload.fromJson(m);
  }

  /// Read and JSON-decode the raw file contents, or null when absent/empty. For
  /// callers that must also tolerate a non-AA legacy shape (e.g. inventory's old
  /// plain-array file) before deciding how to parse.
  Future<Object?> loadRaw() async {
    final file = await resolveFile();
    if (!await file.exists()) return null;
    final raw = (await file.readAsString()).trim();
    if (raw.isEmpty) return null;
    return jsonDecode(raw);
  }

  /// Persist [aa] in canonical `{rows, cols, vals}` form, pretty printed,
  /// creating the directory if needed.
  Future<void> save(AaPayload aa) async {
    final file = await resolveFile();
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(aa.toJson()),
    );
  }

  /// Group an AA's triples by row into `{row: {col: val}}`. The returned map is
  /// a `LinkedHashMap`, so iterating it yields rows in first-appearance order.
  static Map<String, Map<String, String>> groupByRow(AaPayload aa) {
    final byRow = <String, Map<String, String>>{};
    final n = aa.cols.length < aa.rows.length ? aa.cols.length : aa.rows.length;
    for (var i = 0; i < n; i++) {
      (byRow[aa.rows[i]] ??= <String, String>{})[aa.cols[i]] = aa.vals[i]
          .toString();
    }
    return byRow;
  }
}
