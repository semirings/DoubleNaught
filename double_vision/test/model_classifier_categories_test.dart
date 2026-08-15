import 'dart:async';

import 'package:double_vision/models/aa_payload.dart';
import 'package:double_vision/models/workflow.dart';
import 'package:double_vision/services/category_store.dart';
import 'package:double_vision/services/classify_api.dart';
import 'package:double_vision/services/infobus/input_port.dart';
import 'package:double_vision/services/infobus/output_port.dart';
import 'package:double_vision/services/model_catalog_store.dart';
import 'package:double_vision/widgets/nodes/implementations/model_classifier_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The categories AA in the **dense** shape of storage/categories/categories.json
/// (rows/cols are the axes; vals is a flattened rows×cols matrix).
const _categoriesAa = AaPayload(
  rows: ['cat:rhetorical', 'cat:periodic', 'cat:primitive'],
  cols: ['label', 'hypothesis_template', 'threshold'],
  vals: [
    'grandiloquent rhetorical speech', 'This passage is {}', 0.75,
    'balanced periodic sentence', 'This passage is {}', 0.80,
    'direct primitive narrative', 'This passage is {}', 0.60,
  ],
);

/// The same category set in canonical sparse-triple form.
const _sparseCategoriesAa = AaPayload(
  rows: [
    'cat:rhetorical', 'cat:rhetorical', 'cat:rhetorical',
    'cat:periodic', 'cat:periodic', 'cat:periodic',
  ],
  cols: [
    'label', 'hypothesis_template', 'threshold',
    'label', 'hypothesis_template', 'threshold',
  ],
  vals: [
    'grandiloquent rhetorical speech', 'This passage is {}', 0.75,
    'balanced periodic sentence', 'This passage is {}', 0.80,
  ],
);

const _expectedLabels = [
  'grandiloquent rhetorical speech',
  'balanced periodic sentence',
  'direct primitive narrative',
];

/// Captures the last `/classify` call so the test can assert what the node sent
/// (in particular, the categories AA) without touching the network.
class _CapturingClassifyApi extends ClassifyApi {
  const _CapturingClassifyApi(this._sink);

  final List<AaPayload?> _sink;

  @override
  Future<AaPayload> classify({
    required String model,
    required String sourceType,
    required List<String> labels,
    required AaPayload documents,
    AaPayload? categories,
    String task = 'zero-shot-classification',
  }) async {
    _sink.add(categories);
    return const AaPayload(
      rows: ['document'],
      cols: ['grandiloquent rhetorical speech'],
      vals: [0.9],
    );
  }
}

void main() {
  test('CategoryStore.labelsOf reads labels from the dense categories shape', () {
    // The exact shape of storage/categories/categories.json.
    expect(CategoryStore.labelsOf(_categoriesAa), _expectedLabels);
  });

  test('CategoryStore.labelsOf reads labels from the sparse shape too', () {
    expect(
      CategoryStore.labelsOf(_sparseCategoriesAa),
      ['grandiloquent rhetorical speech', 'balanced periodic sentence'],
    );
  });

  test('AaPayload.toSparse expands the dense categories matrix row-major', () {
    final sparse = _categoriesAa.toSparse();
    expect(sparse.rows.length, 9);
    expect(sparse.value('label'), 'grandiloquent rhetorical speech');
    // Second category's threshold, addressed structurally.
    expect(CategoryStore.labelsOf(sparse), _expectedLabels);
  });

  testWidgets(
    'categoryIn supplies the classifier labels and rides along to /classify',
    (tester) async {
      final capturedCategories = <AaPayload?>[];
      late InputPort documentsIn;
      late InputPort categoryIn;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelClassifierNode(
              node: const WorkflowNode(
                id: 1,
                type: 'model_classifier',
                x: 0,
                y: 0,
              ),
              // Empty catalog (absent file) so the load is hermetic; the model
              // comes from modelIn instead.
              store: ModelCatalogStore(
                overridePath: '/tmp/dv_nonexistent_models.json',
              ),
              api: _CapturingClassifyApi(capturedCategories),
              modelInput: Stream<String>.value('org/test-model'),
              onInputPort: (p) => documentsIn = p,
              onCategoryPort: (p) => categoryIn = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Before categories arrive, the node prompts for categoryIn.
      expect(
        find.textContaining('Connect categoryIn'),
        findsOneWidget,
      );

      // Feed the categories AA over the port bus, as a Categories node would.
      final categoryOut = OutputPort('categoriesOut');
      categoryIn.connect(categoryOut);
      categoryOut.emit(_categoriesAa);
      await tester.pumpAndSettle();

      // The categories' `label` column is now the node's category set — all
      // three from the dense AA, not just the first.
      expect(find.textContaining('Categories (3)'), findsOneWidget);
      expect(
        find.textContaining('grandiloquent rhetorical speech'),
        findsOneWidget,
      );

      // Feed a document on documentsIn, then classify.
      final textOut = OutputPort('aaOut');
      documentsIn.connect(textOut);
      textOut.emit(
        const AaPayload(
          rows: ['document'],
          cols: ['text'],
          vals: ['A grandiloquent oration.'],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Classify'));
      await tester.pumpAndSettle();

      // The categories AA rode along to the backend client, carrying all three
      // categories (labels recoverable regardless of dense/sparse shape).
      expect(capturedCategories, isNotEmpty);
      expect(capturedCategories.last, isNotNull);
      expect(CategoryStore.labelsOf(capturedCategories.last!), _expectedLabels);

      categoryOut.dispose();
      textOut.dispose();
    },
  );

  testWidgets(
    'documentsIn fed an AA without a text column reports the mis-wire',
    (tester) async {
      late InputPort documentsIn;
      late InputPort categoryIn;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelClassifierNode(
              node: const WorkflowNode(
                id: 1,
                type: 'model_classifier',
                x: 0,
                y: 0,
              ),
              store: ModelCatalogStore(
                overridePath: '/tmp/dv_nonexistent_models.json',
              ),
              modelInput: Stream<String>.value('org/test-model'),
              onInputPort: (p) => documentsIn = p,
              onCategoryPort: (p) => categoryIn = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Categories present…
      final categoryOut = OutputPort('categoriesOut');
      categoryIn.connect(categoryOut);
      categoryOut.emit(_categoriesAa);
      // …but documentsIn is (mis)wired to a Load Model `model` AA — no `text` column.
      final modelOut = OutputPort('model');
      documentsIn.connect(modelOut);
      modelOut.emit(
        const AaPayload(
          rows: ['model:x', 'model:x'],
          cols: ['displayName', 'sourceType'],
          vals: ['ModernBERT', 'huggingface'],
        ),
      );
      await tester.pumpAndSettle();

      // The node names the columns it actually received, so the mis-wire is
      // obvious, and Classify stays disabled.
      expect(find.textContaining("has no 'text' column"), findsOneWidget);
      expect(find.textContaining('displayName'), findsOneWidget);
      final classify = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Classify'),
      );
      expect(classify.onPressed, isNull);

      categoryOut.dispose();
      modelOut.dispose();
    },
  );
}
