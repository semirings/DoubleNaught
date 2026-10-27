import 'package:flutter/material.dart';

/// Shared epochs/rank/resolution fields and validation for the two image
/// LoRA trainer nodes — Image LoRA Trainer (local, mflux) and Image LoRA
/// Cloud Trainer (cloud, ai-toolkit). Same knobs, same bounds, same field layout in both,
/// so this is the one place to fix e.g. "is 770 a valid resolution" for
/// both nodes at once.
///
/// What's NOT shared, deliberately: quantize (different type and meaning on
/// each backend), progress reporting (local streams real step/total; cloud
/// only gets coarse job state), and mid-run checkpoint export (local-only —
/// the cloud container uploads its adapter once, at the end). Those differ
/// enough between the two backends that the nodes stay separate rather than
/// being merged into one with a local/cloud toggle; each widget still owns
/// its own `_persist`, status display and API client.
mixin TrainingFieldsMixin<T extends StatefulWidget> on State<T> {
  late final TextEditingController epochsController;
  late final TextEditingController rankController;
  late final TextEditingController resolutionController;

  void initTrainingFields(
    Map<String, String>? params, {
    String defaultEpochs = '20',
    String defaultRank = '16',
    String defaultResolution = '768',
  }) {
    epochsController =
        TextEditingController(text: params?['epochs'] ?? defaultEpochs);
    rankController = TextEditingController(text: params?['rank'] ?? defaultRank);
    resolutionController =
        TextEditingController(text: params?['resolution'] ?? defaultResolution);
  }

  void disposeTrainingFields() {
    epochsController.dispose();
    rankController.dispose();
    resolutionController.dispose();
  }

  int? positiveInt(TextEditingController c) {
    final n = int.tryParse(c.text.trim());
    return (n != null && n >= 1) ? n : null;
  }

  int? get epochsValue => positiveInt(epochsController);

  int? get rankValue {
    final n = positiveInt(rankController);
    return (n != null && n <= 128) ? n : null;
  }

  int? get resolutionValue {
    final n = positiveInt(resolutionController);
    return (n != null && n >= 256 && n <= 1536 && n % 16 == 0) ? n : null;
  }

  /// The Epochs/Rank/Resolution row. [epochsKey]/[rankKey]/[resolutionKey]
  /// stay caller-supplied (not hardcoded here) so each node keeps its own
  /// `ValueKey`s — existing widget tests depend on the exact keys per node
  /// (`imgtrain-*` vs `vtrain-*`).
  Widget trainingFieldsRow({
    required bool busy,
    required VoidCallback onAnyChanged,
    required String epochsKey,
    required String rankKey,
    required String resolutionKey,
  }) {
    Widget numField(String label, TextEditingController c, String key,
            String bad, bool ok) =>
        Expanded(
          child: TextField(
            key: ValueKey(key),
            controller: c,
            enabled: !busy,
            keyboardType: TextInputType.number,
            onChanged: (_) => onAnyChanged(),
            decoration: InputDecoration(
              labelText: label,
              errorText: ok ? null : bad,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        numField('Epochs', epochsController, epochsKey, '≥ 1', epochsValue != null),
        const SizedBox(width: 8),
        numField('Rank', rankController, rankKey, '1 – 128', rankValue != null),
        const SizedBox(width: 8),
        numField('Resolution', resolutionController, resolutionKey, '×16',
            resolutionValue != null),
      ],
    );
  }
}
