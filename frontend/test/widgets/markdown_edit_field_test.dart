import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:double_vision/widgets/markdown_edit_field.dart';

Widget _host(TextEditingController c, {bool startInPreview = false}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: MarkdownEditField(
              controller: c, hintText: 'hint', startInPreview: startInPreview),
        ),
      ),
    );

void main() {
  testWidgets('starts in edit mode by default', (t) async {
    final c = TextEditingController(text: '# Title');
    await t.pumpWidget(_host(c));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
  });

  testWidgets('Preview renders markdown and leaves the text untouched',
      (t) async {
    const src = '# Title\n\nuse text_tag and **bold**';
    final c = TextEditingController(text: src);
    await t.pumpWidget(_host(c));
    await t.tap(find.text('Preview'));
    await t.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(c.text, src);
  });

  testWidgets('round trip: edit after preview keeps typed text', (t) async {
    final c = TextEditingController(text: 'one');
    await t.pumpWidget(_host(c));
    await t.tap(find.text('Preview'));
    await t.pumpAndSettle();
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'one two');
    expect(c.text, 'one two');
  });

  testWidgets('double-tap on the preview returns to edit', (t) async {
    final c = TextEditingController(text: 'x');
    await t.pumpWidget(_host(c, startInPreview: true));
    expect(find.byType(MarkdownBody), findsOneWidget);
    final p = find.byKey(const ValueKey('md-preview'));
    await t.tap(p);
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(p);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('empty text never starts in preview', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(_host(c, startInPreview: true));
    expect(find.byType(TextField), findsOneWidget);
  });
}
