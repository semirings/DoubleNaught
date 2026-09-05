import 'package:flutter/services.dart';

/// Result from native file/directory picker.
/// [type] is 'file' or 'dir'; [path] is the selected path or null if cancelled.
class FilePickerResult {
  final String? type; // 'file' or 'dir'
  final String? path;
  final bool cancelled;

  FilePickerResult({
    this.type,
    this.path,
  }) : cancelled = path == null;

  factory FilePickerResult.cancelled() =>
      FilePickerResult(type: null, path: null);
}

/// Platform-agnostic file/directory picker.
/// Opens native dialogs on macOS/Windows/Linux that allow selecting
/// either a file OR a directory in a single unified interface.
/// Falls back to file_selector on unsupported platforms.
class PlatformFilePicker {
  static const _channel =
      MethodChannel('com.populi.doubleNaught/file_picker');

  /// Open a native file/directory picker.
  /// Returns FilePickerResult with type ('file'|'dir') and path,
  /// or cancelled=true if user cancels.
  static Future<FilePickerResult> pickFileOrDirectory() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickFileOrDirectory',
      );

      if (result == null) return FilePickerResult.cancelled();

      return FilePickerResult(
        type: result['type'] as String?,
        path: result['path'] as String?,
      );
    } catch (e) {
      // If method channel fails (e.g., web, unsupported platform),
      // return cancelled. Caller should fall back to file_selector.
      return FilePickerResult.cancelled();
    }
  }
}
