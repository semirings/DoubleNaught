/// A D4M/AA associative array in sparse triple form — the data-contract object
/// that flows between processing nodes (see `DESIGN.md` → "Data-contract
/// boundary": processing nodes are AA-in → AA-out).
///
/// [rows], [cols] and [vals] are parallel lists: entry *k* is the triple
/// `(rows[k], cols[k], vals[k])`. Values are strings for most columns; some
/// columns are inherently numeric (e.g. ChunkNode's `position` / `token_count`)
/// and carry ints — hence [vals] is `List<Object>`. This matches the
/// `(row, col, val)` shape D4M's `aa.find()` yields on the Python side, so a
/// payload round-trips cleanly to/from a real associative array.
///
/// Mirrors the backend `AssocArray` model (`double_touch/models.py`); the
/// envelope keys (`rows`/`cols`/`vals`) are camelCase-clean on the wire.
library;

class AaPayload {
  final List<String> rows;
  final List<String> cols;

  /// Parallel to [cols]; each entry is a `String` or an `int` (JSON numbers
  /// decode to `int` here since every numeric AA column is integral).
  final List<Object> vals;

  const AaPayload({
    this.rows = const [],
    this.cols = const [],
    this.vals = const [],
  });

  factory AaPayload.fromJson(Map<String, dynamic> json) => AaPayload(
    rows: [for (final r in (json['rows'] as List? ?? const [])) r as String],
    cols: [for (final c in (json['cols'] as List? ?? const [])) c as String],
    vals: [for (final v in (json['vals'] as List? ?? const [])) v as Object],
  );

  /// A single-triple status payload — e.g. a node reporting `thinking` / `idle`.
  /// Read it back with `value('status')`.
  factory AaPayload.status(String state) =>
      AaPayload(rows: const ['status'], cols: const ['status'], vals: [state]);

  Map<String, dynamic> toJson() => {'rows': rows, 'cols': cols, 'vals': vals};

  /// Number of stored triples.
  int get length => cols.length;

  /// The distinct row keys, in first-appearance order. For a multi-row AA (e.g.
  /// ChunkNode passages) this is the chunk count.
  List<String> distinctRows() {
    final seen = <String>{};
    final out = <String>[];
    for (final r in rows) {
      if (seen.add(r)) out.add(r);
    }
    return out;
  }

  /// The value stored under column [col] (first match) as a string, or null if
  /// absent. Convenience for single-row AAs (URLNode / FetchNode payloads).
  String? value(String col) {
    final i = cols.indexOf(col);
    return i < 0 ? null : vals[i].toString();
  }

  /// The value stored under column [col] (first match) as an int, or null if
  /// absent or non-numeric.
  int? intValue(String col) {
    final i = cols.indexOf(col);
    if (i < 0) return null;
    final v = vals[i];
    return v is int ? v : int.tryParse(v.toString());
  }
}
