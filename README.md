# Pure Music

<p align="center">
  <img src="app_icon.png" width="80" height="80" alt="Pure Music Logo">
</p>

<p align="center">面向 Windows 的本地音乐播放器</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square" alt="Platform">
  <a href="https://github.com/qingyueyin/Pure-music/releases/latest"><img src="https://img.shields.io/github/v/release/qingyueyin/Pure-music?style=flat-square&color=0969da" alt="Version"></a>
  <a href="https://github.com/qingyueyin/Pure-music/releases/latest"><img src="https://img.shields.io/github/downloads/qingyueyin/Pure-music/total?style=flat-square&color=2ea44f" alt="Downloads"></a>
  <a href="#license"><img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://qingyueyin.github.io/Pure-music/"><img src="https://img.shields.io/badge/网站-使用指南-28a745?style=flat-square" alt="Website"></a>
  <a href="https://gitee.com/qingyueyin/Pure-music"><img src="https://img.shields.io/badge/Gitee-镜像-C71D23?style=flat-square" alt="Gitee"></a>
  <a href="https://t.me/+NsZamWiEKh5lOWNl"><img src="https://img.shields.io/badge/Telegram-群组-2AABEE?style=flat-square" alt="Telegram"></a>
  <a href="https://linux.do"><img src="https://img.shields.io/badge/LINUX_DO-社区-ff7800?style=flat-square" alt="LINUX DO"></a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/110656?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-110656"><img src="https://trendshift.io/api/badge/repositories/110656" alt="Trendshift" width="250" height="55"></a>
</p>

---

## 界面预览

**深色**

<p align="center">
  <img src="screenshot/深色主页.png" width="48%" alt="深色主页">
  <img src="screenshot/深色播放页.png" width="48%" alt="深色播放页">
</p>
<p align="center">
  <img src="screenshot/深色专辑页.png" width="48%" alt="深色专辑页">
  <img src="screenshot/深色沉浸模式.png" width="48%" alt="深色沉浸模式">
</p>
<p align="center">
  <img src="screenshot/深色竖屏.png" width="240" height="420" alt="深色竖屏">
  <img src="screenshot/深色竖屏歌词.png" width="240" height="420" alt="深色竖屏歌词">
  <img src="screenshot/深色竖屏沉浸模式.png" width="240" height="420" alt="深色竖屏沉浸模式">
</p>

**浅色**

<p align="center">
  <img src="screenshot/浅色主页.png" width="48%" alt="浅色主页">
  <img src="screenshot/浅色播放页.png" width="48%" alt="浅色播放页">
</p>
<p align="center">
  <img src="screenshot/浅色网格播放页.png" width="48%" alt="浅色网格播放页">
  <img src="screenshot/浅色专辑页.png" width="48%" alt="浅色专辑页">
</p>
<p align="center">
  <img src="screenshot/浅色沉浸模式.png" width="48%" alt="浅色沉浸模式">
</p>
<p align="center">
  <img src="screenshot/浅色竖屏.png" width="240" height="420" alt="浅色竖屏">
  <img src="screenshot/浅色竖屏歌词.png" width="240" height="420" alt="浅色竖屏歌词">
  <img src="screenshot/浅色竖屏沉浸模式.png" width="240" height="420" alt="浅色竖屏沉浸模式">
</p>

**列表视图**

<p align="center">
  <img src="screenshot/浅色列表.png" width="48%" alt="浅色列表">
  <img src="screenshot/深色列表.png" width="48%" alt="深色列表">
</p>

**曲库**

<p align="center">
  <img src="screenshot/歌单页.png" width="32%" alt="歌单页">
  <img src="screenshot/文件夹页.png" width="32%" alt="文件夹页">
  <img src="screenshot/统计页.png" width="32%" alt="统计页">
</p>
<p align="center">
  <img src="screenshot/专辑详情.png" width="80%" alt="专辑详情">
</p>

**演出模式**

<p align="center">
  <img src="screenshot/演出模式.png" width="80%" alt="演出模式">
</p>

**歌曲详情**

<p align="center">
  <img src="screenshot/歌曲详情.png" width="48%" alt="歌曲详情">
  <img src="screenshot/内嵌歌词.png" width="48%" alt="内嵌歌词">
</p>

**桌面歌词**

<p align="center">
  <img src="screenshot/左对齐主题色歌词.png" width="720" height="198" alt="左对齐主题色歌词">
</p>
<p align="center">
  <img src="screenshot/居中主题色歌词信息歌词.png" width="720" height="198" alt="居中主题色歌词">
</p>
<p align="center">
  <img src="screenshot/右对齐主题色歌词.png" width="720" height="198" alt="右对齐主题色歌词">
</p>

**其他**

<p align="center">
  <img src="screenshot/SMTC.png" width="55%" alt="SMTC">
</p>
<p align="center">
  <img src="screenshot/内嵌数据编辑.png" width="80%" alt="内嵌数据编辑">
</p>

---

## 与上游的区别

基于上游 [qingyueyin/Pure-music](https://github.com/qingyueyin/Pure-music)，本分支在其基础上扩展了以下能力。

### 曲库与格式

- **CUE 分轨**：FLAC/WAV 整轨配合同名 CUE 展开为独立曲目，播放、进度与 seek 都以 CUE 段边界为准；TAK 整轨中的曲目同样按段呈现。
- **SACD ISO**：解析 ISO 的 TOC 生成曲目列表，2CH 与 MCH 区分别呈现；裸 DSD（3-in-14 / 3-in-16）与 DST 压缩轨道都提取为 DSF，DST 由内置解码器还原。同目录的 metabase XML 提供专辑、曲名、艺术家与封面，缺失时回退 ISO 内的文本信息。
- **TAK**：CUE 整轨中的 TAK 曲目通过 BASS_FFMPEG 原生解码播放，无需外部转换工具。
- **导入与封面**：文件夹导入与 m3u/pls 导入都识别 CUE、ISO 源文件，按其中的曲目展开为虚拟轨；同目录封面按 `cover` / `folder` / `front`、源文件同名图片、`Jacket` / `Scans` 子目录的顺序解析（jpg / jpeg / png / webp / bmp），未命中回退内嵌图。
- **音质徽章**：音乐列表、播放队列与统计页歌曲排行显示 Hi-Res 与 DSD 徽章；采样率高于 44100 Hz，或 44100 Hz 且位深不低于 24 bit 记为 Hi-Res，SACD 虚拟轨、DSF/DFF/sacd 来源、采样率不低于 2822400 Hz 或源文件后缀为 `.dsf`/`.dff` 记为 DSD。DSD 曲目同时显示两个徽章。

### 播放与输出

**DSD 播放**

默认 DSF 直解，SACD 轨道提取为 DSF 后原样输出，不生成 PCM 中间文件。手动选择 PCM 缓存时转为 WAV，采样率 44.1k / 88.2k / 96k / 192k，位深 16 / 24 bit，降低 DSD 解码的 CPU 占用；转换失败时该轨回退到 DSF 播放。清理缓存只删除 PCM 派生文件，保留已提取的 DSF。

**输出设置**

| 项目 | 说明 |
|------|------|
| 输出设备 | 共享与独占两套设备编号空间分别枚举与选择 |
| 共享 / 独占 | 共享由 Windows 混音器决定实际格式；独占按所选采样率与格式向设备请求，失败回退切换前的设置 |
| 采样率 | 可选自动或固定值；自动时独占跟随设备混音格式 |
| 输出格式 | 按设备支持情况请求，设备不支持时自动选择兼容格式 |
| PCM 缓存格式 | 选择 PCM 缓存时 SACD 转 PCM 使用的采样率与位深，下次加载音轨时生效 |
| DSD 播放模式 | DSF 直解（推荐，源 DSF 原样输出）或 PCM 缓存（生成 WAV，首次转换较慢） |

**性能与稳定性**

SACD 轨道提取串行执行，TOC 解析结果缓存；缓存 DSF 在使用前校验头部与 chunk 结构，损坏时重新提取；播放过程中预提取下一轨，批量导入按批处理削峰。

### 在线能力

- **在线元数据**：专辑与艺术家信息从网易云音乐、QQ 音乐、酷狗音乐、MusicBrainz / Cover Art Archive 多源检索；候选列表供选择，可选「不使用」或将字段留空；结果长期缓存，封面与头像使用磁盘缓存。
- **歌词**：在线候选支持来源选择（QQ / 酷狗 / 网易 / AMLL），支持逐字歌词；KRC 歌词自带翻译与罗马音，纯假名的日文行自动转写罗马音，歌词缓存保留翻译与罗马音。
- **应用内更新**：检测到新版本后可下载安装包，校验 SHA256 后自动拉起安装向导；便携版下载更新包，同时保留打开网页的入口。
- **网络**：所有网络请求统一走代理配置（系统 / 直连 / 手动），由代理软件自行分流；本机回环地址直连。

### 数据与界面

- **缓存与数据**：缓存目录可单独指定到其他磁盘，清理缓存删除封面、歌词候选、在线信息、AMLL 索引与 SACD PCM 缓存，已提取的 DSF 保留；便携版与安装版使用各自的数据目录。
- **界面与性能**：详情页按可用宽度切换紧凑布局，在线信息面板在窄宽度下移到标题下方或隐藏；专辑卡片标题按封面主色计算对比度；音量滑杆拖动只更新内存与 BASS 输出，松手才落盘，拖动不触发整页重建；封面与头像使用磁盘缓存。

---

## 从源码构建

<details>
<summary>构建命令</summary>

```bash
flutter pub get
flutter run

# 构建 Release
flutter build windows --release

# 修改 Rust 后重新生成 FRB 绑定
# 需先安装: cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen generate
```

</details>

---

## 致谢

| | |
|------|------|
| 图标 | [Silicon7921](https://ray.so/icon) |
| 字体 | [Pretendard Variable](https://github.com/orioncactus/pretendard) |
| 音频 | [BASS](https://www.un4seen.com/) |
| 标签 | [lofty](https://github.com/Serial-ATA/lofty-rs) |
| 歌词库 | [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db) |
| FFI | [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) |
| 起源 | [coriander_player](https://github.com/Ferry-200/coriander_player) |
| 参考 | [ZeroBit-Player](https://github.com/Empty-57/ZeroBit-Player) · [Lyrico](https://github.com/Replica0110/Lyrico) · [original-sound-hq-player](https://github.com/Johnwikix/original-sound-hq-player) · [SPlayer](https://github.com/imsyy/SPlayer) · [Unilyric](https://github.com/apoint123/Unilyric) |

---

## 特别感谢

| | |
|------|------|
| muzi9527 | [L站链接](https://linux.do/u/muzi9527) |

---

## 贡献者

[![contrib.rocks](https://contrib.rocks/image?repo=qingyueyin/Pure-music&max=1000&v=3)](https://github.com/qingyueyin/Pure-music/graphs/contributors)

---

## Star History

<a href="https://www.star-history.com/?repos=qingyueyin%2FPure-music&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&theme=dark&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&theme=light&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=qingyueyin/Pure-music&type=date&theme=light&legend=top-left&sealed_token=3xg2arWalPfLMWP-v8tF6oiUigXHChZGv3G5byMARkfFx4mAH_bKPZWuYsOGt0OXyQAacmwE94DO-yNQKFu3d1xE7KqjHBRQ1PXDBRrIb9-lsK6IVQyzdA" />
 </picture>
</a>

---

## License

代码遵循 [GPL-3.0](LICENSE)。

请尊重（非法律条款）：仅限非商业用途；使用或修改时注明出处，并附上本仓库链接。

---

## 免责声明

软件不包含音乐、歌词等版权内容，播放的是你本地已有的文件。在线歌词来自第三方平台，版权归原平台及权利人所有。使用本软件产生的版权、法律问题由使用者自行承担。

---

<div align="center">Made with ❤️ by qingyueyin</div>
