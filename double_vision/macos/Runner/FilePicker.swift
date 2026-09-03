import Cocoa
import FlutterMacOS

/// Unified file/directory picker for macOS using NSSavePanel.
/// Returns both files and directories in a single native dialog.
class FilePicker {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.populi.doubleNaught/file_picker",
      binaryMessenger: controller.engine.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      if call.method == "pickFileOrDirectory" {
        pickFileOrDirectory(result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func pickFileOrDirectory(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()

    // Key: allow both files AND directories
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        result(nil) // Cancelled
        return
      }

      let fileManager = FileManager.default
      var isDir: ObjCBool = false
      let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)

      result([
        "type": isDir.boolValue ? "dir" : "file",
        "path": url.path,
      ])
    }
  }
}
