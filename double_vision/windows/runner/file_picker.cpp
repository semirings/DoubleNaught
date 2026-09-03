#include "include/file_picker.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.dart>
#include <windows.h>
#include <commdlg.h>
#include <shlobj.h>

#include <memory>
#include <string>

namespace {

class FilePicker {
 public:
  static void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (method_call.method_name() == "pickFileOrDirectory") {
      PickFileOrDirectory(std::move(result));
    } else {
      result->NotImplemented();
    }
  }

 private:
  static void PickFileOrDirectory(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    // Use Windows file open dialog that supports both files and directories
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED |
                                         COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) {
      result->Success(flutter::EncodableValue());
      return;
    }

    IFileOpenDialog* pFileDialog = nullptr;
    hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&pFileDialog));
    if (FAILED(hr)) {
      CoUninitialize();
      result->Success(flutter::EncodableValue());
      return;
    }

    // Key: set to allow both files and folders
    FILEOPENDIALOGOPTIONS dwFlags;
    pFileDialog->GetOptions(&dwFlags);
    pFileDialog->SetOptions(dwFlags | FOS_PICKFOLDERS);

    hr = pFileDialog->Show(nullptr);
    if (SUCCEEDED(hr)) {
      IShellItem* pItem = nullptr;
      hr = pFileDialog->GetResult(&pItem);
      if (SUCCEEDED(hr)) {
        PWSTR pszPath = nullptr;
        hr = pItem->GetDisplayName(SIGDN_FILESYSPATH, &pszPath);
        if (SUCCEEDED(hr)) {
          std::wstring wpath(pszPath);
          std::string path(wpath.begin(), wpath.end());

          WIN32_FILE_ATTRIBUTE_DATA fileAttr;
          bool isDir = GetFileAttributesExA(path.c_str(), GetFileExInfoStandard,
                                            &fileAttr) &&
                       (fileAttr.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);

          flutter::EncodableMap resultMap;
          resultMap[flutter::EncodableValue("type")] =
              flutter::EncodableValue(isDir ? "dir" : "file");
          resultMap[flutter::EncodableValue("path")] =
              flutter::EncodableValue(path);
          result->Success(flutter::EncodableValue(resultMap));

          CoTaskMemFree(pszPath);
        }
        pItem->Release();
      }
    }

    pFileDialog->Release();
    CoUninitialize();
  }
};

}  // namespace

void FilePikerPluginRegisterWithRegistrar(
    FlutterWindowsPluginRegistrarRef registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter::PluginRegistrarGetMessenger(registrar),
          "com.populi.doubleNaught/file_picker",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        FilePicker::HandleMethodCall(call, std::move(result));
      });
}
