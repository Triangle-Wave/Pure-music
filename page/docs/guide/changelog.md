---
outline: false
description: Pure Music 更新日志，自 2.0.0 起按版本折叠。
---

# 更新日志

从 **2.0.0** 起。每个版本默认折叠，点版本号展开。最新：**2.3.15**。

完整发布页：[GitHub](https://github.com/Triangle-Wave/Pure-music/releases)（未配置 Gitee 镜像）

<details>
<summary><strong>2.3.15</strong></summary>

**Full Changelog**: https://github.com/Triangle-Wave/Pure-music/compare/v2.3.14...v2.3.15

</details>

<details>
<summary><strong>2.3.14</strong></summary>

**更新流程**

- 修复点击“下载并安装”后安装向导没有启动的问题：现在直接启动安装程序，由安装程序关闭当前应用并完成替换。
- 修复 GitHub API 限流时更新弹窗不显示更新说明的问题，改用更新清单中的完整日志。

**安装提示**

- 2.3.13 及更早版本仍需要手动运行一次本版本的安装包；安装 2.3.14 后，后续版本可以正常在线更新。

</details>

<details>
<summary><strong>2.3.9</strong></summary>

**播放与曲库**
- TTA 曲目进度条零点改用 BASS 实际定位落点，起点不再偏移
- CUE 段尾偏移按距末尾距离设置，播放止于轨尾
- 增量扫描发现 CUE 目录仍有被引用的源文件整轨条目时强制重建；曲库加载时剔除被虚拟轨覆盖的源文件条目
- CUE 最后一轨时长：内置读取器按 Windows 媒体属性 → TAK 容器头（`tBaK` + STREAMINFO）→ TTA1 头依次兜底，同一文件只探测一次；全部探测失败时保持原行为并记录原因
- CUE 虚拟轨封面按通用名（cover/folder/front）→ 源文件同名图 → Jacket/Scans 子目录 → 内嵌图依次查找，支持 BMP，同目录共享一次扫描
- 搜索：音乐结果匹配专辑名与艺术家，支持首字母与完整拼音，标题命中优先

**歌词**
- 跨来源合并：主来源保留逐字时间轴，其他来源按时间戳补齐缺失的翻译与罗马音，已有内容不覆盖

**音频输出**
- 共享模式与独占模式分别记录输出设备
- 设备名支持二次解析并去掉模糊匹配，失效设备不再静默切换
- 设备热插拔后自动刷新列表

**更新**
- 下载线路：自动（GitHub 直连 → Gitee 镜像 → 加速代理）、仅 GitHub、仅 Gitee、仅加速代理
- 更新清单只从 GitHub 或 Gitee 获取，加速代理只承担安装包传输
- 每条线路下载后校验 SHA256，校验不通过自动切换下一条线路，全部失败时优先展示直连原因

**远程曲库**
- 新增 Navidrome、WebDAV 远程曲库
- 远程曲目参与播放统计与播放记录

**上游同步**
- 合并上游的输出设备、歌词请求、滤镜与背景渲染、界面提示等修复

**其他**
- 退出时释放音量控制
- 在线歌词请求支持取消

</details>

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
