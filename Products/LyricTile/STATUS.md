# LyricTile · 续接入口

更新：2026-11-26（北京时间）。分支：`codex/lyrictile-standalone-20261126`；[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。只读本入口及下一任务的必要文件；不检索旧对话、整仓、完整 PR 或测试日志。

## 产品与技术决策
- 独立原生 macOS 歌词板；右侧固定尺寸、悬停同框控制，未来原生嵌入 Nearpane。
- 架构与 ADR：`Documentation/ARCHITECTURE.md`；API：`IMPLEMENTATION_CONTRACT.md`；设计按需读 `Research/2026-11-26/docs/DESIGN_SPEC.md`。
- 四播放器适配；真实进度逐行同步，真实词时码加精度证据启用逐字；首版网络源 LRCLIB，本地绑定/导入/缓存可回退。

## 当前完成状态
- App、歌词服务、播放器、原生 UI、TileKit、Host 模块、打包/更新/诊断均已实现。
- 本轮修复：导入/在线请求及缓存竞争；稀疏或空曲目 ID、媒体进程重启、控制读回与 seek；UI 异步操作、切歌撤销旧选择器/拖动、hover 收起；退出组件的布局死锁；登录项真实状态同步。
- 增加 14 个回归用例；每个有效开发单元已独立提交。CI 使用临时、仅针对两个已锁定公共依赖的只读认证，版本及权限未扩大。

## 本机排列恢复
- 显式拖动现在保存所选显示器。协调排列保存组件顺序，退出后释放占位，重开仍按用户顺序排列。独立注册表实测通过（两个组件重开后顶边为 16 / 298 pt），新增回归用例。

## 最新实际验证
- 源码 [`123fd0bd1433`](https://github.com/haohongfei2001-png/nearpane/commit/123fd0bd1433ee2a20b7d4bd2f07b26920781b00)；[macOS CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041)；[ZIP/DMG 候选](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041/artifacts/15105338706)。
- macOS 27.0.1 / Xcode 27.1 / Swift 6.4 / arm64：79 测试通过（12 XCTest + 67 Swift Testing），零失败、零跳过；App/Host 编译、3 个原生界面、真实 helper 装载与 ad-hoc 包检查通过。
- 120.64 秒 hosted idle：CPU 0.33157% 单核（预算 0.3%，本次未达）；RSS 中位/峰值 54.28/61.14 MiB（达标）。随后 profile 以等待为主，未识别失控循环；不把不同主机的旧数据当作受控回归对照。
- 摘要与原始小型证据：`Documentation/Verification/2026-11-26-continuation/README.md`。后续纯文档提交不改变以上已测源码与包哈希。

## 剩余任务与下一轮起点
1. P1：真实播放器/TCC、双屏/Spaces/睡眠唤醒、精度及长稳验收；核实实机空闲 CPU。当前没有可由 CI 替代的真实播放通过记录。
2. P1：持有者 Developer ID、公证、实际 Sparkle 升级及正式发布配置；当前仍为工程候选。
3. 下一轮 Pro 先读本文件、上述验证摘要及 `Documentation/LOCAL_ONLY_HANDOFF.md` 的具体未完成项。按真实失败证据修复，不重复设计/建工程/全量读取。
4. 定位入口：歌词 `Sources/LyricServices/LyricRepository.swift`；播放器 `Sources/LyricPlayback/PlaybackSelection.swift`；UI `Sources/LyricUI/LyricAppModel.swift`；布局 `Sources/TileKit/TileRegistry.swift`，各自对应 Tests。性能若有新证据再读 `Sources/LyricPlayback/NativePlayers.swift` 与 `Sources/TileKit/TileDesktopCoordinator.swift` 的进程发现路径。

## 必须由本机 Codex 执行
仅执行上述真实播放器、系统授权、用户显示器/桌面、独立时间参考、长时采样及持有者签名/公证/升级事项，按 `Documentation/LOCAL_ONLY_HANDOFF.md` 保存脱敏证据。普通源码修复、回归与云端编译继续由 Pro 完成。

## 本机打包与更新
- macOS 27.0 实际 Sparkle 安装器验证通过：错误签名保留 build 1、正确签名替换到 build 2，签名完整性通过。使用隔离副本和临时密钥。已修复包内残留本机 CLT 路径，详见 `Documentation/Verification/2026-11-26-local/sparkle-install.md`。
- 已核对 LRCLIB 官方 API 和授权询问，确认客户端识别要求，未找到歌词显示、适用地域或作品署名授权；详见 `Documentation/THIRD_PARTY_NOTICES.md`。
- 持有者签名 App 默认连接本分支 LyricTile 专属空更新目录，下载在解压前校验 Ed25519 签名。更新密钥保存在本机专用钥匙串条目。

## 本机逐行渲染

初版在 M5 实际显示 Apple Music 的本地逐行歌词，120.13 秒 CPU 单核均值 3.59%，RSS 中位 88.88 MiB。按同一进程的采样优化了隐藏控制区、静态文本重绘和重复录音身份计算，保留原有播放读回频率、时钟规则和转场。本机 release 编译通过，最终包资源数据以本机验收记录为准。
