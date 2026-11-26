# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；开发分支 `codex/lyrictile-standalone-20261126`，[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。

## 本轮视觉复审与优化

- 192pt 五行歌词；当前句按实际宽度使用一或两完整字形行。外框不随句长变化。上下文提高对比度，超长当前句保留原生滚动并显示真实溢出指示。
- 104pt 紧凑摘要；hover 前后歌曲封面与标题位置一致。点击封面返回实际播放器，歌曲菜单保留入口；浏览歌词时提供返回当前句按钮。未知字段不伪造。
- 同一 18pt 圆角，降低玻璃材质覆盖层的不透明度；高对比度/减少透明度仍使用实色。欢迎页使用应用图标，设置中直接展示在线查找与自动显隐说明。
- 暂停仅在用户实际操作面板时保留；独立辅助窗口不再强制显示控制区或钉住暂停面板。
- 保留最大 192pt 的侧栏占位，避免歌词异步到达时推动其他工具；紧凑态在已注册的侧栏可能留下 88pt 未绘制区域，此为当前协调策略的取舍，而非已解决的动态排版。

## 验证状态

本轮运行时代码 `ca361e9` 的 [CI31](https://github.com/haohongfei2001-png/nearpane/actions/runs/45881886204) 全部通过：生产编译、75 个 Swift Testing 测试定义与 13 个 XCTest 用例、候选包启动及无播放隐藏、helper 加载。七种原生布局及欢迎/设置截图已复审；192/104pt 尺寸、短句一行、长句两完整行、紧凑 hover 对齐、无歌曲透明均通过。实际无播放器候选空闲采样 121 秒、110 点，单核 CPU 均值 0.099%，RSS 中位 55.25 MiB。[本轮截图与证据](Documentation/Verification/2026-11-27-ui-refinement/README.md)。此前 204/112pt 截图保留为历史证据。

本轮不扩展播放器、歌词服务、Nearpane 架构，不发布新版本。实际歌曲、鼠标交互、壁纸玻璃观感、侧栏联排及签名安装包仍待专项实机验收；已有安装基线 1.0.0（4）不变。详见[本机报告](Documentation/Verification/local-2026-11-26.md)与[界面实现](Documentation/UI_IMPLEMENTATION.md)。

## 已安装构建 4 的发行候选

11 月 27 日 03:20 完成八小时实机长稳。构建 4 在同一进程下记录 27,053 次观测，混合工况 CPU 均值为单核 0.65%，RSS 中位/峰值 33.80/118.42 MiB。该包内源码为 `3e83b5c`，早于本轮界面重做。App 与 DMG 均已公证，构建 2 至 4 的升级通过。正式公开发行仍缺 Spotify 已登录播放验收及在线歌词展示、缓存的适用授权依据。物理 DELL 和整机睡眠唤醒尚未实测。[长稳数据](Documentation/Verification/2026-11-26-local/eight-hour-runtime.json) · [Release 草稿](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-97927bb5d7506543a099)
