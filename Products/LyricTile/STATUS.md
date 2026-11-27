# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；开发分支 `codex/lyrictile-standalone-20261126`，[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。

## 本轮精修

- 192pt 外框固定。普通句保留五句上下文；当前句超过两行时退为三句上下文，为主句让出三至四个完整文字行，不缩小字号。测量与显示使用同一 CoreText 排版；极长句仍可原生滚动。
- hover 主句最多保留两完整行，为封面、曲名、控制与进度留出空间；当前句中心不跳动。原生视图在高度变化时明确更新裁切和溢出指示。
- 104pt 紧凑摘要；hover 前后歌曲封面与标题位置一致。点击封面返回实际播放器，歌曲菜单保留入口；浏览歌词时提供返回当前句按钮。未知字段不伪造。
- 同一 18pt 圆角与已有轻材质。欢迎页收紧为 400×360，保留真实图标、自动显隐和在线查找告知；设置按外观、播放与歌词、通用分组，桌面位置等低频选项折叠。
- 暂停仅在用户实际操作面板时保留；独立辅助窗口不再强制显示控制区或钉住暂停面板。
- 侧栏按实际 104/192pt 占位。收缩延迟一秒合并短暂查找，随后回收原先 88pt 空位；扩容先撤回并通过既有协调屏障。无播放不注册空槽，用户排列顺序保留。

## 验证状态

本次新增正常长句完整阅读、最窄大字 hover、同一原生视图高度切换，以及侧栏收缩/扩容与旧授权失效的风险断言；原生编译、测试及截图复审待本次 CI 完成。上轮 `ca361e9` 的 [CI31](https://github.com/haohongfei2001-png/nearpane/actions/runs/45881886204) 已通过，证据仅覆盖当时的一/两行当前句及旧欢迎/设置布局：[上轮截图与证据](Documentation/Verification/2026-11-27-ui-refinement/README.md)。

本轮不扩展播放器、歌词服务、Nearpane 架构，不发布新版本。实际歌曲、鼠标交互、壁纸玻璃观感、侧栏联排及签名安装包仍待专项实机验收；已有安装基线 1.0.0（4）不变。详见[本机报告](Documentation/Verification/local-2026-11-26.md)与[界面实现](Documentation/UI_IMPLEMENTATION.md)。

## 已安装构建 4 的发行候选

11 月 27 日 03:20 完成八小时实机长稳。构建 4 在同一进程下记录 27,053 次观测，混合工况 CPU 均值为单核 0.65%，RSS 中位/峰值 33.80/118.42 MiB。该包内源码为 `3e83b5c`，早于本轮界面重做。App 与 DMG 均已公证，构建 2 至 4 的升级通过。正式公开发行仍缺 Spotify 已登录播放验收及在线歌词展示、缓存的适用授权依据。物理 DELL 和整机睡眠唤醒尚未实测。[长稳数据](Documentation/Verification/2026-11-26-local/eight-hour-runtime.json) · [Release 草稿](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-97927bb5d7506543a099)
