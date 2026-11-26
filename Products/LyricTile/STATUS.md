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
- 已修复登录启动设置：等待系统允许时可取消注册；从系统设置返回会刷新真实状态；复用 UI 不会替 Nearpane 注册登录项。本轮新代码的 macOS CI 待运行，不沿用旧验证结果。
- 已修复歌词仓库：本地导入/绑定使旧在线请求失效，关闭再开启在线查询不会复活旧请求，清缓存不会被迟到的空结果重建负缓存；新增 3 个挂起请求回归用例。
- 已修复播放器：稀疏元数据保留曲目身份、空 ID 不共用指纹、媒体子进程重启建立新会话；控制读回核验时钟/新鲜度/源所有权，seek 读回匹配实际速率和曲尾；新增 6 个回归用例。
- 已修复 TileKit：已确认退出且窗口消失的组件会释放当前/待定占位，不再让剩余组件永久等待它确认；保留存活窗口撤回屏障，新增 2 个回归用例。
- UI 异步操作修复正在整合；每个有效单元独立提交。

## 未完成与下一步
1. P0：整合 UI 操作修复及回归；提交该单元。
2. P0：修复 hosted CI 公共依赖下载凭据错误，再完成新源码编译/测试/打包；首轮 `532a41da6a7f` 在下载依赖时失败，未进入编译或测试。
3. P1：真实播放器/TCC、用户显示器与桌面环境、长稳、最终签名/公证/更新验收。

## 最小读取路径
- 先读本文件与 `AGENTS.md`，再按任务读取单个模块及其测试。
- 歌词：`Sources/LyricServices/LyricRepository.swift`、`Tests/LyricServicesTests/LyricRepositoryTests.swift`。
- 播放：`Sources/LyricPlayback/PlaybackController.swift`、`Tests/LyricPlaybackTests/PlaybackTests.swift`。
- UI：`Sources/LyricUI/LyricAppModel.swift`；独立外壳：`Sources/LyricTileApp/LyricTileApp.swift`。
- 详情索引：`Documentation/IMPLEMENTATION_STATE.md`。禁止重读完整对话、仓库、PR 差异或 CI 日志；只取失败步骤和必要片段。

## 只能在真实 Mac 完成
按 `Documentation/LOCAL_ONLY_HANDOFF.md` 做真实播放器与按需 Automation 授权、独立参考时钟精度、双屏/Spaces/全屏/睡眠唤醒、长时间资源测试，以及持有者的 Developer ID、公证和正式升级测试。普通代码开发、单元测试和 hosted macOS 构建继续由 Pro 完成。
