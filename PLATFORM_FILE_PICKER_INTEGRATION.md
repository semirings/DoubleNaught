# Platform File Picker Integration

## Overview
Replaces the file/directory selection popup menu with a single unified native dialog that supports both files and directories, automatically detecting what was selected.

## Files Changed

### Dart Frontend
- **`frontend/lib/services/platform_file_picker.dart`** — NEW
  - Method channel wrapper for native file picker
  - Returns `FilePickerResult` with `type` ('file' or 'dir') and `path`

- **`frontend/lib/widgets/nodes/implementations/load_file_node.dart`**
  - Removed: `pickFile` parameter, `_onBrowseFilePressed()`, `_onBrowseDirectoryPressed()`
  - Replaced with: single `_onBrowsePressed()` that uses `PlatformFilePicker`
  - UI: PopupMenuButton → IconButton (no menu)
  - Removed: `package:file_selector` import

### Native Implementations

#### macOS
- **`frontend/macos/Runner/FilePicker.swift`** — NEW
  - Uses `NSOpenPanel` with `canChooseFiles = true` and `canChooseDirectories = true`
  - Returns file/directory type + path

- **`frontend/macos/Runner/MainFlutterWindow.swift`** — MODIFIED
  - Added: `FilePicker.register(with:)` call after `RegisterGeneratedPlugins`

#### Windows
- **`frontend/windows/runner/file_picker.cpp`** — NEW
  - Uses Windows `IFileOpenDialog` with `FOS_PICKFOLDERS` flag
  - Automatically detects file vs directory via `FILE_ATTRIBUTE_DIRECTORY`

#### Linux
- **`frontend/linux/file_picker.cc`** — NEW
  - Uses GTK `GtkFileChooserNative`
  - Checks `G_FILE_TYPE_DIRECTORY` to determine selection type

## Integration Steps

### 1. Build Configuration

**macOS**: Xcode should automatically include Swift files in the Runner target.

**Windows**: Add to `windows/runner/CMakeLists.txt`:
```cmake
add_plugin_sources(
  flutter_windows
  file_picker.cpp
)

# Ensure Windows SDK headers are available
target_link_libraries(${WINDOWS_APP_NAME} PRIVATE shell32 ole32 oleaut32)
```

**Linux**: Add to `linux/CMakeLists.txt`:
```cmake
# Add file_picker plugin
list(APPEND PLUGIN_BUNDLED_LIBRARIES
  file_picker
)

# Link GTK
pkg_check_modules(GTK REQUIRED gtk+-3.0)
target_link_libraries(${PROJECT_NAME} PRIVATE ${GTK_LIBRARIES})
```

### 2. Test

Run on each platform and verify:
- ✅ Click Browse → native dialog appears (no menu)
- ✅ Select a file → `_urlController.text` updates with file path
- ✅ Select a directory → `_urlController.text` updates with directory path
- ✅ File extension validation still works (reject .exe, .zip, etc.)

### 3. Cleanup

Remove from dependencies if no longer used elsewhere:
- `file_selector` package (check if other parts of codebase use it)

## Fallback Behavior

On unsupported platforms (web, Android, iOS):
- `PlatformFilePicker.pickFileOrDirectory()` returns `cancelled: true`
- URL must be entered manually in the text field
- No functionality regression — just less convenient UX

## User-Visible Changes

**Before**: Click Browse → Menu appears → Choose File/Directory → Dialog opens
**After**: Click Browse → Dialog opens → Select file or directory → Done

Single-step UX, native feel on all platforms.
