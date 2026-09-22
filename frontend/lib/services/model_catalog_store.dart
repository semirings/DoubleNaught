import 'package:aa_preview_table/aa_preview_table.dart';
import 'aa_file.dart';

/// One model definition — a single Row in the model-catalog associative array
/// (row key `model:<modelId>`), with one triple per attribute column.
class ModelEntry {
  final String modelId;
  final String displayName;

  /// `local` | `huggingface` | `remote_url`.
  final String sourceType;
  final String pathOrUrl;

  /// `safetensors` | `gguf` | `mlx` | `onnx`.
  final String format;

  /// `zero-shot-classification` | `text-generation` | etc.
  final String task;

  const ModelEntry({
    required this.modelId,
    required this.displayName,
    this.sourceType = '',
    this.pathOrUrl = '',
    this.format = '',
    this.task = '',
  });
}

/// AA-native persistence for the **model catalog** at `storage/models_rcvs.json`.
///
/// The file is a standard [AaPayload] (sparse `rows`/`cols`/`vals` triples): each
/// model is a row `model:<modelId>`, and each attribute (`displayName`,
/// `sourceType`, `pathOrUrl`, `format`, `task`) is a column triple on that row.
/// Loading, slicing, updating and saving all go through the Dart AA class, so the
/// on-disk contract is identical to what flows between nodes.
///
/// Mirrors the `DN_STORAGE_DIR` convention (repo `storage/`, `dart:io` — so this
/// is desktop/mobile only).
class ModelCatalogStore {
  /// Row-key prefix that marks a catalog model row in the AA.
  static const String rowPrefix = 'model:';

  /// Attribute columns, in canonical order.
  static const List<String> attributes = [
    'displayName',
    'sourceType',
    'pathOrUrl',
    'format',
    'task',
  ];

  final AaFile _file;

  /// [overridePath] points the catalog at a specific file (tests); otherwise it
  /// resolves to `storage/models_rcvs.json`.
  ModelCatalogStore({String? overridePath})
    : _file = AaFile('models_rcvs.json', overridePath: overridePath);

  /// The catalog as structured entries (grouped by AA row).
  Future<List<ModelEntry>> models() async => fromAa(await _file.load());

  /// Group an AA's triples into one [ModelEntry] per `model:` row, preserving
  /// first-appearance order.
  static List<ModelEntry> fromAa(AaPayload aa) {
    final byRow = AaFile.groupByRow(aa);
    return [
      for (final e in byRow.entries)
        if (e.key.startsWith(rowPrefix))
          ModelEntry(
            modelId: e.key.substring(rowPrefix.length),
            displayName:
                e.value['displayName'] ?? e.key.substring(rowPrefix.length),
            sourceType: e.value['sourceType'] ?? '',
            pathOrUrl: e.value['pathOrUrl'] ?? '',
            format: e.value['format'] ?? '',
            task: e.value['task'] ?? '',
          ),
    ];
  }

  /// Encode entries back into a single associative array.
  static AaPayload toAa(List<ModelEntry> models) {
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];
    for (final m in models) {
      final row = '$rowPrefix${m.modelId}';
      final values = <String, String>{
        'displayName': m.displayName,
        'sourceType': m.sourceType,
        'pathOrUrl': m.pathOrUrl,
        'format': m.format,
        'task': m.task,
      };
      for (final col in attributes) {
        rows.add(row);
        cols.add(col);
        vals.add(values[col] ?? '');
      }
    }
    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  /// The single-model AA slice (row `model:<id>`) emitted by LoadModel.
  static AaPayload sliceModel(ModelEntry model) => toAa([model]);

  /// Persist the full catalog as AA JSON.
  Future<void> save(List<ModelEntry> models) => _file.save(toAa(models));

  /// Insert or replace [entry] (matched by `modelId`); returns the new catalog.
  Future<List<ModelEntry>> upsert(ModelEntry entry) async {
    final list = [...await models()];
    final i = list.indexWhere((m) => m.modelId == entry.modelId);
    if (i >= 0) {
      list[i] = entry;
    } else {
      list.add(entry);
    }
    await save(list);
    return list;
  }
}
