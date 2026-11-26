# LyricTile · 续接入口

更新：2026-11-26（北京时间）。工作分支：`codex/lyrictile-standalone-20261126`；[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。

## 已定决策
- 独立原生 macOS app，未来直接嵌入 Nearpane；右侧固定歌词板，悬停同框显示控制。
- 当前架构与 ADR：`Documentation/ARCHITECTURE.md`；模块 API：`IMPLEMENTATION_CONTRACT.md`。
- 四播放器适配；真实源进度支持逐行，真实词时码和精度证据支持逐字。首版在线源 LRCLIB，本地导入/绑定/缓存可用。
- 设计快照：`Research/2026-11-26/docs/DESIGN_SPEC.md`。按需读取，不重新研究或加载完整归档。

## 实际状态
- 续接基线：`ed5bb55507a8`。独立 App、歌词格式/匹配、播放适配、原生界面、TileKit、Host 模块、打包/更新/诊断均已实现。
- 既有已测源码 `75d9e60cb8a0`：[macOS CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45750660678)，65 项测试通过，App/Host 编译、原生空态/欢迎/设置、真实 helper 装载及 ad-hoc 包检查通过。
- 本轮在分模块检查并修复异步请求、播放器会话与 UI 状态缺陷；以随后提交更新本节，不把旧验证算作新代码验证。

## 未完成与下一步
1. P0：完成本轮歌词请求/导入竞争、播放器状态和 UI 操作的具体修复及回归；提交每个单元。
2. P0：对新源码运行现有 hosted macOS CI，记录确切 SHA、结果和候选包。
3. P1：真实播放器/TCC、用户显示器与桌面环境、长稳、最终签名/公证/更新验收。

## 最小读取路径
- 先读本文件与 `AGENTS.md`，再按任务读取单个模块及其测试。
- 歌词：`Sources/LyricServices/LyricRepository.swift`、`Tests/LyricServicesTests/LyricRepositoryTests.swift`。
- 播放：`Sources/LyricPlayback/PlaybackController.swift`、`Tests/LyricPlaybackTests/PlaybackTests.swift`。
- UI：`Sources/LyricUI/LyricAppModel.swift`；独立外壳：`Sources/LyricTileApp/LyricTileApp.swift`。
- 详情索引：`Documentation/IMPLEMENTATION_STATE.md`。禁止重读完整对话、仓库、PR 差异或 CI 日志；只取失败步骤和必要片段。

## 只能在真实 Mac 完成
按 `Documentation/LOCAL_ONLY_HANDOFF.md` 做真实播放器与按需 Automation 授权、独立参考时钟精度、双屏/Spaces/全屏/睡眠唤醒、长时间资源测试，以及持有者的 Developer ID、公证和正式升级测试。普通代码开发、单元测试和 hosted macOS 构建继续由 Pro 完成。
