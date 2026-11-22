# PR #15 单机夜间验收

**最终结论为 P0 BLOCKED、P1 BLOCKED、生产资格 0/2。** 最后一段普通桌面准入使用源码 `075fdf8655246f95a29f3808db1fcb4c4bf7685f`。三段准入观察实际展示 Mission Control 共 0 次，唯一正式 Host 一直运行。[逐阶段机器判定](13-stage-verdicts.json) · [PR #15](https://github.com/haohongfei2001-png/nearpane/pull/15)

起始 GitHub HEAD 为 `911189d94545f13cb1b6b56862360a669735d3ea`，分支为 `codex/r4-native-candidate-20261120`。2026-11-22 23:57（上海），26A428、SIP 开启、arm64。唯一运行的正式 Host 为 5.22（90）、`bec6cb2`、PID 32364、出生代 1795343882268848。四项权限由 Host 自读。配置取本轮起始摘要，活动共享租约为零。[起始身份和配置摘要](01-initial-host.json)

| 阶段 | 状态 | 实际操作和证据 |
| --- | --- | --- |
| P0 基线 | BLOCKED | 从起始 HEAD 重建观察器。六分钟内出现原生全屏和普通桌面 4、6，未同时取得稳定普通桌面、前台窗和输入空闲。展示 0 次。[基线记录](02-baseline.json) |
| 上次 Edge 到 GitHub Desktop 的前台变化 | 变化已证实，发起方 UNKNOWN | Launch Services 的结构化 SETFRONT 明确给出旧 PID 48228、新 PID 56354 及时间。该事件记录前台提交，无请求方字段。[系统记录](03-prior-system-front.json) |
| P1 单窗 | BLOCKED | 须由本轮完整 P0 收据准入。 |
| 三组切换、10/50 次、Corner/Guardian、性能 | NOT_RUN | 单窗口往返尚未通过。两后端生产资格为 0/2。 |

原始机器文件只写入新的私有目录。公开证据保留允许的身份字段、观测时序、状态和原件摘要。每轮以同一 Host、同一启动代及其同次收据作为下一阶段的入口。验收后重新核对进程、配置、权限和租约。

观察器已加入 Workspace 启动、退出、激活、隐藏、取消隐藏、Space 和会话变化通知。相同单调时钟记录原 AX 对象、两款目标应用的 AX 窗口及 WindowServer 几何和双向归属。Host 遥测逐次记录实际返回值，等待响应期间主线程可以接收系统通知。源码版 Host 为 Dock 读取附加起止时间；已安装版本仅返回缓存值与观察来源。修订观察器 SHA-256 为 `0f7c2d8190c4d13786d64ab8e3fbcc0461aa25eb1d562685086d0871f7be211c`。本轮先核对普通桌面准入，成功后自动运行现有单窗监督器。

### 00:10 至 00:16 的正式入口

源码 `199715ea264e7f8755074bddf80d4c33791e92ff`。在同一登录会话收到了 4 条带进程出生代的激活通知。普通桌面 6、4、6 的状态变化采样分别距离最近输入约 4、16、2 毫秒。曾读到的 139 秒空闲发生在原生全屏。该时段展示 0 次，原窗口连续性未测。正式监督器返回 `p0RequiredBeforeQuit`，退出请求为零。[实机准入和激活时间线](04-ordinary-admission.json) · [P1 回执](05-p1-gate.json)

复核上次真正展示时的系统事件，唯一一条 Edge → GitHub Desktop 的 SETFRONT 后约 15.9 毫秒，WindowManager 在普通桌面 4 记录前台连接变化。查询范围内没有可以绑定到请求方的发送、接收和目标链。历史焦点漂移的发起方仍为 UNKNOWN。[结构化系统事件](06-historical-system-timeline.json)

00:23 的独立只读核对使用 SHA-256 为 `965b4d84a92ffbcdea125f6cb23e27883bb6ee789abdda25f1841a0b1a818a1b` 的观察器。原生全屏 5184 上，GitHub Desktop 窗口 17742 的反向归属为桌面 6，在当前 Space 的正向命中为 0，Quartz 的可见清单中没有该窗。Edge 进程仍是同一代，原窗口 68518 此刻未在其五个普通层窗口中。这个读数只对本次采样有效。Swift 和 Python 读取的 14 类 HID 计数一致。32 个真实系统日志时间戳在采样两端均与 `mach_continuous_time` 和单调时间线吻合。[窗口和前台元数据](07-passive-window-readback.json) · [输入读回](08-live-hid.json) · [时钟校准](09-physical-clock.json)

第一阶段的原生引擎和 5.22 协议 CI 均通过。托管构建完成 102 项 Rust 和 91 项 Swift 测试，并验证生产 C ABI。[引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45042709665) · [5.22 协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45042709671)

### 最终实机结果与清理

00:23 至 00:29，404 个连续准入样本均为原生全屏 type 4。期间最大输入空闲约 1,039 秒，结束时直接读取的活动 Space 为 5184。本轮可见桌面条、原焦点双读和 Host 四阶段时序均为 **NOT_RUN**。上次普通桌面已通过的缩略图、焦点失败及真实影像继续保留。本轮没有发生可录制的新展示。[本轮全量计数与时间线](10-final-observation.json) · [上次真实录屏与原始 AX 证据](../p0-p1-admission-26A428/RESULTS.md)

正式 `spaces` 监督器读取本轮私有 P0 收据，摘要与公开投影登记的原件摘要相同，返回 `p0RequiredBeforeQuit`。正式 Host 退出请求、第三方窗口登记、迁入和迁回均为 0。A→B→C→A、10 次、50 次、Corner 单窗、Guardian 恢复，以及与 Apple Stage Manager 的双向 100 样本性能对照均为 **NOT_RUN**。两个后端的生产写入继续关闭。[最终 P1 回执](11-final-supervisor.json)

结束时正式 Host 的 PID、出生代、CDHash、Team ID、配置文件摘要和索引摘要逐项相同，四项权限由该进程重新读回。按上一次使用的算法组合配置和索引摘要，结果同为 `b6248b5b3e9df2fc2dbfa69a291167eefc03f0a1085e74a2ebb0f3a31c92fce0`。独立清理读数确认一块内置物理显示器，原生清单连续两次为 4、5568、6、5184，签名测试夹具进程为 0，活动共享租约和阻塞恢复记录为 0。[最终资源与签名](12-resources-and-host.json)

已安装源码的定时器间隔为 350 毫秒，容差为 80 毫秒，旧正式 Host 返回最近一次读取的状态。上次展示和收起分别读到旧值 0 和 1。本轮复核该时段正式 Host 日志，未取得带时间戳的内部采样事件。因此实测轮询周期、缓存与前台漂移的因果关系仍为 **UNKNOWN**。源码现已附带实际 Dock 读取的起止时间。该次源码 CI 在 26A434 完成 102 项 Rust、91 项 Swift、30 项 Host 验收脚本测试、23 项安装监督器测试及生产 C ABI 链接与读回。[缓存与物理遥测](15-host-cache.json) · [CI 原始收据](14-source-ci.json) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45044110858) · [5.22 协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45044110835)

### 终次遥测期间的输入与焦点

先前的观察器在等待最后一次 Host 回复之前就结束了 HID 及原生 Space 读数。修复后，收到回复才核对原 AX 对象、Dock、Space 清单和输入计数。监督器会拒绝缺失、倒序、过期或焦点对象不同的收据。00:45 的实机只读核对中，正式 Host 在约 320 毫秒后答复，随后才开始读焦点并结束 14 类输入计数。前后计数一致。当时处于原生全屏且没有合格的普通前台窗，焦点读数为 UNKNOWN。这次只读调用未展示 Mission Control。最后一轮准入所用的五个程序也已在两个独立目录重建，文件摘要逐一相同。[终次读回](17-terminal-readback.json) · [独立重建](16-reproducible-build.json)

### 最终源码与 GitHub CI

最终源码为 `9cbe165e81630abf9fc50ad5e5f1aa7b65228529`。从这次已提交的源码独立重建，五个程序与 00:45 只读采样使用的版本逐个一致。两项 GitHub Actions 均已完成。引擎工作流通过了 102 项 Rust、91 项 Swift、30 项 Host 验收脚本和 23 项已安装 Host 监督器测试，生产 C ABI 完成链接和执行。5.22 协议工作流中的两个托管收据均记录夹具已退出、临时配置已清理，同时将正式 Host 和整组可见性切换记为 NOT_RUN。实机准入和生产资格沿用上表结论。[CI 收据与独立重建](18-final-ci.json) · [Rust、Swift 和 C ABI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45045824760) · [原生 5.22 协议](https://github.com/haohongfei2001-png/nearpane/actions/runs/45045824688)

### 恢复执行入口

下一次操作条件为同机自然停留在普通桌面，原窗口有可读 AX 焦点，物理输入静止。以本分支重新运行 `scripts/acceptance/window-engine/host/build-overview-witness.sh`，为一次观察分配新的 0700 目录，运行 `overview-witness`。若原窗、HID、两个四按钮实测布局和正式 Host 的 0→1→0→0 均通过，立即将该私有原件传给 `run-installed-stage.py <已验证的安装记录目录> spaces --p0-receipt <本次原件> --result-dir <新私有目录>`。监督器会在退出前复核实时权限和 14 类输入计数，在诊断 Host 启动前再次核对物理输入。若前台再度漂移，同一次记录可交给 `overview_system_events.py` 关联系统事件和目标窗口元数据。[正式监督器](../../../../scripts/acceptance/window-engine/host/run-installed-stage.py) · [系统事件采集](../../../../scripts/acceptance/window-engine/host/overview_system_events.py)
