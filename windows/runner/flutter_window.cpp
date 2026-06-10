#include "flutter_window.h"

#include <windows.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Convierte una ruta UTF-8 (como llega de Dart) a UTF-16 para la API de ficheros.
std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring utf16(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      utf16.data(), len);
  return utf16;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  wasapi_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.adriangp.markly/wasapi",
          &flutter::StandardMethodCodec::GetInstance());
  wasapi_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const std::string& method = call.method_name();
        if (method == "start") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "start requiere {path, captureSystem}");
            return;
          }
          std::string path;
          bool capture_system = false;
          auto path_it = args->find(flutter::EncodableValue("path"));
          if (path_it != args->end()) {
            if (const auto* p = std::get_if<std::string>(&path_it->second)) {
              path = *p;
            }
          }
          auto sys_it = args->find(flutter::EncodableValue("captureSystem"));
          if (sys_it != args->end()) {
            if (const auto* b = std::get_if<bool>(&sys_it->second)) {
              capture_system = *b;
            }
          }
          if (path.empty()) {
            result->Error("bad_args", "start requiere la ruta del WAV");
            return;
          }
          const bool ok =
              wasapi_recorder_.Start(Utf16FromUtf8(path), capture_system);
          result->Success(flutter::EncodableValue(ok));
        } else if (method == "stop") {
          wasapi_recorder_.Stop();
          result->Success();
        } else if (method == "pause") {
          wasapi_recorder_.Pause();
          result->Success();
        } else if (method == "resume") {
          wasapi_recorder_.Resume();
          result->Success();
        } else if (method == "amplitude") {
          result->Success(
              flutter::EncodableValue(wasapi_recorder_.Amplitude()));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  wasapi_recorder_.Stop();
  wasapi_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
