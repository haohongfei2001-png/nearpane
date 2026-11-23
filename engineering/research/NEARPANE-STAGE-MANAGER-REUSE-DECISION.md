# Nearpane 窗口引擎复用裁决

采用 Swift Host、进程内 Rust staticlib 和版本化 C ABI。上游固定为 `eugene-tea/stage-manager@69a73665488243bf78982c6d523ac4e0850c1ddb`。本文件落实[窗口可见性裁决](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md)。原先允许临时 Spaces 参与生产自动选择的条款已废止，原因是该机制在工作组切换期间改变原生窗口归属。[原版裁决与来源](https://github.com/haohongfei2001-png/nearpane/blob/7d099c7/engineering/research/NEARPANE-STAGE-MANAGER-REUSE-DECISION.md)

## 执行责任

- Swift 拥有 R4、StageGroupStore、StageGroupCoordinator、窗口存活身份、布局、意图日志和恢复决策。
- Rust 的工作线程拥有逐窗执行、事件 tap、按键手势生命周期、独立 WindowServer 读回和恢复辅助。请求使用固定宽度 POD、intent、epoch 和有界队列。CF/AX 对象由取得者管理，Rust panic 留在 FFI 内。
- 产品 Provider 仅考虑符合当前桌面不变合同的实现。暂时停放到另一原生 Space 的机制保留为隔离研究，未获准的 Provider 返回 unsupported。
- Corner 必须完整保留手势隔离、角落和边界命中、裁片、Guardian、写前租约及原始几何恢复。旧遮罩失败证据和上游速度数据均不能赋予写权。
- 单个窗口同一时刻只有一个写入者。健康检查失败时原执行器先归还确切持有的窗口，任何未知状态保留原责任。

## 4. What to preserve from Nearpane

Preserve unchanged in principle:
- `Sources/NearpaneCore/StageGroupStore.swift`: product-owned persistent group/member IDs, display partitioning and layouts.
- `Sources/NearpaneCore/StageGroupCoordinator.swift`: write-ahead transaction, before/after records, input epoch, ownership and recovery decisions.
- `Sources/NearpaneSpaceAction/WindowWitness.swift`: strong process birth + PID + CGWindowID + AX identity + same-app sibling inventory and independent CG/AX geometry checks.
- `Sources/NearpaneOrdinaryWindowController/WindowMonitor.swift`: existing AX observer and window lifecycle monitoring, subject to a clear single owner for AX access.
- R4 presentation, preview pipeline, exact focus path, auto-tiling and tool integrations.
- Nearpane performance standard and its PASS/FAIL/UNKNOWN/NOT_RUN definitions.

Replace or consolidate:
- the current experimental visibility driver behind `StageWindowSession` with the Rust backend adapter;
- duplicate AX frame/park code that would otherwise compete with the Rust worker;
- any overlay-only or minimized-state path that is represented as full input-safe hiding without a qualifying input isolation mechanism;
- any second authoritative group/visibility persistence model copied from upstream.

Retain as read-only diagnostics:
- existing Native Space inventory and membership reader;
- existing display topology and native Space UUID observation;
- existing exact focus and window witness paths where they do not race the Rust backend for AX writes.

Delete only after parity and migration tests prove they are unused. No bulk deletion of the archived experiments is authorized by this decision.

## 7. MIT, signing and notarization

Upstream is MIT. Preserve the original full license and copyright notice for copied substantial portions. Add `THIRD-PARTY-NOTICES.md` and an origin manifest mapping every vendored file to upstream path and commit. Modified files must retain notice and state that Nearpane modifications were made.

Run a dependency license audit against the exact extracted Cargo.lock graph. MIT on the top-level project does not automatically clear every transitive dependency.

Static linking does not eliminate code signing: final Nearpane.app must pass deep signature verification, Hardened Runtime requirements, Developer ID Gatekeeper assessment, notarization and clean-machine install/upgrade/rollback. SkyLight private API use remains a distribution and OS compatibility risk regardless of license.


[上游固定文件来源与许可证](../verification/window-engine/gate0-origins.json) · [实施计划](NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)
