---
outline: false
description: Pure Music 更新日志，自 2.0.0 起按版本折叠。
---

# 更新日志

从 **2.0.0** 起。每个版本默认折叠，点版本号展开。最新：**2.3.8**。

完整发布页：[GitHub](https://github.com/Triangle-Wave/Pure-music/releases) · [Gitee 镜像](https://gitee.com/qingyueyin/Pure-music)（同步常滞后）

<details>
<summary><strong>2.3.8</strong></summary>

**播放与格式**

- 新增 TAK 原生解码，CUE 整轨中的 TAK 曲目可直接播放
- SACD ISO 支持 2CH/MCH、DST 压缩与裸 DSD，提取为 DSF 后默认直解
- PCM 缓存可选 44.1k / 88.2k / 96k / 192k 与 16/24bit；默认推荐 DSF 直解，不生成 WAV
- 修复部分格式因异步文件标志导致的“格式不支持”

**在线信息**

- 专辑、艺术家信息支持网易 / QQ / 酷狗与 MusicBrainz / Cover Art Archive
- 支持候选来源选择与“不使用/空白”，结果长期缓存
- 艺术家头像、专辑封面使用磁盘缓存，缓存目录可单独指定
- GitHub API 限流时从发布页解析版本，更新检查不再误报网络异常

**歌词**

- 在线歌词候选与来源选择，支持 QQ / 酷狗 / 网易 / AMLL
- 酷狗 KRC 缓存歌词恢复自带罗马音
- 纯假名日文行自动生成罗马音，含汉字行保持原文

**界面与性能**

- 专辑 / 歌手详情页按可用宽度重新分配头部空间，窄窗口标题与操作区不再被挤压
- 专辑卡片标题按对比度选色，补充艺术家名
- 音量拖动期间不写盘、不整页重建，松手后合并保存
- 封面、头像、在线信息使用磁盘缓存，减少重复请求

**设置与数据**

- 缓存目录可单独指定到其他磁盘，清理缓存保留已提取的 DSF
- 统一代理：所有请求走配置的代理，由代理软件自行分流
- 安装版支持应用内下载更新：校验 SHA256 后自动拉起安装向导

**修复**

- 修复 CUE/TAK 曲目播放失败
- 修复酷狗 KRC 缓存歌词缺少罗马音
- 修复专辑 / 歌手页头部布局、专辑卡片标题不可见
- 修复 GitHub 403 时更新检查显示网络异常
- 修复封面 BMP 解码失败与部分标签读取异常

</details>

<details>
<summary><strong>2.3.7</strong></summary>

**Full Changelog**: https://github.com/Triangle-Wave/Pure-music/compare/v2.3.6...v2.3.7

</details>

---

更早版本见 [GitHub Releases](https://github.com/Triangle-Wave/Pure-music/releases)。下载见 [下载页](/download)。
