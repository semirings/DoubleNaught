import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/input_port.dart';
import '../base/double_naught_node_wrapper.dart';
import '../base/input_connector.dart';

/// Save format for the output file, auto-detected or manually selected.
enum _SaveFormat { json, csv, txt, png, jpg }

/// A workflow sink node that saves incoming port data (AA, text, or image)
/// to local disk with format selection and save-location controls.
///
/// Provides three input ports:
/// - `aaIn` (idx 0): Associative Array (D4M dict) on the AA port bus
/// - `textIn` (idx 1): Plain text stream from upstream
/// - `imageIn` (idx 2): Raw image bytes stream from upstream
///
/// The node includes file path text input, a "Browse..." button for path
/// selection, a format dropdown, a "Save / Export" button, and status display.
class SaveFileNode extends StatefulWidget {
  final WorkflowNode node;

  /// Whether `aaIn` has an incoming edge.
  final bool aaConnected;

  /// Whether `textIn` has an incoming edge.
  final bool textConnected;

  /// Whether `imageIn` has an incoming edge.
  final bool imageConnected;

  /// Called when an edge is dropped on `aaIn`.
  final void Function(PortRef source)? onAaConnect;

  /// Called when an edge is dropped on `textIn`.
  final void Function(PortRef source)? onTextConnect;

  /// Called when an edge is dropped on `imageIn`.
  final void Function(PortRef source)? onImageConnect;

  /// Registers `aaIn` with the canvas bridge (AA port bus).
  final void Function(InputPort port)? onAaInputPort;

  /// Text stream wired from upstream nodes.
  final Stream<String>? textInput;

  /// Image bytes stream wired from upstream nodes.
  final Stream<Uint8List>? imageInput;

  /// Saved node parameters (file path, format selection, etc.).
  final Map<String, String>? initialParams;

  /// Reports node parameter changes back to the canvas for persistence.
  final void Function(Map<String, String> params)? onParams;

  const SaveFileNode({
    super.key,
    required this.node,
    this.aaConnected = false,
    this.textConnected = false,
    this.imageConnected = false,
    this.onAaConnect,
    this.onTextConnect,
    this.onImageConnect,
    this.onAaInputPort,
    this.textInput,
    this.imageInput,
    this.initialParams,
    this.onParams,
  });

  @override
  State<SaveFileNode> createState() => _SaveFileNodeState();
}

class _SaveFileNodeState extends State<SaveFileNode> {
  // --- Input ports ---
  late final InputPort _aaIn;
  StreamSubscription<String>? _textSub;
  StreamSubscription<Uint8List>? _imageSub;

  AaPayload? _incomingAa;
  String? _incomingText;
  Uint8List? _incomingImage;

  // --- File path & format controls ---
  late TextEditingController _filePathController;
  _SaveFormat _selectedFormat = _SaveFormat.json;
  String _statusMessage = 'Ready to save';
  bool _statusIsError = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _aaIn = InputPort('aaIn');
    widget.onAaInputPort?.call(_aaIn);
    _aaIn.onDataArrived.listen(_onAaData);

    _subscribeText();
    _subscribeImage();

    _filePathController =
        TextEditingController(text: widget.initialParams?['filePath'] ?? '');
    _loadFormatFromParams();
  }

  @override
  void didUpdateWidget(SaveFileNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textInput != widget.textInput) _subscribeText();
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
    // Check which input is active and suggest a format.
    if (_incomingAa != null) return _SaveFormat.json;
    if (_incomingText != null) return _SaveFormat.txt;
    if (_incomingImage != null) {
      return _detectImageFormat(_incomingImage!) ?? _SaveFormat.png;
    }
    return _SaveFormat.json;
  }

  void _updateFormat() {
    // Auto-detect only if user hasn't explicitly set a format in params.
    if (widget.initialParams?['format'] == null) {
      setState(() => _selectedFormat = _autoDetectFormat());
    }
  }

  /// Detect PNG vs JPEG by magic bytes; return null if unknown.
  _SaveFormat? _detectImageFormat(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x50) {
      return _SaveFormat.png;
    }
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return _SaveFormat.jpg;
    }
    return null;
  }

  Future<void> _onSavePressed() async {
    setState(() => _isSaving = true);
    try {
      final filePath = _filePathController.text.trim();
      if (filePath.isEmpty) {
        setState(() {
          _statusMessage = 'Error: Enter a file path';
          _statusIsError = true;
        });
        return;
      }

      // Ensure the path has the right extension.
      final finalPath = _appendExtensionIfMissing(filePath, _selectedFormat);

      // Serialize and write based on the active input.
      if (_incomingAa != null) {
        await _saveAa(_incomingAa!, finalPath);
      } else if (_incomingText != null) {
        await _saveText(_incomingText!, finalPath);
      } else if (_incomingImage != null) {
        await _saveImage(_incomingImage!, finalPath);
      } else {
        setState(() {
          _statusMessage = 'Error: No data to save';
          _statusIsError = true;
        });
        return;
      }

      // Update params for persistence.
      widget.onParams?.call({
        'filePath': filePath,
        'format': _selectedFormat.name,
      });

      setState(() {
        _statusMessage = 'Saved to $finalPath';
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
    final ext = _extensionFor(_selectedFormat);
    final result = await fs.getSaveLocation(
      suggestedName: 'export$ext',
      acceptedTypeGroups: [
        fs.XTypeGroup(
          label: _formatLabel(_selectedFormat),
          extensions: [ext.replaceFirst('.', '')],
        ),
      ],
    );
    if (result != null) {
      setState(() => _filePathController.text = result.path);
    }
  }

  Future<void> _saveAa(AaPayload aa, String path) async {
    if (_selectedFormat == _SaveFormat.csv) {
      await _saveAaCsv(aa, path);
    } else {
      await _saveAaJson(aa, path);
    }
  }

  Future<void> _saveAaJson(AaPayload aa, String path) async {
    final dict = {
      'row': aa.rows,
      'col': aa.cols,
      'val': aa.vals,
    };
    final json = jsonEncode(dict);
    await _writeFile(path, utf8.encode(json));
  }

  Future<void> _saveAaCsv(AaPayload aa, String path) async {
    // Simple CSV: header row with column names, then data rows.
    final colSet = <String>{};
    for (final col in aa.cols) {
      colSet.add(col);
    }
    final columns = colSet.toList()..sort();
    final rows = aa.distinctRows();

    final lines = <String>[];
    lines.add(columns.join(','));

    for (final row in rows) {
      final values = <String>[];
      for (final col in columns) {
        // Find the value at (row, col) in the sparse triples.
        String value = '';
        for (int i = 0; i < aa.rows.length; i++) {
          if (aa.rows[i] == row && aa.cols[i] == col) {
            value = aa.vals[i].toString();
            break;
          }
        }
        values.add(_escapeCsvField(value));
      }
      lines.add(values.join(','));
    }

    await _writeFile(path, utf8.encode(lines.join('\n')));
  }

  String _escapeCsvField(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  Future<void> _saveText(String text, String path) async {
    await _writeFile(path, utf8.encode(text));
  }

  Future<void> _saveImage(Uint8List bytes, String path) async {
    await _writeFile(path, bytes);
  }

  Future<void> _writeFile(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  String _appendExtensionIfMissing(String path, _SaveFormat format) {
    final ext = _extensionFor(format);
    if (!path.toLowerCase().endsWith(ext)) {
      return path + ext;
    }
    return path;
  }

  String _extensionFor(_SaveFormat format) => switch (format) {
        _SaveFormat.json => '.json',
        _SaveFormat.csv => '.csv',
        _SaveFormat.txt => '.txt',
        _SaveFormat.png => '.png',
        _SaveFormat.jpg => '.jpg',
      };

  String _formatLabel(_SaveFormat format) => switch (format) {
        _SaveFormat.json => 'JSON',
        _SaveFormat.csv => 'CSV',
        _SaveFormat.txt => 'Text',
        _SaveFormat.png => 'PNG',
        _SaveFormat.jpg => 'JPEG',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = _incomingAa != null || _incomingText != null || _incomingImage != null;

    return DoubleNaughtNodeWrapper(
      title: 'Save File',
      icon: Icons.save_outlined,
      inputPorts: [
        InputConnector(
          label: 'aaIn',
          idx: 0,
          active: widget.aaConnected,
          onConnect: widget.onAaConnect,
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
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // File path input
          TextField(
            controller: _filePathController,
            decoration: const InputDecoration(
              labelText: 'File Path',
              hintText: 'export.json',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            enabled: !_isSaving,
          ),
          const SizedBox(height: 8),
          // Browse button
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
          // Format selector
          DropdownMenu<_SaveFormat>(
            enableSearch: false,
            label: const Text('Format'),
            initialSelection: _selectedFormat,
            onSelected: (format) {
              if (format != null) {
                setState(() => _selectedFormat = format);
              }
            },
            dropdownMenuEntries: _SaveFormat.values
                .map((f) => DropdownMenuEntry(value: f, label: _formatLabel(f)))
                .toList(),
          ),
          const SizedBox(height: 12),
          // Save button
          SizedBox(
            width: double.infinity,
            height: 40,
            child: ElevatedButton.icon(
              onPressed: (!hasData || _isSaving) ? null : _onSavePressed,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save, size: 16),
              label: Text(_isSaving ? 'Saving...' : 'Save / Export'),
            ),
          ),
          const SizedBox(height: 8),
          // Status display
          _buildStatusDisplay(theme),
        ],
      ),
    );
  }

  Widget _buildStatusDisplay(ThemeData theme) {
    final color = _statusIsError ? theme.colorScheme.error : Colors.green;
    final textStyle = theme.textTheme.bodySmall?.copyWith(color: color);
    return Text(_statusMessage, style: textStyle, maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}
