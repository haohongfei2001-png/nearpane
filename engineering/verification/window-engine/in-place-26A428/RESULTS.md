# 5.22（90）同机原位验收

2026-11-21，macOS 27.0（26A428），SIP 开启。PR #15 的起点为 `22355d11731dc01bafef20ef59283be93f95edd1`，签名候选的源码为 `b7424a29de0e220454c13409c77189a131df6ae9`。**原位验收在退出旧 Host 前阻塞，生产资格为 0/2。** [机器总表](verification.json) · [正式监督程序的原始回执](05-installation.json)

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 日常 App、资料与恢复文件完整备份 | PASS | [源件与副本指纹](03-private-backup.json) · [跨重启保存的私有备份验签](03-durable-backup.json) |
| 候选构建、签名、单实例声明 | PASS | [签名、ABI 与源码指纹](04-signed-candidate.json) · [组件清单](04-component-signatures.json) |
| 退出旧 Host 前的归属检查 | BLOCKED | [两次指定窗口读回](02-pre-quit-recovery.json) · [Launch Services 与内核清单](05-roster.json) |
| 新版正式 Host 启动、四项自读权限、同进程普通桌面读回 | NOT_RUN | [监督程序停止的位置](05-installation.json) |
| Spaces 自有面板与第三方单窗往返 | NOT_RUN | [固定夹具与持久化回归](offline/spaces/receipt.json) |
| Corner Guardian 恢复责任移交、停放、真实鼠标隔离、还原 | NOT_RUN | [Guardian 专项离线回执](offline/guardian/result.json) |
| 收尾的日常进程、用户配置和未结记录 | PASS | [日常 Host 自读](07-daily-after.json) · [验收前后比对](07-daily-preserved.json) |

## 为何停止

日常 `com.holdsnow.nearpane.alpha` 运行于标准路径，PID 59938，出生代 1795224294017017，CDHash 为 `27a6616d7c6d916e94633986a81ba488dba21e2d`。上轮从另一路径打开同标识候选时，Launch Services 返回了这个已有进程。本轮启动器在发起打开请求前核对同标识进程清单。接受启动回执还需核对实际内核可执行文件、PID、出生代和登录会话。[上轮启动结果](../first-window-26A428/08-signed-product-scope.json) · [本轮在场清单](05-roster.json)

活动资料的 `WorkRect/ordinary/journal.json` 仍为 `pending`。窗口 33546 的 PID 为 49381，出生代为 1794932452405415。日志的原始矩形为 `(12, 33, 1211, 923)`，上一次布局后确认为 `(0, 33, 1230, 923)`。两次独立 WindowServer 读取均得到后一矩形。日志还有一次 AX 与 CG 几何不一致的拒绝记录。共享窗口锁目录中打开的描述符数为零，持久恢复记录仍然有效。该窗口属于用户正在运行的应用，本轮仅采集日志中已有身份的数值元数据。没有向它投递输入、变更几何或归档其恢复记录。[换装前原始读数](02-pre-quit-recovery.json)

监督程序保留了日常 Host。它在验收前后以同一进程代际回答了两个独立挑战，均报告辅助功能、事件投递和屏幕录制已允许。这个版本未实现事件监听预检。原 App、全部资料代、偏好和安装恢复资料的内容指纹逐项一致，未结日志的 SHA-256 也一致。本次交换次数为零，回滚为 `NOT_NEEDED`。[开始时的权限](01-daily-before.json) · [收尾证明](07-daily-preserved.json)

## 候选与恢复边界

此候选源码的 GitHub 原生 CI 已通过 93 项 Rust、68 项 Swift、生产 C ABI 链接与运行校验、12 项安装 Host 回归、23 项安装监督程序回归。CI 构建为 26A434，实际登录会话的读数单列在上述 26A428 收据中。[CI 机器结果](ci/source-result.json) · [GitHub Actions](https://github.com/haohongfei2001-png/nearpane/actions/runs/44901699295)

候选和日常版本均由 Team `ZB9D4T66QB` 签名。候选 CDHash 为 `3a0d2c5fbd1793f67d919026a4359baecb3a34c8`，保留 `LSMultipleInstancesProhibited=true`。静态打包模式只在私有目录准备 App 并严格验证签名。需要运行 Host 的资源和帮助程序自检单列为 `NOT_RUN`。首次完整编译暴露了跨 Swift 模块的可见性错误，修复后的正式构建成功。分发检查记录了 14 个尚缺正式分发签名属性的组件，本轮未做公证。[首次编译失败](offline/first-release-build-failed.log) · [成功签包日志](offline/signed-static-build.log) · [签名明细](04-component-signatures.json)

Spaces 的首次写入入口只接受固定签名夹具。它在系统写入前持久化操作意图，记录创建的资源与系统读回，跨进程拒绝重放。运行中的 Guardian 仍须认证正式 Host、持有原 AX 对象，并根据产品写前日志承担恢复责任。只读探针和已编译的恢复逻辑不能授予停放资格。此次没有创建测试窗口、临时 Space 或 Guardian 租约。两个后端继续各自等待实机验收，既有语音冷启动首次超时保留为 UNKNOWN。[跨进程日志测试](offline/spaces/durable-journal.txt) · [历史语音记录](../swift-test-events.txt)

下一轮从同一台 Mac 的日常恢复清单开始。既有窗口恢复有明确处置记录、当时的两次读回和租约清单都满足条件后，监督程序才进入标准路径候选启动。本轮不进入 10 次或 50 次测试。
