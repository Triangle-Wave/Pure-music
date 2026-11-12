#ifndef RUNNER_DESKTOP_LYRIC_WINDOW_H_
#define RUNNER_DESKTOP_LYRIC_WINDOW_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// 控制外部桌面歌词进程窗口的屏幕位置，实现显隐。
class DesktopLyricWindow {
 public:
  explicit DesktopLyricWindow(flutter::BinaryMessenger* messenger);
  ~DesktopLyricWindow();

  DesktopLyricWindow(const DesktopLyricWindow&) = delete;
  DesktopLyricWindow& operator=(const DesktopLyricWindow&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool SetVisible(const flutter::EncodableValue* arguments);
  HWND FindLyricWindow();
  void ClearSavedPosition();

  HWND lyric_window_ = nullptr;
  bool has_saved_position_ = false;
  int saved_x_ = 0;
  int saved_y_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_DESKTOP_LYRIC_WINDOW_H_
