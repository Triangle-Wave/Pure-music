#include "desktop_lyric_window.h"

#include <flutter/standard_method_codec.h>

#include <utility>
#include <variant>

namespace {

constexpr char kChannelName[] = "pure_music/desktop_lyric_window";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"desktop_lyric";
constexpr int kOffscreenPosition = -32000;
constexpr UINT kMoveFlags = SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE;

const flutter::EncodableValue* ValueForKey(
    const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

const bool* ReadBool(const flutter::EncodableMap& map, const char* key) {
  return std::get_if<bool>(ValueForKey(map, key));
}

}  // namespace

DesktopLyricWindow::DesktopLyricWindow(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

DesktopLyricWindow::~DesktopLyricWindow() = default;

void DesktopLyricWindow::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "setVisible") {
    result->Success(
        flutter::EncodableValue(SetVisible(method_call.arguments())));
  } else {
    result->NotImplemented();
  }
}

bool DesktopLyricWindow::SetVisible(
    const flutter::EncodableValue* arguments) {
  const auto map = arguments == nullptr
                       ? nullptr
                       : std::get_if<flutter::EncodableMap>(arguments);
  const bool* visible = map == nullptr ? nullptr : ReadBool(*map, "visible");
  if (visible == nullptr) {
    return false;
  }

  HWND hwnd = FindLyricWindow();
  if (hwnd == nullptr) {
    return false;
  }

  if (!*visible) {
    if (!has_saved_position_) {
      RECT rect{};
      if (!GetWindowRect(hwnd, &rect)) {
        return false;
      }
      saved_x_ = rect.left;
      saved_y_ = rect.top;
      has_saved_position_ = true;
    }
    if (!SetWindowPos(hwnd, nullptr, kOffscreenPosition, kOffscreenPosition,
                      0, 0, kMoveFlags)) {
      return false;
    }
    return true;
  }

  if (!has_saved_position_) {
    return true;
  }
  if (!SetWindowPos(hwnd, nullptr, saved_x_, saved_y_, 0, 0, kMoveFlags)) {
    return false;
  }
  ClearSavedPosition();
  return true;
}

HWND DesktopLyricWindow::FindLyricWindow() {
  if (lyric_window_ != nullptr && IsWindow(lyric_window_)) {
    return lyric_window_;
  }
  // 位置记录与缓存 HWND 绑定；句柄失效或重查到不同窗口时丢弃旧坐标。
  ClearSavedPosition();
  HWND found = FindWindowW(kWindowClass, kWindowTitle);
  if (found == nullptr || !IsWindow(found)) {
    lyric_window_ = nullptr;
    return nullptr;
  }
  lyric_window_ = found;
  return lyric_window_;
}

void DesktopLyricWindow::ClearSavedPosition() {
  has_saved_position_ = false;
  saved_x_ = 0;
  saved_y_ = 0;
}
