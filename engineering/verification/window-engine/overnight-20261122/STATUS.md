# PR #15 单机夜间验收

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
