# LyricTile · HOLDSNOW 设计与实施交接

研究基线：2026-11-26（北京时间）。这是**完成设计与技术裁决的交接包**，不是已经发布的macOS App。

## 先看这三项

1. `LyricTile-Visuals.pdf`：三个高保真方向、最终词页、状态/语言/材质、首次使用和整个桌面组合。
2. `LyricTile-Design.html`：自包含可交互设计稿，直接本地打开；明确使用原创排版样句，未连接播放器。
3. `docs/LyricTile-Decision.md`：完整产品/技术/复用/架构/首版范围裁决；打印版本为`LyricTile-Decision.pdf`。

动效节奏另见 `LyricTile-Motion.html`：点击后播放原创时间编排样本，明确不连接播放器、不作为实机证据。

交给Codex时，提供完整文件夹/ZIP和`docs/CODEX_BUILD_INSTRUCTIONS.md`。只发截图会丢失媒体、时钟、匹配与权限的重要契约。

## 最终决定

- 名称LyricTile，母品牌HOLDSNOW；独立桌面歌词伴随工具，未来为Nearpane原生模块。
- 唯一正式视觉为「雾白词页」；窄列、稳定歌词、同尺寸hover控制。
- Swift/AppKit/SwiftUI；Apple Music/Spotify走定向AppleEvents，QQ/网易走隔离MediaRemote兼容桥。
- 歌词来源和播放器分离；LRCLIB公开API、绑定/缓存、可选精确ID数据源；不伪造逐字或进度。
- 只复用边界清楚的BSD/MIT与隔离MPL组件；GPL/AGPL作为研究参照，保持未来Nearpane许可选择。
- TileKit很小；旧版本自动排列需要各App接入，独立首发不等待Nearpane。

## 文件索引

| 路径 | 用途 |
|---|---|
| docs/DESIGN_SPEC.md | 几何、字体、材质、动画、状态、交互、权限、可访问性 |
| docs/TILEKIT_PROTOCOL.md | 多进程不重叠、跨屏、生命周期锁、Host交接 |
| docs/MACOS27_ACCEPTANCE.md | 可执行的真实播放器/性能/安装包验收 |
| contracts/design-tokens.json | 机器可读设计值 |
| contracts/LyricDomainContracts.swift | Swift6领域类型/协议草案，尚未Mac编译 |
| contracts/lyric-model-contract.json | 歌词/来源/真实时间模型约束 |
| contracts/player-capabilities.schema.json | 支持资格与运行时能力分离 |
| contracts/source-lock.json | 固定仓库提交与复用决定 |
| contracts/lyric-acceptance-cases.json | 明确标为测试设计的原创格式边界用例 |
| research/*/*AUDIT.md | 三份实际源码深审及永久链接 |
| research/root/LYRICFEVER-AUDIT.md | 补充竞品源码审计 |
| assets/ | 原创封面、图标概念与确定性SVG母版 |
| design/ | 可编辑设计源、高保真PNG与设计说明 |
| qa/ | 原型/文件结构验证结果；不是macOS验收报告 |

## 证据边界

已完成：固定源码审阅、LRCLIB一次真实HTTP200探测、独立设计、原型渲染与契约结构检查。

还必须在目标Mac执行：Swift完整编译、真实播放器/时钟/控制、TCC、WindowServer、原生材质、签名公证及长期资源测量。

还不能由代码推导：特定网络歌词来源在目标发行模式/地域下的内容授权。工程不因此全部暂停，但不能虚构曲库许可。

所有示例歌词为本轮原创排版样句，封面为本轮生成；设计样张不计为播放器支持或正式同步通过证据。
