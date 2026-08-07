import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/aa_payload.dart';
import '../../../models/workflow.dart';
import '../../../services/load_file_api.dart';
import '../../../services/infobus/output_port.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// A workflow source node that loads files from the backend storage directory
/// and auto-detects Associative Arrays based on schema metadata or column patterns.
///
/// Supports .parquet, .arrow, .json, .csv, .txt files. AA detection is handled
/// by the backend /load endpoint, which checks for metadata tags and reconstructs
/// native AA objects. Non-AA files are returned as raw tables/text.
///
/// Emits two output ports:
/// - `contents` (idx 0): raw file data as dict/string (for non-AA files)
/// - `aa` (idx 1): the loaded AA if detected, else null
class LoadFileNode extends BaseNodeWidget {
  final void Function(AaPayload aa)? onAaLoaded;

  const LoadFileNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    this.onAaLoaded,
    super.onOutputPort,
    super.connectedOutputs,
  });

  @override
  State<LoadFileNode> createState() => _LoadFileNodeState();
}

enum _SchemaMode { auto, forceAa, rawTable }

class _LoadFileNodeState extends BaseNodeState<LoadFileNode> {
  @override String   get nodeTitle => 'Load File';
  @override IconData get nodeIcon  => Icons.upload_file_outlined;

  final OutputPort _contentsOut = OutputPort('contents');
  final OutputPort _aaOut = OutputPort('aa');
  final LoadFileApi _api = const LoadFileApi();

  late TextEditingController _filePathController;
  _SchemaMode _schemaMode = _SchemaMode.auto;
  AaPayload? _aa;
  bool _isLoading = false;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    initOutputPort(_contentsOut);
    initOutputPort(_aaOut);

    _filePathController = TextEditingController(
      text: widget.initialParams?['filePath'] ?? 'storage/out/export.parquet',
    );

    final schemaMode = widget.initialParams?['schemaMode'];
    if (schemaMode != null) {
      try {
        _schemaMode = _SchemaMode.values.byName(schemaMode);
      } catch (_) {
        _schemaMode = _SchemaMode.auto;
      }
    }
  }

  @override
  void dispose() {
    _filePathController.dispose();
    _contentsOut.dispose();
    _aaOut.dispose();
    super.dispose();
  }

  Future<void> _onLoadPressed() async {
    final filePath = _filePathController.text.trim();
    if (filePath.isEmpty) {
      setState(() {
        _errorMessage = 'Error: Enter a file path';
        _statusMessage = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = 'Loading...';
    });

    try {
      final response = await _api.load(
        filePath: filePath,
        schemaMode: _schemaMode.name,
      );

      if (!mounted) return;

      setState(() {
        _aa = response.aa;
        _statusMessage = response.message;
        _errorMessage = null;
      });

      // Emit the AA if detected.
      if (response.aa != null) {
        _aaOut.emit(response.aa!);
      }

      // Save params for persistence.
      saveParams({
        'filePath': filePath,
        'schemaMode': _schemaMode.name,
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: ${e.toString()}';
          _statusMessage = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'contents',
          idx: 0,
          active: _statusMessage != null || _aa != null,
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
        OutputConnector(
          label: 'aa',
          idx: 1,
          active: _aa != null || widget.connectedOutputs.contains(1),
          dragData: PortRef(nodeId: widget.node.id, idx: 1),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        TextField(
          controller: _filePathController,
          enabled: !_isLoading,
          decoration: const InputDecoration(
            labelText: 'File Path (backend storage)',
            hintText: 'storage/out/export.parquet',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
        const SizedBox(height: 8),
        DropdownMenu<_SchemaMode>(
          enableSearch: false,
          label: const Text('Schema Mode'),
          initialSelection: _schemaMode,
          onSelected: (mode) {
            if (mode != null) setState(() => _schemaMode = mode);
          },
          dropdownMenuEntries: const [
            DropdownMenuEntry(
              value: _SchemaMode.auto,
              label: 'Auto-Detect',
            ),
            DropdownMenuEntry(
              value: _SchemaMode.forceAa,
              label: 'Force AA',
            ),
            DropdownMenuEntry(
              value: _SchemaMode.rawTable,
              label: 'Raw Table',
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _onLoadPressed,
            icon: _isLoading
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 16),
            label: Text(_isLoading ? 'Loading...' : 'Load'),
          ),
        ),
        const SizedBox(height: 8),
        _buildStatus(theme),
        if (_aa != null) ...[
          const SizedBox(height: 6),
          _buildAaIndicator(theme),
        ],
      ],
    );
  }

  Widget _buildAaIndicator(ThemeData theme) {
    final aa = _aa!;
    final rows = aa.distinctRows().length;
    final cols = <String>{...aa.cols}.length;
    return Row(
      children: [
        Icon(Icons.table_chart_outlined, size: 14, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'AA · $rows rows × $cols cols on aa',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(ThemeData theme) {
    if (_errorMessage != null) {
      return Text(_errorMessage!,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12));
    }
    if (_statusMessage != null) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_statusMessage!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.green),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}
