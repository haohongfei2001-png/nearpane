# 5.22（90）实施依据与模块归属

PR #15 的起点为 `6f85f73bc6b64290308ac610e342702f989a9f66`，已安装窗口版源码为 `365fdc40c19853e4fa4343f9f20c240c85b7583b`。本目录三份裁决原文取自研究提交 `3151827799a646d4a41af7f15bae6fa8c520d00b`。原生源码与 PR #14 修复均沿 PR #15 历史向前更新。冻结的 R4 窗口卡、空态及视觉令牌继续生效。

| 阶段 / 归属 | 现有入口（相对工程根目录） | 跨模块约定 |
| --- | --- | --- |
| P0 系统清单 | `Sources/CReadOnlySpaces/ReadOnlySpaces.c`、`Sources/NearpaneSpaceAction/Inventory.swift`、`Sources/NearpaneDesktopReader` | 指针显示器 UUID、真实 Space ID/UUID、初始顺序及每屏活动项 |
| P0 切换 | `Sources/NearpaneUI/NativeSidebarNavigation.swift`、`NativeSpaceActionClient.swift`、`Sources/NearpaneCore/NativeSpaceCommand.swift`、`Sources/NearpaneSpaceAction/{main,StepHandshake}.swift` | 已安装 Host 的串行管道、单次明确意图、每步许可和外部独立确认 |
| P0 版本手势 | `Sources/CNativeSpaceActions/NativeSpaceActions.m`、`GestureSerialization.c`，上游版本见 `Resources/Upstream/NativeSpaceActions/SOURCES.md` | 只在匹配的系统构建生成相邻 Dock 手势，生产能力与实机资格分开 |
| P1 迁移 | `Sources/CNativeSpaceActions/NativeSpaceActions.m`、`Sources/NearpaneSpaceAction/WindowWitness.swift` | Bridged Window Management；P0 验收前禁止集成。原 ABI 及兄弟窗集另行确认 |
| P2 身份、焦点 | `Sources/WindowGeometryCore/WindowIdentity.swift`、`Sources/NearpaneCore/OrdinaryOwnerIdentity.swift`、`Sources/NearpaneUI/{CurrentDesktopWindows,DesktopWindowSelection,HostCurrentWindowFocus,PreviewPixelCache}.swift` | PID、进程出生、窗号及代际。AXFocusedWindow 与目标文档读回分别取证 |
| P3 截图、附件 | `Sources/NearpaneTray/{TrayOwner,SystemCaptureProcess,ProductDraftBinding}.swift`、`Dependencies/domains.lock.json` 的 RiftletCapture / RiftletAdapters | 冻结接口为捕获 UUID、来源显示器及窗口身份、选区/比例与像素尺寸、文件 SHA-256、状态。草稿和上传按进程/窗口/标签页绑定 |
| P4 翻译、单词本 | `Sources/NearpaneUI/{SelectionTranslation,SidebarNotebook}.swift`、Host 服务注册 `Sources/NearpaneHost/NearpaneApp.swift` | 请求 UUID、文本摘要、模型结果、面板、事务提交及重开逐步读回。只在用户数据目录存放原文 |
| P4 语音 | `Sources/NearpaneVoice/VoiceModule.swift`、`Sources/NearpaneSaytileBridge`、锁定的 SaytileKit | 会话 UUID、首个音频帧、音频哈希、最终结果及恢复。沿用 Host 已有生命周期通知 |
| P5 生命周期、布局、性能 | `Sources/NearpaneHost/NearpaneApp.swift`、`Sources/NearpaneCore/{DesktopSessionAvailability,ManagedWindowTiler}.swift`、`scripts/acceptance/native-spaces/{lifecycle,performance}.py` | Host 接收显示器、睡眠、会话通知。布局以当前窗口身份及工作区计算 |
| P6 分发、回滚 | `scripts/{build-candidate.sh,candidate_signing.py,check-alpha-distribution.py,publish-candidate.py}` | 同一签名候选、嵌套代码、独立 Gatekeeper、公证、安装及回滚收据 |
| 分阶段证据 | `Sources/NearpaneCore/{NativeSpaceCommand,NativeRouteEvidence}.swift`、`scripts/acceptance/native-spaces`、`engineering/verification/native-spaces` | 意图 UUID、单调时间、来源及目标、投递、独立读回、终态、清理。工具结果只写标识、数量、摘要，不写私人正文 |

## 基线源码与研究假设的校正

在上述 PR 起点，`swipeEvent` 已调用 `iss_augment_dock_swipe_event`，`NPSendAdjacentSwipe` 已生成伴随事件并检查指针显示器。故不能把失败归因于完全缺失 IOHID。实际差异是普通动画使用六个增大行程的采样，结束速度为 2，并允许一次请求包含多步。最小修订是保留并测试现有序列化器，按版本统一轻行程、相位与结束速度，限制首轮为单一相邻动作，以安装版来回读回决定是否启用。原有空白侧栏只通过真实窗口或显式组合触发导航，不添加测试专用生产行。

各阶段所需的可运行验收及门槛见[实施验收入口](../verification/native-spaces/ACCEPTANCE.md)。
