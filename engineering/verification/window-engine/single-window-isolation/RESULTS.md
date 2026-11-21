# StageGroup 单窗口验收

在 macOS 27.0（26A428）、SIP 开启的实体机上，**Spaces 和 Corner 均未取得生产资格**。本轮在正式 Host 启动前停止。可确认的实机结果是 WindowServer 的只读桌面清单，以及签名候选与日常安装的身份。正式侧栏整组切换、10 次和 50 次均为 **NOT_RUN**。 [机器总表](verification.json)

| 项目 | 结果 | 证据范围 |
| --- | --- | --- |
| 目标系统、签包和单实例 | **PASS** 静态签名 / **BLOCKED** 启动 | 标准路径中是另一份 5.22（90），同标识的日常 PID 59938 在场。候选单独保存在临时目录。启动检查发生在任何 App 或夹具打开之前。 [签包](04-signed-candidate.json) · [实际启动门槛](03-formal-host-preflight.json) |
| 桌面清单 | **PASS** 只读 | 修复后的两次观测，原始 20 条、不同 ID 18 个、用户桌面清单 4 项。两次顺序、ID 和重复次数一致。当时的活动项为 type 4、ID 5568。该读数来自使用正式引擎的独立只读程序。 [原始观测](01-original-inventory.json) · [修复后观测](02-checked-inventory.json) |
| Spaces 自有面板 | **BLOCKED** | 正式入口未启动，创建、迁入、返回、关闭、销毁均为零次。正式 Host 权限、前台焦点、Mission Control 的可见清单及清理后状态均无本轮实测。 [启动收据](03-formal-host-preflight.json) |
| Spaces 第三方窗 | **NOT_RUN** | 需先通过自有面板。已有透明普通应用夹具只覆盖归属和几何。可见普通窗、键盘标记、同应用旁窗及 Dock 需要独立接收者证据。 [夹具与实机入口](../../../../scripts/acceptance/window-engine/spaces/README.md) |
| Corner 单窗 | **BLOCKED** | 未建立 Guardian 恢复租约，未停放窗口。按下、拖动、释放经过生产回调的离屏测试已通过。停放窗口与旁窗各收到什么事件、真实 resize 边缘、Dock 和崩溃恢复仍无本轮实测。较早夹具实际收到了指向停放窗的鼠标按下，原 FAIL 保留。 [历史接收者失败](../../stage-groups/5.22-90/isolation/qualification/corner.json) |
| 默认引擎、整组与性能 | **NOT_RUN** | 满足实机门槛的后端为 0/2。尚无可比较的切换延迟、焦点错误率、CPU、内存或长期兼容性数据。 |

## Spaces

最初两读都返回 22 条全量记录，其中全屏 ID 5184、5568、5573 分别出现两次。每个 ID 在用户桌面清单中只出现一次，类型均为 4。此前全量读取器把任何重复 ID 判为无效。现在仅接受可与唯一全屏记录逐项对应的双份记录。原始次数、同显示器桌面顺序和直接活动 ID 都参与核对。普通桌面重复、隐藏 ID 重复、第三份副本或清单缺项仍会阻止操作。两批观测分别发生在不同时刻，两批之间的清单变化原因未测定。 [读取器、测试及原始记录](https://github.com/haohongfei2001-png/nearpane/commit/e01ae02744074c940f90aaa30ec7651bda847858)

独立面板入口使用正式 Host 的自有非激活面板、内嵌 Rust 引擎和单次持久化记录。它先验证窗口迁回及双向归属，确认 AppKit 和 WindowServer 均已观察到面板关闭，再销毁已证实空置的临时 Space。随后两次核对原始清单、普通桌面成员与前台焦点。未确认的归属保留恢复责任。 [正式 Host 入口](../../../../Sources/NearpaneHost/InstalledSpacesFixtureCycle.swift) · [运行方式](../../../../scripts/acceptance/window-engine/spaces/README.md)

## Corner

鼠标按住期间，Host 拒绝移动窗口。有在场接收者信息时，按下事件中的实际窗口编号和 PID 与最新的 CG 前后顺序对照。拖动和释放沿用各自按钮的按下决定。接收者矛盾会撤销该代引擎的写权限。恢复期间只继续保护有新读数支持的已持有窗口。离屏测试包含内存中的 Quartz 事件和两个方向的接收者冲突。它没有向系统投递鼠标事件。 [实现与专项回归](https://github.com/haohongfei2001-png/nearpane/commit/0cc4714c6cde1cf0e70bba8d430ec9de6f36d3be)

上游 Corner Park、sliver、CG 前后顺序、事件监听、PressGate 的来源有固定版本。正式库包含 CornerPatch 的几何和遮挡判断，以及签名 Guardian。当前实际绘制壁纸裁片的 AppKit 代码仍在隔离验收夹具中。正式 Host 的单窗裁片、实际输入隔离和恢复交接均待验证。 [来源清单](../../../../Engine/nearpane-window-engine/origins/corner.json) · [裁片夹具](../../../../scripts/acceptance/window-engine/corner/picture.m)

## 构建与复核

工程基线为 PR #15 的 `8e00176`。源码 `0cc4714` 在本机 26A428 和 CI 26A434 均通过 100 项 Rust、86 项 Swift 和生产 C ABI。单独的 Python 回归覆盖正式 Host 启动、资源清理与恢复。14 项分发签名缺口仍在，候选仅供隔离验收。验收入口调用前后，日常 Host 的 PID、出生代、签名和二进制摘要完全相同。 [本机源码收据](local-26A428-source.json) · [CI 源码收据](ci-corner-source.json) · [同一日常进程的两次读回](05-daily-host.json)

首次编译缺少 `CGDisplayCreateUUIDFromDisplayID` 的 SDK 声明。补入 ColorSync 头文件后编译通过。受限文件系统中的持久日志测试返回 19，独立临时目录的复测和 CI 均通过。两次原始失败日志已保留。 [开发失败原始日志](development-failures.zip) · [Spaces CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44924109238) · [Corner CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44925486801)

## 后续实机顺序

1. 在隔离的、已授权的 26A428 普通桌面中，以标准路径中的签名 Host 单独运行自有面板。核对面板事件、双向归属、前台焦点和 Mission Control 用户可见清单。
2. 自有面板通过后，登记一扇可见签名普通窗口并保留同应用旁窗。只迁移目标，验证恢复后的原始身份、几何、键盘落点与 Dock。
3. Corner 单独取得 Guardian 恢复租约，再对一扇窗口执行完整停放、真实鼠标接收者核对和恢复。两后端的实机收据各自评定。
4. 有合格后端及同机对照后再决定默认引擎。整组从正式侧栏一次 A→B→C→A 开始，同组窗口、旁窗、焦点、布局与原生手势都通过后才扩大到 10 次和 50 次。
