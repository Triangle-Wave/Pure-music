# 第三方组件：bass_tak

## tak_deco_lib.dll

- 来源：TAK 官方解码库，版本 2.3.3（`tak_GetLibraryVersion` 返回 `0x00020303`）
- 版权：Copyright 2007 Thomas Becker, D-49080 Osnabrueck
- 许可：freeware；随本应用分发，只用于本地 TAK 音频解码
- 位置：`bin/tak_deco_lib.dll`（x64）

`tak_deco_lib.h` 是同一解码库的官方 SDK 头文件（声明版本 1.1.1），结构体按 1 字节对齐与 DLL 保持一致。

## bass_tak 插件源码

- 来源：gageas/bass_tak2.4（BASS 2.4 的 TAK 插件）
- 用途：把 `tak_deco_lib` 接入 BASS，使 BASS 直接加载 `.tak` 文件
- 本目录的副本面向 x64 与 BASS 2.4.17：文件偏移使用 64 位类型，64 位长度使用 `ptrdiff_t`，并对采样参数与 APE 标签长度做边界校验

## 使用范围

`bass_tak.dll` 只把 TAK 比特流解码为 PCM 交给 BASS；不修改源文件，不参与编码。
