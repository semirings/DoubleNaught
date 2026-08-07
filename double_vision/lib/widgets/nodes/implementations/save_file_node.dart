import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../../../services/save_file_api.dart';
import '../base/base_node_widget.dart';
import '../base/input_connector.dart';

/// Save format for the output file, auto-detected or manually selected.
enum _SaveFormat { parquet, csv, json, txt, png, jpg }

/// A workflow sink node that saves incoming port data (AA, text, or image)
/// to local disk with format selection and save-location controls.
///
/// Provides three input ports:
/// - `aaIn`    (idx 0): Associative Array (D4M dict) on the AA port bus
/// - `textIn`  (idx 1): Plain text stream from upstream
/// - `imageIn` (idx 2): Raw image bytes stream from upstream
///
/// The node includes file path text input, a "Browse..." button for path
/// selection, a format dropdown, a "Save / Export" button, and status display.
class SaveFileNode extends BaseNodeWidget {
  // aaIn (AA, idx 0) — the "canonical" input uses base's inputConnected/onInputConnect
  // onInputPort used for aaIn registration

  /// Whether `textIn` has an incoming edge.
  final bool textConnected;

  /// Whether `imageIn` has an incoming edge.
  final bool imageConnected;

  /// Called when an edge is dropped on `textIn`.
  final void Function(PortRef source)? onTextConnect;

  /// Called when an edge is dropped on `imageIn`.
  final void Function(PortRef source)? onImageConnect;

  /// Text stream wired from upstream nodes.
  final Stream<String>? textInput;

  /// Image bytes stream wired from upstream nodes.
  final Stream<Uint8List>? imageInput;

  const SaveFileNode({
    super.key,
    required super.node,
    bool aaConnected = false,
    void Function(PortRef source)? onAaConnect,
    super.onInputPort,   // registers aaIn
    this.textConnected = false,
    this.imageConnected = false,
    this.onTextConnect,
    this.onImageConnect,
    this.textInput,
    this.imageInput,
    super.initialParams,
    super.onParams,
  }) : super(inputConnected: aaConnected, onInputConnect: onAaConnect);

  @override
  State<SaveFileNode> createState() => _SaveFileNodeState();
}

class _SaveFileNodeState extends BaseNodeState<SaveFileNode> {
  @override String   get nodeTitle => 'Save File';
  @override IconData get nodeIcon  => Icons.save_outlined;

  late final InputPort _aaIn;
  StreamSubscription<String>?    _textSub;
  StreamSubscription<Uint8List>? _imageSub;

  AaPayload? _incomingAa;
  String?    _incomingText;
  Uint8List? _incomingImage;

  late TextEditingController _filePathController;
  _SaveFormat _selectedFormat = _SaveFormat.parquet;
  String _statusMessage = 'Ready to save';
  bool   _statusIsError = false;
  bool   _isSaving      = false;

  final _api = const SaveFileApi();

  @override
  void initState() {
    super.initState();
    _aaIn = InputPort('aaIn');
    initInputPort(_aaIn, _onAaData);

    _subscribeText();
    _subscribeImage();

    _filePathController = TextEditingController(
      text: widget.initialParams?['filePath'] ?? 'storage/out/export',
    );
    _loadFormatFromParams();
  }

  @override
  void didUpdateWidget(SaveFileNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textInput  != widget.textInput)  _subscribeText();
    if (oldWidget.imageInput != widget.imageInput) _subscribeImage();
  }

  @override
  void dispose() {
    _filePathController.dispose();
    _aaIn.dispose();
    _textSub?.cancel();
    _imageSub?.cancel();
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

  void _onAaData(AaPayload payload) {
    if (!mounted) return;
    setState(() => _incomingAa = payload);
    _updateFormat();
  }

  void _onTextData(String text) {
    if (!mounted) return;
    setState(() => _incomingText = text);
    _updateFormat();
  }

  void _onImageData(Uint8List bytes) {
    if (!mounted) return;
    setState(() => _incomingImage = bytes);
    _updateFormat();
  }

  _SaveFormat _autoDetectFormat() {
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

  Future<void> _onSavePressed() async {
    setState(() => _isSaving = true);
    try {
      var filename = _filePathController.text.trim();
      if (filename.isEmpty) {
        setState(() {
          _statusMessage = 'Error: Enter a file path';
          _statusIsError = true;
        });
        return;
      }

      // Strip "storage/out/" prefix if present (backend adds it automatically)
      if (filename.startsWith('storage/out/')) {
        filename = filename.substring('storage/out/'.length);
      }

      if (_incomingAa == null && _incomingText == null && _incomingImage == null) {
        setState(() {
          _statusMessage = 'Error: No data to save';
          _statusIsError = true;
        });
        return;
      }

      // Convert image to base64 if present
      String? imageBase64;
      if (_incomingImage != null) {
        imageBase64 = base64Encode(_incomingImage!);
      }

      final response = await _api.save(
        aa: _incomingAa,
        text: _incomingText,
        imageBase64: imageBase64,
        filename: filename,
        format: _selectedFormat.name,
      );

      saveParams({'filePath': filename, 'format': _selectedFormat.name});

      setState(() {
        _statusMessage = response.message;
        _statusIsError = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: ${e.toString()}';
        _statusIsError = true;
      });
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Future<void> _onBrowsePressed() async {
    // Note: Browse is disabled on the backend since the backend controls paths.
    // Show a hint to the user instead.
    setState(() {
      _statusMessage = 'Files are saved to backend storage/out/ directory';
      _statusIsError = false;
    });
  }

  String _formatLabel(_SaveFormat format) => switch (format) {
        _SaveFormat.parquet => 'Parquet',
        _SaveFormat.json    => 'JSON',
        _SaveFormat.csv     => 'CSV',
        _SaveFormat.txt     => 'Text',
        _SaveFormat.png     => 'PNG',
        _SaveFormat.jpg     => 'JPEG',
      };

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildInputConnectors(BuildContext context) => [
        InputConnector(
          label: 'aaIn',
          idx: 0,
          active: widget.inputConnected,
          onConnect: widget.onInputConnect,
        ),
        InputConnector(
          label: 'textIn',
          idx: 1,
          active: widget.textConnected,
          onConnect: widget.onTextConnect,
        ),
        InputConnector(
          label: 'imageIn',
          idx: 2,
          active: widget.imageConnected,
          onConnect: widget.onImageConnect,
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme   = Theme.of(context);
    final hasData = _incomingAa != null || _incomingText != null || _incomingImage != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 52),
        TextField(
          controller: _filePathController,
          enabled: !_isSaving,
          decoration: const InputDecoration(
            labelText: 'File Path (relative to storage/out/)',
            hintText: 'export',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 36,
          child: OutlinedButton.icon(
            onPressed: _isSaving ? null : _onBrowsePressed,
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Browse...'),
          ),
        ),
        const SizedBox(height: 8),
        DropdownMenu<_SaveFormat>(
          enableSearch: false,
          label: const Text('Format'),
          initialSelection: _selectedFormat,
          onSelected: (format) {
            if (format != null) setState(() => _selectedFormat = format);
          },
          dropdownMenuEntries: _SaveFormat.values
              .map((f) => DropdownMenuEntry(value: f, label: _formatLabel(f)))
              .toList(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: ElevatedButton.icon(
            onPressed: (!hasData || _isSaving) ? null : _onSavePressed,
            icon: _isSaving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save, size: 16),
            label: Text(_isSaving ? 'Saving...' : 'Save / Export'),
          ),
        ),
        const SizedBox(height: 8),
        _buildStatusDisplay(theme),
      ],
    );
  }

  Widget _buildStatusDisplay(ThemeData theme) {
    final color     = _statusIsError ? theme.colorScheme.error : Colors.green;
    final textStyle = theme.textTheme.bodySmall?.copyWith(color: color);
    return Text(_statusMessage,
        style: textStyle, maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}
