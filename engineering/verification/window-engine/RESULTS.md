# Nearpane 5.22 Window Engine 验收

本轮单窗结果由 `666e26f` 的签名 Host 与实体机收据给出。开发 Host 的双向归属和原始 AX 对象已实测。正式 Host 单窗动作受启动身份阻塞，Corner、Spaces 的生产资格均未取得。[本轮六级门槛、清理与原始记录](first-window-26A428/RESULTS.md)

## 上一轮集成基线

生产资格为 **0/2**。正式 Host 的 A→B→C→A 为 **NOT_RUN**。签名开发 Host 与本轮 CI 对应源码 `ddac854`，接续草稿 PR #15 的 `0dd9cb2`，包含 Riftlet 1.0.7（53）和 Saytile 0.20（533）。 [本轮机器可读结果](verification.json) · [集成方案](../../research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)

| Gate | 已验证 | 尚需实证 |
| --- | --- | --- |
| 0 · ABI | arm64 和 x86_64 静态库、同一 C/Swift/Rust 布局、有限队列、取消、超时与 panic 边界通过。固定 MIT 原文、文件来源与 Cargo 锁文件可核对。 | Intel 结果仅覆盖编译和架构检查。 [ABI](gate0.json) · [上游来源](origins.json) |
| 1 · Corner | 接入角落选择、AX/CG 双读、实际 Z-order、完整按下至释放的 PressGate、真实壁纸裁片和独立 Guardian。离线测试覆盖未确认窗口、失效的事件监听器与恢复前用户输入。 | **BLOCKED**。精确系统上的独立探针没有辅助功能和输入事件授权，两轮当时读到的桌面类型均为 4。未创建测试窗或提交停放。真实点击、调整尺寸边缘、三组切换和崩溃恢复仍待验证。 [实体事件](target-26A428/corner-physical-preflight/) · [恢复测试](gate1-packaged-guardian.json) |
| 2 · Spaces | 经典和 bridged 路线通过类型、对象生命周期和归属往返的离线测试。启动探针仅能操作自己新建的无激活面板。Host 要求原始成员归属、面板关闭和临时 Space 销毁分别成立。 | **BLOCKED**。目标机签名探针的 self/guest 身份校验均通过，自身辅助功能为否，窗口及 Space 写入均为零。 [精确系统预检](target-26A428/exact-spaces-canary-03-preflight/result.json) · [ABI 与测试](../../../scripts/acceptance/window-engine/spaces/launch-verification.json) |
| 3 · Host 事务 | 单一写入者、窗口身份、写前日志、接收方先恢复、旧组逐窗释放及未确认时冻结均已接入。签名开发 Host 可从 Launch Services 后台独立读取结果。 | **NOT_RUN**。仍缺标准安装 Host 的真实侧栏点击、组合窗口复原、完整键盘输入落点。 [事务回归](gate3-transaction-tests.json) |
| 4 · 性能 | 验收器复核双向原始时钟、首帧、焦点/输入接收者、逐帧色标、资源和恢复记录。10 项专项测试通过。 | **NOT_RUN**。单次安全门槛未通过，10、50、同机 Apple 每方向 100 个样本和随后 1000 次压力均未启动。P50/P95/P99 无实测值。 [目标机性能收据](gate4-target.json) · [测量合同](../../research/NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md) |
| 5 · 产品生命周期 | 新普通窗口通过真实 AX 建窗通知、同屏同桌面及连续两次目录读回加入已有组。归组只登记成员。显示器和原生桌面变化、睡眠唤醒、退出前恢复及资料切换已接入 Host 的所有权检查。 | **NOT_RUN**。正式 Host 的新窗口归组、两块实体显示器、原生全屏和 Split View、系统接管、真实睡眠唤醒及崩溃恢复仍需整组实测。 |

### 同一台 Mac 的两次观察

在 macOS 27.0（26A428）、SIP 开启的实体 Mac 上，第一份只读记录连续两次确认普通桌面 4 及其 UUID。之后的 Corner 探针两次读到另一条系统记录，类型为 4。两次观察分开存档。两者都没有对其间用户看到的桌面执行选择或迁移。 [普通桌面读回](target-26A428/corner-read-only-scope.json) · [后一次独立读回](target-26A428/corner-physical-preflight/raw.jsonl)

同一份 Developer ID 签名开发 Host 在直接调用和 Launch Services 独立后台启动时，都读到辅助功能和输入事件允许。两次都成功拒绝了未取得资格的窗口写入。Corner 和 Spaces 各自的独立验收进程读到自身授权不足。日常安装此前重复请求授权的原因仍为 **UNKNOWN**。 [签名 Host 的两次读回](target-26A428/signed-development-host.json)

### 保留的失败与修复

- 第一轮托管运行中，Corner 无法确认普通桌面身份。Spaces 夹具在建窗前链接失败。使用相同静态库复现了缺少 Carbon 的符号，修复后的夹具完成链接与验签。 [首次运行](runs/44881106930/) · [链接诊断](../../../scripts/acceptance/window-engine/spaces/combined-link-receipt.json)
- 第二轮托管机为 macOS 27.0.1（26A434）、SIP 关闭。两次只读观察均返回桌面编号 1，当前及对应普通桌面条目的 UUID 均为空。Corner 完成 0 圈。Spaces 已编译，动作收据为 0。 [原始记录](runs/44882622947/)
- 实体机第一次启动 Spaces 隔离探针时，launchd 无权打开工作区内的标准输出文件，进程未进入 main。改用私有临时日志后，探针发现 Foundation 和 POSIX 对临时目录的路径拼写不同。统一路径后，独立签名身份验证通过，已有辅助功能授权检查阻止派发。 [第一次](target-26A428/exact-spaces-canary-01/) · [第二次](target-26A428/exact-spaces-canary-02/) · [最终预检](target-26A428/exact-spaces-canary-03-preflight/)
- 源码 `ddac854` 的原生协议和内嵌工具 CI 通过。窗口引擎 CI 的 87 项 Rust 测试通过，托管 GUI 的两次读回均缺少普通桌面 UUID，整项作业以失败结束。Corner 和 Spaces 的系统验收记录为 **BLOCKED**。 [原生协议](https://github.com/haohongfei2001-png/nearpane/actions/runs/44885716259) · [内嵌工具](https://github.com/haohongfei2001-png/nearpane/actions/runs/44885716248) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44885716283) · [完整托管收据](runs/44885716283/)
- 本机同源码全量 Swift 回归共 698 项。首次与开发包编译同时运行时，静音 PCM 夹具触发断流保护。单项重测耗时 0.323 秒并通过。编译结束后独立运行全量回归，695 项通过、3 项按环境跳过。缺少首次超时的完整归因。窗口调度专项 49 项及性能验收器 10 项分别通过。 [首次失败与两次复测](swift-test-events.txt) · [指标及日志摘要](verification.json)

### 构建与回退

从仓库根目录运行 `bash scripts/build-app.sh debug` 可构建完整开发包。`bash scripts/test.sh` 运行 Swift 和跨语言集成测试。Rust 使用 Cargo 锁文件并离线编译。开发包内携带固定原作者许可证及各模块的文件来源。 [Rust 源码和 ABI](../../../Engine/nearpane-window-engine/) · [签名开发包验证入口](../../../scripts/acceptance/window-engine/probe-development-host.py)

日常安装独立于开发包。恢复已有窗口时，先保留旧所有者的日志，只对进程代际、窗口身份、归属和几何均可确认的成员执行恢复。未能确认的成员保留记录并阻止切换后端。源码回退基线为 `0dd9cb2`，可用独立 checkout 复核。 [单独恢复程序](../../../Engine/nearpane-window-engine/src/corner/guardian/README.md)

开发 ZIP 解包后通过完整嵌套签名校验，核对了 Host 可执行文件 SHA-256、CDHash 和源码版本。包内沿用开发标识 `com.holdsnow.nearpane.host`、版本 0.2.0（1）。日常安装为 5.22（90）、源码 `d2d0bb6`，测试前后 CDHash 一致。6 个临时测试目录共 7 个 App 已清理。 [开发包指纹](development-archive.json) · [清理收据](target-26A428/fixture-cleanup.json)
