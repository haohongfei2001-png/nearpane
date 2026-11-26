# LyricTile · 2026-11-27 外观收敛验证

本轮运行时代码：[`39dabc3`](https://github.com/haohongfei2001-png/nearpane/commit/39dabc3ae676471a334dcb07112ee9e825f9b574)。[云端 macOS 工作流](https://github.com/haohongfei2001-png/nearpane/actions/runs/45875877384)。最终结果与文件摘要见 [verification.json](verification.json)。

## 已完成验证

macOS **27.0.1 arm64**、Xcode **27.1**、Swift **6.4**。生产 app 与宿主 facade 编译通过，**75 个 Swift Testing 测试定义 + 13 个 XCTest 用例通过**；其中原生布局参数化覆盖七个场景。候选包为 ad-hoc 签名，生产无播放隐藏检查、欢迎/设置原生窗口及 helper 加载通过。实际无播放器候选完成 121 秒空闲采样，105 点，平均单核 CPU 0.157%、RSS 中位 55.06 MiB，符合该工作流的空闲预算；不外推为真实播放或八小时表现。

## 最终设计裁决

| 场景 | 呈现 |
|---|---|
| 有真实歌曲，正在播放，歌词可显示 | 204pt 高五行歌词；中央 18–20pt，大字 22pt；近邻 14pt、远邻 12pt |
| 正在播放，歌词尚未取得或不能同步 | 112pt 高歌曲摘要，已有封面、真实歌名/歌手和简短状态 |
| hover | 原尺寸内呈现歌曲信息、播放控制和真实进度；歌词态保留当前句，遮住上下文 |
| 暂停 | 默认隐藏；仅保留用户正在操作的同一歌曲面板，交互结束即隐藏 |
| 无歌曲、停止、未知或缓冲 | 隐藏面板，并通过原有撤回屏障释放独立侧栏占位 |

短句在中央原生字形区垂直居中。长句保留字号，通过原生滚动阅读；静止视口按完整行裁剪。翻译作为当前句的补充，不替代相邻歌词。无封面使用中性符号；缺失歌手不以播放器名称冒充；未提供曲名和未知时间均明确表示缺失。

## 原生布局截图

这些图片由 **实际 `LyricPanelView`、NSHostingView、AppKit 和 CoreText** 在 macOS 中渲染，使用只存在于 `Tests` 的原创歌词；没有网页仿制图或演示播放路径。原生视图边界、五条真实相邻 cue、缺失字段和无歌曲透明性均有测试断言。

| 常态 | hover |
|---|---|
| ![五行歌词](fixture-light-lyrics.png) | ![歌词 hover](fixture-light-lyrics-hover.png) |
| ![紧凑歌曲摘要](fixture-compact.png) | ![紧凑 hover](fixture-compact-hover.png) |
| ![176pt 深色长句与翻译](fixture-narrow-dark-long-lyrics.png) | ![缺失曲名、歌手、封面与进度](fixture-missing-metadata.png) |

[无歌曲透明图](fixture-no-song-transparent.png)对应的[原生记录](fixture-no-song-transparent.json)为 `maximumAlpha = 0`、`nativeGlyphViews = 0`，没有绘制空白面板。每张图片都有同名 JSON，记录逻辑尺寸和证据性质。

**证据边界：** 这些是原生布局夹具，没有启动播放器、取得产品会话锁或发送播放命令。按钮置灰、封面采用中性符号是该测试环境的预期；图片不能证明真实歌曲封面的接收、鼠标 hover 事件或播放控制已实测。既有播放器来源与异步归属保护保持在生产路径中。

## 必要的后续界面确认

最终签名安装包仍需实际桌面复核播放→暂停→离开、再次播放、歌词异步到达时的收缩/展开，以及浅/深壁纸下的玻璃材质观感。本轮没有重新扩展播放器、歌词 provider 或 Nearpane 架构，也没有把历史实机结果计为新界面通过。
