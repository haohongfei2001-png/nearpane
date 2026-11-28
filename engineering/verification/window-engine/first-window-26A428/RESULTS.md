# 首次单窗验收 · macOS 27.0（26A428）

正式 Host 的 Corner 与 Spaces 均在首次窗口写入前阻塞，生产资格 **0/2**。本轮在一块物理显示器、SIP 开启的登录会话完成了签名主体核对和开发 Host 的真实窗口双向归属测量。被测产品源码为 `666e26f`，版本为 5.22（90）。[机器总表与逐文件 SHA-256](verification.json)

| 本轮合同 | Corner | Spaces |
| --- | --- | --- |
| BUILD_PASS | PASS | PASS |
| ABI_PASS | PASS | PASS |
| HOST_PERMISSION_PASS · 含引擎的正式 Host | BLOCKED | BLOCKED |
| TARGET_SCOPE_PASS · 同一正式 Host、带签名窗 | BLOCKED | BLOCKED |
| SINGLE_WINDOW_HIDE_RESTORE_PASS | NOT_RUN | NOT_RUN |
| PRODUCTION_QUALIFIED | 否 | 否 |

## 三个签名主体

| 主体 | 源码 / CDHash | 实体机读回 |
| --- | --- | --- |
| 运行中的日常 `.alpha` | `d2d0bb6` / `27a6616d7c6d916e94633986a81ba488dba21e2d` | PID 59938，前后出生代一致。它自己的日志确认辅助功能、事件投递、录屏为允许。该版本未实现事件监听预检，也没有 Window Engine ABI。 |
| 私有目录中的产品 `.alpha` | `666e26f` / `a82bb2abda2a66d591dd7bd1d822adc2e67c55f5` | 验签、资源、ABI 1 和两个后端拒绝未获资格写入的检查通过。Launch Services 返回 PID 59938、错误码 0、精确路径不匹配。新版产品进程自身的辅助功能和输入监听均为 UNKNOWN。 |
| 独立签名的开发 `.host` | `666e26f` / `4f6bd4e0c91c3b718948b5cb2f347528556f4d6a` | 后台启动取得精确路径，Host 自报辅助功能、输入监听和事件投递均为允许。带窗测量使用 PID 98669。 |

每次均通过源版本、签名、PID 和进程出生代归属读回。首次权限观察器在冷编译工具时超时；此时尚未向日常 Host 发送诊断。后续同一日常进程在试验前后分别回答新挑战值。此次观察不足以追溯以前每一次授权弹窗的来源。[冷编译失败](01-observer-cold-compile-timeout.json) · [日常 Host 原始日志](02-installed-permissions.json) · [日常镜像能力](03-installed-scope-capability.json) · [正式包签名及 ABI](07-signed-package.json) · [Launch Services 回执](08-signed-product-scope.json) · [开发 Host 权限](09-development-permissions-and-denials.json)

## 同进程窗口读回

开发 Host 两次测到同一物理屏、同一登录会话的普通桌面 **type 0 / ID 6**。`SLSCopyManagedDisplaySpaces` 的当前记录、清单记录及 UUID 一致，每轮前后的 `SLSManagedDisplayGetCurrentSpace` 均返回 6。期间收到 0 次 AppKit Space 变更通知。NSWorkspace 提供变更通知，拥有 NSWindow 的应用可以独立读取 `isOnActiveSpace`。[首次两次读回](09-development-scope.json) · [Apple NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification) · [Apple NSWindow](https://developer.apple.com/documentation/appkit/nswindow/isonactivespace)

签名普通 App 的窗口 **61357** 由 PID **98617** 所有。两次反查均为 `[6]`，从 Space 6 正查该窗每次恰好命中一次。窗口拥有者在开始和结束时都读到 `isOnActiveSpace = true`。Host 保持了同一个原始 AX 对象，两次 AX 与 WindowServer 几何均为 `(625, 407, 220, 143)`。窗口自身透明且忽略鼠标，这次采集只证明归属与几何。夹具已关闭，进程退出，前台保持原样。公开收据以同一映射替换硬件和 Space UUID，原始 Host 回应保存在实体机私有目录并有 SHA-256。[窗口拥有者回执](11-registered-membership.json) · [同一 Host 原始字段与归属](11-registered-membership-host.json) · [公开字段一致性核验](11-public-projection.json)

历史记录中的普通桌面 4 与 type 4 桌面 5184 来自不同采样时刻和进程。本次系统读数建立了新的同期对照；历史切换原因仍为 UNKNOWN。[旧普通桌面读数](../target-26A428/corner-read-only-scope.json) · [旧 type 4 读数](../target-26A428/corner-physical-preflight/raw.jsonl)

## 动作与恢复

- **Corner**。普通 StageGroup 的 AX 绑定、聚焦和布局已经移入 Host；Rust 和 CGEventTap 同样位于 Host。独立普通窗口控制器拒绝 Stage 写入。当前实体读回确认 Host 持有原始对象；单独的 Guardian 没有该窗口的已准备租约或已确认停放记录，崩溃恢复为 BLOCKED。停放、真实鼠标按下/拖动/释放、旁窗、Dock 与精确还原均为 NOT_RUN。[71 项 Host 路径回归](05-host-ax-tests.json) · [Guardian 交接回归](06-guardian-offline.json)
- **Spaces**。正式包的 canary 入口核验标准安装路径和签名。生产资格表仍为空。当天未创建自有面板或临时 Space，第三方迁入、迁回和清单还原均为 NOT_RUN。[包内拒绝写入的回执](07-signed-package.json) · [独立探针之前的身份与权限证据](../target-26A428/exact-spaces-canary-03-preflight/result.json)
- **修复与清理**。打包曾因 Guardian 的 Mach-O 最低系统版本为 27.0 而失败，修复后通过产品的 26.0 最低版本检查。签名窗口夹具首次登记于创建窗口前退出，已定位 Foundation 对临时目录的路径规范化差异，经同目录文件身份核验后，用 POSIX 路径完成上述读回。四份临时签名 App 已核验退出、注销并移除。日常安装的 PID、出生代、签名与权限收尾读回一致。[首次打包失败](07-signed-preparation-first-failure.json) · [夹具退出证据](10-startup-exit.json) · [清理回执](12-owned-cleanup.json) · [收尾权限](13-daily-after.json)

## 独立 CI 与下一步

产品源码通过 87 项 Rust、61 项 Swift 及 C ABI 检查。托管 macOS 27.0.1（26A434）两次得到普通桌面 ID 1，同时当前与清单的 UUID 均为空字符串，环境收据为 **BLOCKED**。首轮分类的 UNKNOWN 与原始输出仍可查。此前语音冷启动的第一次超时保留为 **UNKNOWN**。[源码 CI](ci-44893427099/source-result.json) · [托管读数](ci-44893427099/reads.json) · [托管结果](ci-44893427099/hosted-result.json) · [首次 CI 收据](ci-44892866455/hosted-result.json) · [语音原始失败和复测](../swift-test-events.txt)

下一步集中在一个具备既有授权的独立 26A428 物理测试系统：以标准安装路径启动新版正式 Host，使用仅限其自有面板和一扇登记测试窗的单次验收事务，在同一进程复核权限、桌面和窗口归属，再分别验证 Corner 的输入/还原和 Spaces 的自有 canary/迁回。先取得这两份实际收据，再讨论生产资格。
