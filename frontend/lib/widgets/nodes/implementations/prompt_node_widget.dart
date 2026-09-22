import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aa_preview_table/aa_preview_table.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/infobus/output_port.dart';
import '../../focus_panel.dart' show FocusContent;
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';
import '../base/output_connector.dart';

/// Where an ingested file's text lands relative to what is already composed.
enum PromptInsert { append, prepend }

/// A prompt-authoring processing node — see `DESIGN.md` → "Prompt".
///
/// Composes free text (a prompt, a code snippet, an instruction block) and
/// publishes it on `promptOutput` as an AA. An AA arriving on `fileInput` is
/// flattened to text and merged into the same editable state, so an ingested
/// file is immediately editable rather than a fixed prefix.
///
/// ## One document, two surfaces
///
/// The text has a single owner: [_PromptNodeWidgetState._prompt]. The inline
/// body field attaches to it, and the expanded [PromptCanvasEditor] in the Focus
/// Panel attaches to the *same* controller, so the two surfaces cannot drift —
/// there is no mirroring step to get wrong.
///
/// ## Port contract
///
/// * `fileInput` (input idx 0) — AA carrying text/code
/// * `promptOutput` (output idx 0) — AA: row `prompt:<nodeId>`, cols `prompt`
///   and `char_count`
class PromptNodeWidget extends BaseNodeWidget {
  static const double _width = 320;

  /// Pushes the expanded editor into the Focus Panel as this node's tab.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Opens (and selects) this node's Focus Panel tab.
  final void Function(int nodeId)? onView;

  /// Coalescing window for `promptOutput`. A burst of keystrokes emits once the
  /// typing settles rather than one AA per character.
  final Duration emitDebounce;

  const PromptNodeWidget({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.onOutputPort,
    super.inputConnected,
    super.onInputConnect,
    super.connectedOutputs,
    this.onContent,
    this.onView,
    this.emitDebounce = const Duration(milliseconds: 300),
  });

  /// The text carried by [aa], flattened for prompt composition.
  ///
  /// Prefers the cells of a text-bearing column (`text`, `prompt`, `content`,
  /// `val`) when the AA has one; otherwise takes every string value. Values are
  /// joined by newline in payload order, and numeric cells are skipped — a
  /// chunk's `position` or `token_count` is metadata, not prose.
  /// Delegates to [AaPayload.flattenText] — the Remote Service Node reads its
  /// `dataInput` through the same helper, so "what counts as the text of an AA"
  /// is defined once.
  static String extractText(AaPayload aa) => aa.flattenText();

  @override
  State<PromptNodeWidget> createState() => _PromptNodeWidgetState();
}

class _PromptNodeWidgetState extends BaseNodeState<PromptNodeWidget> {
  @override String   get nodeTitle => 'Prompt';
  @override IconData get nodeIcon  => Icons.edit_note_outlined;
  @override double   get nodeWidth => PromptNodeWidget._width;

  /// The single source of truth for the prompt text, shared with the expanded
  /// editor in the Focus Panel.
  late final TextEditingController _prompt;

  final InputPort  _fileIn = InputPort('fileInput');
  final OutputPort _out    = OutputPort('promptOutput');

  PromptInsert _insert = PromptInsert.append;
  Timer? _debounce;
  int _ingested = 0;

  /// Whether the expanded editor tab exists yet. Only **Expand Editor** creates
  /// it; without this guard the first debounced emit would push content and the
  /// canvas would throw the Focus Panel open on the user's first keystroke.
  bool _editorMounted = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(
      text: widget.initialParams?['prompt'] ?? '',
    );
    _prompt.addListener(_onTextChanged);

    final saved = widget.initialParams?['insert'];
    if (saved != null) {
      _insert = PromptInsert.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => PromptInsert.append,
      );
    }

    initInputPort(_fileIn, _onFile);
    initOutputPort(_out);

    // Publish restored text so a reopened workflow feeds downstream nodes
    // without the user having to touch the editor. Deferred past the first
    // frame: emitting during initState would reach consumers mid-build.
    if (_prompt.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emit();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _prompt.removeListener(_onTextChanged);
    _prompt.dispose();
    _fileIn.dispose();
    _out.dispose();
    super.dispose();
  }

  // ── State → downstream ───────────────────────────────────────────────────

  void _onTextChanged() {
    if (!mounted) return;
    // Rebuild for the char counter; republish once the burst settles.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(widget.emitDebounce, () {
      if (mounted) _emit();
    });
  }

  void _emit() {
    final text = _prompt.text;
    _out.emit(AaPayload(
      rows: ['prompt:${widget.node.id}', 'prompt:${widget.node.id}'],
      cols: const ['prompt', 'char_count'],
      vals: [text, text.length],
    ));
    saveParams({'prompt': text, 'insert': _insert.name});
    _republishEditor();
  }

  /// Refresh the Focus Panel tab's subtitle. The editor itself needs no push —
  /// it holds the live controller — but the subtitle is a snapshot.
  ///
  /// No-op until the tab exists, so state changes never conjure the panel.
  void _republishEditor() {
    if (!_editorMounted) return;
    widget.onContent?.call(
      widget.node.id,
      FocusContent.promptEditor(_prompt, subtitle: _summary),
    );
  }

  String get _summary {
    final chars = _prompt.text.length;
    final lines = _prompt.text.isEmpty ? 0 : _prompt.text.split('\n').length;
    final ingested = _ingested == 0 ? '' : ' · $_ingested ingested';
    return '$lines lines · $chars chars$ingested';
  }

  // ── fileInput ingest ─────────────────────────────────────────────────────

  void _onFile(AaPayload payload) {
    if (!mounted) return;
    final incoming = PromptNodeWidget.extractText(payload);
    if (incoming.isEmpty) return;

    final existing = _prompt.text;
    final merged = existing.isEmpty
        ? incoming
        : switch (_insert) {
            PromptInsert.append  => '$existing\n\n$incoming',
            PromptInsert.prepend => '$incoming\n\n$existing',
          };

    setState(() => _ingested++);
    // Assigning .text moves the caret to the end, which is what you want after
    // an append; the listener handles the rebuild and the debounced emit.
    _prompt.text = merged;
  }

  void _setInsert(PromptInsert mode) {
    setState(() => _insert = mode);
    saveParams({'prompt': _prompt.text, 'insert': mode.name});
  }

  void _openEditor() {
    _editorMounted = true;
    _republishEditor();
    widget.onView?.call(widget.node.id);
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'fileInput',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
      ];

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'promptOutput',
          idx: 0,
          active: _prompt.text.isNotEmpty ||
              widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        Row(
          children: [
            Expanded(
              child: Text(
                _summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            PopupMenuButton<PromptInsert>(
              tooltip: 'Where ingested file text lands',
              initialValue: _insert,
              onSelected: _setInsert,
              padding: EdgeInsets.zero,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: PromptInsert.append,
                  child: Text('Ingest: append'),
                ),
                PopupMenuItem(
                  value: PromptInsert.prepend,
                  child: Text('Ingest: prepend'),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _insert.name,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ),
            IconButton(
              onPressed: _openEditor,
              icon: const Icon(Icons.open_in_full, size: 16),
              tooltip: 'Expand Editor',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _prompt,
          minLines: 4,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'Compose a prompt…',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
      ],
    );
  }
}
