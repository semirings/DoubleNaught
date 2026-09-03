import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/save_file_api.dart';
import '../base/base_node_widget.dart';
import '../base/execute_button.dart';
import '../base/io_support.dart';
import '../base/wait_checkbox.dart';
import '../base/wait_gated_execution.dart';

/// Save format for the output file, auto-detected or manually selected.
enum _SaveFormat { parquet, csv, json, jsonl, txt, png, jpg }

/// Save mode: overwrite existing file or append to it.
enum _SaveMode { append, overwrite }

/// Extensions any `_SaveFormat` (or a save dialog's own pick) might carry —
/// stripped from a suggested/typed name before appending the real one, so
/// e.g. a `.csv` pick with Format still on Parquet doesn't double up as
/// `.csv.parquet`. Mirrors the backend's own `_KNOWN_EXTENSIONS` in
/// `save_file.py`.
const _knownExtensions = [
  '.parquet', '.jsonl', '.json', '.csv', '.txt', '.jpeg', '.jpg', '.png',
];

String _stripKnownExtension(String name) {
  final lower = name.toLowerCase();
  for (final ext in _knownExtensions) {
    if (lower.endsWith(ext)) return name.substring(0, name.length - ext.length);
  }
  return name;
}

/// The canvas's only file-writing sink — see `DESIGN.md` → "Save File node".
///
/// One input port, `dataIn` (idx 0), carries an AA. `textIn`/`imageIn` are
/// also still accepted as raw `Stream`s — unchanged wiring from before this
/// node had a Wait/Execute mechanism at all — so a previously-saved workflow
/// wired to either keeps working; the card itself now shows only the one
/// port per the finalized UX spec. No output port: this is a sink.
class SaveFileNode extends BaseNodeWidget {
  /// Called when an edge is dropped on `textIn`.
  final void Function(PortRef source)? onTextConnect;

  /// Called when an edge is dropped on `imageIn`.
  final void Function(PortRef source)? onImageConnect;

  /// Whether `textIn` has an incoming edge.
  final bool textConnected;

  /// Whether `imageIn` has an incoming edge.
  final bool imageConnected;

  /// Text stream wired from upstream nodes.
  final Stream<String>? textInput;

  /// Image bytes stream wired from upstream nodes.
  final Stream<Uint8List>? imageInput;

  /// Backend seam; defaults to the local `/save` + `/save/cancel` endpoints.
  final SaveFileApi? api;

  /// Save-dialog seam. Defaults to `file_selector`'s [getSaveLocation];
  /// overridden by tests, which cannot drive a platform dialog.
  final Future<FileSaveLocation?> Function(String suggestedName)?
      pickSaveLocation;

  const SaveFileNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onInputPort,
    super.inputConnected,
    super.onInputConnect,
    this.onTextConnect,
    this.onImageConnect,
    this.textConnected = false,
    this.imageConnected = false,
    this.textInput,
    this.imageInput,
    this.api,
    this.pickSaveLocation,
  });

  @override
  State<SaveFileNode> createState() => _SaveFileNodeState();
}

class _SaveFileNodeState extends BaseNodeState<SaveFileNode>
    with WaitGatedExecution<SaveFileNode> {
  @override String   get nodeTitle    => 'Save File';
  @override IconData get nodeIcon     => Icons.save_outlined;
  @override double   get nodeWidth    => 320;
  @override String   get workingLabel => 'saving';

  late final SaveFileApi _api;
  late final InputPort _dataIn;
  StreamSubscription<String>?    _textSub;
  StreamSubscription<Uint8List>? _imageSub;

  AaPayload? _incomingAa;
  String?    _incomingText;
  Uint8List? _incomingImage;

  late final TextEditingController _urlController;
  _SaveFormat _selectedFormat = _SaveFormat.parquet;
  _SaveMode _selectedMode = _SaveMode.overwrite;
  SaveFileResponse? _result;

  /// The transport used by the run currently in flight, held so Cancel can
  /// hard-abort it (`UX_UI/GLOBAL_UX_CONTRACT.md` §2) rather than merely
  /// stop watching it. Null whenever nothing is executing.
  http.Client? _execClient;

  /// Bumped on every new run and on cancel. A completed await whose captured
  /// generation no longer matches the current one belongs to a superseded or
  /// cancelled run and must not touch state.
  int _execGen = 0;

  bool get _isUrlValid => IOSupport.isValidUrl(_urlController.text);
  bool get _hasData =>
      _incomingAa != null || _incomingText != null || _incomingImage != null;

  @override
  bool get isReady => _hasData && _isUrlValid;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? const SaveFileApi();
    _dataIn = InputPort('dataIn');
    initInputPort(_dataIn, _onAaData);
    _dataIn.onDisconnected.listen((_) => _dropAa());

    _subscribeText();
    _subscribeImage();

    // Starts EMPTY per spec — no placeholder/default value baked into a new
    // node (UX_UI/GLOBAL_UX_CONTRACT.md §6). A previously saved node
    // restores its own value, same as any other persisted field.
    _urlController = TextEditingController(
      text: widget.initialParams?['url'] ?? '',
    );
    _urlController.addListener(_onUrlEdited);
    _loadFormatFromParams();
    _loadModeFromParams();
  }

  @override
  void didUpdateWidget(SaveFileNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textInput  != widget.textInput)  _subscribeText();
    if (oldWidget.imageInput != widget.imageInput) _subscribeImage();
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlEdited);
    _urlController.dispose();
    _dataIn.dispose();
    _textSub?.cancel();
    _imageSub?.cancel();
    _execClient?.close();
    super.dispose();
  }

  void _subscribeText() {
    _textSub?.cancel();
    _incomingText = null;
    _textSub = widget.textInput?.listen(_onTextData);
  }

  void _subscribeImage() {
    _imageSub?.cancel();
    _incomingImage = null;
    _imageSub = widget.imageInput?.listen(_onImageData);
  }

  void _loadFormatFromParams() {
    if (widget.initialParams?['format'] != null) {
      try {
        _selectedFormat =
            _SaveFormat.values.byName(widget.initialParams!['format']!);
      } catch (_) {
        _selectedFormat = _SaveFormat.json;
      }
    } else {
      _selectedFormat = _autoDetectFormat();
    }
  }

  void _loadModeFromParams() {
    if (widget.initialParams?['saveMode'] != null) {
      try {
        _selectedMode =
            _SaveMode.values.byName(widget.initialParams!['saveMode']!);
      } catch (_) {
        _selectedMode = _SaveMode.overwrite;
      }
    } else {
      _selectedMode = _SaveMode.overwrite;
    }
  }

  /// Drop the retained AA when the `dataIn` wire is cut or re-pointed, so
  /// [isReady] genuinely reflects "is there live data to act on" rather
  /// than lingering on a since-disconnected upstream's last delivery.
  void _dropAa() {
    if (!mounted || (_incomingAa == null && _result == null)) return;
    setState(() {
      _incomingAa = null;
      _result = null;
    });
    setIdle();
  }

  void _onAaData(AaPayload payload) {
    if (!mounted) return;
    setState(() {
      _incomingAa = payload;
      _result = null;
    });
    _updateFormat();
    maybeAutoFire();
  }

  void _onTextData(String text) {
    if (!mounted) return;
    setState(() {
      _incomingText = text;
      _result = null;
    });
    _updateFormat();
    maybeAutoFire();
  }

  void _onImageData(Uint8List bytes) {
    if (!mounted) return;
    setState(() {
      _incomingImage = bytes;
      _result = null;
    });
    _updateFormat();
    maybeAutoFire();
  }

  void _onUrlEdited() {
    setState(() {});
    maybeAutoFire();
  }

  _SaveFormat _autoDetectFormat() {
    // A `json_line` column means the payload is already formatted training
    // lines, not a matrix — writing it as Parquet would bury them.
    if (_incomingAa?.cols.contains('json_line') ?? false) {
      return _SaveFormat.jsonl;
    }
    if (_incomingAa    != null) return _SaveFormat.parquet;
    if (_incomingText  != null) return _SaveFormat.txt;
    if (_incomingImage != null) {
      return _detectImageFormat(_incomingImage!) ?? _SaveFormat.png;
    }
    return _SaveFormat.parquet;
  }

  void _updateFormat() {
    if (widget.initialParams?['format'] == null) {
      setState(() => _selectedFormat = _autoDetectFormat());
    }
  }

  _SaveFormat? _detectImageFormat(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x50) {
      return _SaveFormat.png;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return _SaveFormat.jpg;
    }
    return null;
  }

  /// Switching the format explicitly drops the previous result and, in
  /// reactive mode, re-runs immediately against the format just picked —
  /// mirrors JSONL Formatter's Format Mode dropdown.
  void _onFormatChanged(_SaveFormat format) {
    setState(() {
      _selectedFormat = format;
      _result = null;
    });
    saveParams({'url': _urlController.text.trim(), 'format': format.name, 'saveMode': _selectedMode.name});
    setIdle();
    maybeAutoFire();
  }

  /// Switching the save mode. Disabled when format is PNG/JPEG (image-only formats).
  void _onModeChanged(_SaveMode mode) {
    if (_isImageOnlyFormat(_selectedFormat)) return;
    setState(() {
      _selectedMode = mode;
      _result = null;
    });
    saveParams({'url': _urlController.text.trim(), 'format': _selectedFormat.name, 'saveMode': mode.name});
    setIdle();
    maybeAutoFire();
  }

  bool _isImageOnlyFormat(_SaveFormat format) =>
      format == _SaveFormat.png || format == _SaveFormat.jpg;

  String get _payloadKind => _incomingImage != null
      ? 'image'
      : _incomingText != null
          ? 'text'
          : 'aa';

  bool get _hasJsonlColumn => _incomingAa?.cols.contains('json_line') ?? false;

  @override
  void fire() => _save();

  Future<void> _save() async {
    if (!isReady || status == NodeStatus.working) return;
    final gen = ++_execGen;
    setWorking();

    final owns = _api.client == null;
    final client = _api.client ?? http.Client();
    _execClient = client;
    final api = owns ? SaveFileApi(baseUrl: _api.baseUrl, client: client) : _api;

    final url = _urlController.text.trim();
    final imageBase64 =
        _incomingImage != null ? base64Encode(_incomingImage!) : null;

    try {
      final response = await api.save(
        aa: _incomingAa,
        text: _incomingText,
        imageBase64: imageBase64,
        url: url,
        format: _selectedFormat.name,
        append: _selectedMode == _SaveMode.append,
      );
      if (gen != _execGen || !mounted) return;

      setState(() => _result = response);
      saveParams({'url': url, 'format': _selectedFormat.name});
      setComplete(detail: response.message);
    } catch (e) {
      if (gen != _execGen || !mounted) return;
      setError(e);
    } finally {
      if (gen == _execGen) _execClient = null;
      if (owns) client.close();
    }
  }

  /// Execute button's `onPressed` while [NodeStatus.working] — the button
  /// renders as Cancel in that state (`ExecuteButton.executing`). Hard
  /// abort, synchronously: state flips to idle right here, not after any
  /// awaited step notices a flag. `_execGen` guards the in-flight run's own
  /// awaits against then clobbering that idle state if the request still
  /// resolves in the background.
  ///
  /// Save File specific: the write itself can't be interrupted mid-flight
  /// (the backend's threadpool call keeps running once dispatched, unaware
  /// the client gave up), so a plain abort alone can leave a fully-written
  /// file behind despite the UI showing idle. [_cleanupAfterCancel] is the
  /// best-effort follow-up that actually removes it, per this node's Cancel
  /// spec.
  void _onCancelPressed() {
    if (status != NodeStatus.working) return;
    _execGen++;
    _execClient?.close();
    _execClient = null;
    setIdle();
    _cleanupAfterCancel();
  }

  Future<void> _cleanupAfterCancel() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await _api.cancelCleanup(
      url: url,
      format: _selectedFormat.name,
      payloadKind: _payloadKind,
      hasJsonlColumn: _hasJsonlColumn,
    );
  }

  // ── Save-location dialog ────────────────────────────────────────────────

  /// Open the native save dialog to fill in the URL field.
  ///
  /// The backend is still what writes the file, so this only captures a
  /// destination. The dialog's own suggested name/extension also picks the
  /// Format — the backend normalises any mismatch between a picked/typed
  /// extension and the selected Format itself (see `save_file.py`'s
  /// `_strip_known_extension`), so nothing needs stripping client-side
  /// beyond what's needed to suggest a sane default name.
  Future<void> _onPickLocationPressed() async {
    final current = _urlController.text.trim();
    final currentBase = current.isEmpty
        ? 'export'
        : _stripKnownExtension(
            Uri.tryParse(current)?.pathSegments.lastOrNull ?? 'export');
    final suggested = '$currentBase.${_extensionOf(_selectedFormat)}';

    final location =
        await (widget.pickSaveLocation ?? _openNativeDialog)(suggested);
    if (location == null || !mounted) return;

    final format = _formatOfPath(location.path) ?? _selectedFormat;
    final url = IOSupport.pathToFileUri(location.path);

    setState(() {
      _urlController.text = url;
      _selectedFormat = format;
      _result = null;
    });
    saveParams({'url': url, 'format': format.name});
    setIdle();
    maybeAutoFire();
  }

  static Future<FileSaveLocation?> _openNativeDialog(String suggestedName) =>
      getSaveLocation(suggestedName: suggestedName);

  /// The on-disk extension for [format] — the same suffix the backend
  /// appends.
  static String _extensionOf(_SaveFormat format) => format.name;

  /// The format implied by [path]'s extension, or null when unrecognised.
  static _SaveFormat? _formatOfPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = path.substring(dot + 1).toLowerCase();
    for (final f in _SaveFormat.values) {
      if (_extensionOf(f) == ext) return f;
    }
    return ext == 'jpeg' ? _SaveFormat.jpg : null;
  }

  String _formatLabel(_SaveFormat format) => switch (format) {
        _SaveFormat.parquet => 'Parquet',
        _SaveFormat.json    => 'JSON',
        _SaveFormat.jsonl   => 'JSONL',
        _SaveFormat.csv     => 'CSV',
        _SaveFormat.txt     => 'Text',
        _SaveFormat.png     => 'PNG',
        _SaveFormat.jpg     => 'JPEG',
      };

  /// Build radio buttons for Append/Overwrite save mode.
  /// Append is disabled for image-only formats (PNG, JPEG).
  Widget _buildSaveModeRadios(ThemeData theme, bool busy) {
    final isImageOnly = _isImageOnlyFormat(_selectedFormat);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Save Mode',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            // Append option
            Expanded(
              child: _buildRadioOption(
                label: 'Append',
                value: _SaveMode.append,
                enabled: !isImageOnly && !busy,
                onChanged: _onModeChanged,
              ),
            ),
            const SizedBox(width: 16),
            // Overwrite option
            Expanded(
              child: _buildRadioOption(
                label: 'Overwrite',
                value: _SaveMode.overwrite,
                enabled: !busy,
                onChanged: _onModeChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Build a single radio button option.
  Widget _buildRadioOption({
    required String label,
    required _SaveMode value,
    required bool enabled,
    required Function(_SaveMode) onChanged,
  }) {
    final isSelected = _selectedMode == value;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final disabledColor = scheme.onSurfaceVariant.withValues(alpha: 0.38);
    final activeColor = isSelected ? scheme.primary : scheme.onSurfaceVariant;

    return GestureDetector(
      onTap: enabled ? () => onChanged(value) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled ? activeColor : disabledColor,
                width: 2,
              ),
            ),
            child: isSelected
                ? Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: enabled ? scheme.primary : disabledColor,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: enabled ? activeColor : disabledColor,
            ),
          ),
        ],
      ),
    );
  }

  // ── Ports ────────────────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        singleInputConnector(label: 'dataIn'),
      ];

  // ── Body ─────────────────────────────────────────────────────────────────

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = status == NodeStatus.working;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        IOSupport.field(
          controller: _urlController,
          enabled: !busy,
          // Web has no real paths to hand the backend, so the field is the
          // only way in there.
          trailing: kIsWeb
              ? null
              : IconButton(
                  onPressed: busy ? null : _onPickLocationPressed,
                  icon: const Icon(Icons.save_as_outlined, size: 18),
                  tooltip: 'Choose location…',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
        ),
        const SizedBox(height: 10),
        DropdownMenu<_SaveFormat>(
          enableSearch: false,
          expandedInsets: EdgeInsets.zero,
          enabled: !busy,
          label: const Text('Format'),
          initialSelection: _selectedFormat,
          onSelected: (f) => f == null ? null : _onFormatChanged(f),
          dropdownMenuEntries: [
            for (final f in _SaveFormat.values)
              DropdownMenuEntry(value: f, label: _formatLabel(f)),
          ],
        ),
        const SizedBox(height: 12),
        _buildSaveModeRadios(theme, busy),
        const SizedBox(height: 10),
        WaitCheckbox(checked: wait, onChanged: onWaitChanged, locked: busy),
        const SizedBox(height: 6),
        ExecuteButton(
          enabled: isReady && !busy,
          executing: busy,
          onPressed: busy ? _onCancelPressed : onExecutePressed,
        ),
        const SizedBox(height: 8),
        statusRow(),
        if (_result case final result?) ...[
          const SizedBox(height: 6),
          Text(
            '${result.bytesWritten} bytes · ${result.filePath.split('/').last}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
