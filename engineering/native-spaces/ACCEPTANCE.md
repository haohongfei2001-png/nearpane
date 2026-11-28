# 独立台前调度验收入口

2026-11-26：唯一现行依据为[独立台前调度裁决](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md)。

原 Apple 原生条带及 Corner 遮罩验收合同已归档。当前必须验证非活动第三方窗口真实离开工作区，并由正式 R4 恢复。

- [当前状态](STATUS.md)
- [实现与原始验证证据](../verification/independent-stage/README.md)
- [统一构建及本机自动验收入口](../../scripts/acceptance/independent-stage/README.md)

## 必须分开的证据

- 源码编译、Swift/Rust/FFI 与状态机测试。
- 引擎自己的窗口探针。
- 两个独立进程的真实窗口隐藏与恢复，含同应用双窗、旁窗和双向 Space 归属。
- 正式 R4 选择、组内精确焦点、合并与拆分、黄色按钮。
- 系统总览、桌面切换、全屏、Split View、桌面显示、正常与异常退出恢复。
- 实际目标 macOS 27.0 / 26A428 / Apple Silicon / SIP 开启；其他机器单列。
- 完整应用、签名、公证、最终安装与连续操作。

API 返回、合成状态测试、CI 绿色和自身窗口成功都不能替代第三方窗口的真实回读。缺前置是 BLOCKED/NOT_RUN，实际不符才是 FAIL。输出必须保留原始失败及最终清理；不将模拟 Control-arrow 记为实体三指手势。

[本文件此前的完整原文](archive/ACCEPTANCE-pre-independent-20261126.md)仅作为历史依据，不再指导当前开发或自动回退。
