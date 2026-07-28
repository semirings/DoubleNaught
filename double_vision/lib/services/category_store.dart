import '../models/aa_payload.dart';
import 'aa_file.dart';

/// AA-native access to the **category set** at `storage/categories/categories.json`.
///
/// The file is a standard [AaPayload] (sparse `rows`/`cols`/`vals` triples): one
/// row per category (`cat:<id>`), with an attribute triple per column —
/// `label` (the human-readable candidate label a zero-shot model scores),
/// `hypothesis_template` (the `{}`-placeholder template) and `threshold` (the
/// per-category acceptance cutoff). This is the same AA that flows out of the
/// Categories source node into ModelClassifier's `categoryIn`, so the on-disk
/// contract and the on-the-wire contract are identical.
///
/// Mirrors [ModelCatalogStore]'s shape; the file already lives in canonical
/// rcvs form, so loading is a straight [AaFile] read. Uses `dart:io` (via
/// [AaFile]), so this is desktop/mobile only.
class CategoryStore {
  /// Row-key prefix that marks a category row in the AA.
  static const String rowPrefix = 'cat:';

  /// The column holding the candidate label a model scores against.
  static const String labelCol = 'label';

  final AaFile _file;

  /// [overridePath] points the store at a specific file (tests); otherwise it
  /// resolves to `storage/categories/categories.json`.
  CategoryStore({String? overridePath})
    : _file = AaFile('categories/categories.json', overridePath: overridePath);

  /// The category set as a single associative array, normalised to canonical
  /// sparse triples. The on-disk file may be authored in dense (`rows × cols`
  /// matrix) form; downstream (the port bus, the `/classify` wire contract)
  /// expects sparse, so it is expanded here at the single ingress point.
  Future<AaPayload> load() async => (await _file.load()).toSparse();

  /// The candidate labels held in a categories AA, in category (row) order —
  /// the values of the [labelCol] column. Empty when the AA has no `label`
  /// column. This is what supersedes the old comma-separated categories field.
  /// Accepts either the dense or sparse AA shape.
  static List<String> labelsOf(AaPayload aa) => [
    for (final attrs in AaFile.groupByRow(aa.toSparse()).values)
      if ((attrs[labelCol] ?? '').trim().isNotEmpty) attrs[labelCol]!.trim(),
  ];
}
