# 5.22（90）P0 / P1 实机准入

2026-11-22，macOS 27.0（26A428），arm64，SIP 开启。正式安装路径为 `/Applications/Nearpane.app`。常规 Host 的源码为 `bec6cb21ea77e7d024ee188d22d7f1d6699497c4`，CDHash 为 `cefff1e30ec9c0e51c52c91197b92d22e39737bf`，PID 32364，出生代 1795343882268848。观察器在同一登录会话独立读取 AX 和 WindowServer。Host 通过已有诊断通道报告它看到的 Mission Control 状态。[安装、进程及最终清理](11-cleanup.json)

| 合同 | 实机结论 | 依据 |
| --- | --- | --- |
| P0 可见桌面条 | **PASS** | 普通桌面 4，同次展示中每轮 170 个坐标，Dock 与 SystemWide 各读两轮。两轮均得到四个可分别命中的真实按钮，布局相同。[原始 AX](07-ordinary-position-and-focus.json) · [独立复算](08-physical-strip-replay.json) |
| P0 原焦点 | **前台连续性 FAIL，原 AX 焦点 UNKNOWN** | 展示前两读均为 Microsoft Edge，PID 48228，出生代 1795271950317697，CGWindowID 68518。收起后 49 次读到 GitHub Desktop（PID 56354）处于前台，49 次 AXFocusedWindow 均返回 -25212。原窗口连续确认 0/2。十四类 HID 计数相同。[分项判定](09-p0-decision.json) |
| P0 整体 | **UNKNOWN，未准入** | 普通桌面原生清单完整恢复，独立观察器确认收起。Host 的四次原始标志依次为 0、0、1、0，展示和收起的单次遥测均有滞后。[同次会话](07-ordinary-position-and-focus.json) |
| P1 第三方窗口往返 | **BLOCKED，迁移 NOT_RUN** | 正式 `run-installed-stage.py spaces` 读取原始 P0 收据后于退出前返回，退出请求为零。[实际监督器回执](10-p1-supervisor.json) |
| P2 整组、10/50、Corner、性能对照 | **NOT_RUN** | P1 尚未取得单窗口往返、外部读回、持久化日志和恢复证明。 |

## 桌面条为何现在可以核实

Apple 的坐标查询使用显示器全局左上原点。应用级根只在本应用中查找，SystemWide 根可返回其他进程实际位于该点的对象。普通桌面两轮的 Dock 根都只有 3 个成功命中和 167 个无值，一共 340 次 SystemWide 调用则全部返回对象。已验签的 Apple WindowManager（PID 647）在 SystemWide 读数中暴露了 `mc.spaces.list`。它的 AXChildren、AXVisibleChildren 和 AXChildrenInNavigationOrder 返回相同的四个 AXButton，四个按钮的 AXParent 均指回该列表。[Apple AX 坐标接口](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition) · [逐点、父节点与原始错误码](07-ordinary-position-and-focus.json)

收起式桌面条高 72 点。按钮的 AX 框从 y=-0.5 开始，高 129 点，其中有的横向相交。这次采集中的早期分类器要求完整矩形处于桌面条内部，因此原件中 `observedTileHits` 为零。独立复算保留原件，要求同一条物理扫描线分别命中四个按钮，且位置顺序、框和两轮的可见子节点均一致。在 y=16，两轮实测的横向命中范围分别约为 454–584、627–670、713–757、886–1016 点。这些数值是实际探测点，并非对缩略图像素边缘的估计。源码已改为核对同一扫描线的实际命中，记录原始 AX 框。[复算程序](../../../../scripts/acceptance/window-engine/host/visible_strip.py) · [两轮数值](08-physical-strip-replay.json)

普通桌面试验展示一次、收起一次，未发出窗口、Space 或合成输入操作。收起后的前台进程与原进程不同，原始证据没有给出切换触发方。后续观察器可在保留原 AX 对象的同时记录 NSWorkspace 的应用激活通知，并为 Host 状态遥测保留有界轮询的每次响应。这两项后续改动已进入源码，独立实机复验仍待进行。[焦点与时间戳](07-ordinary-position-and-focus.json)

## 全屏补充观察与清理

普通桌面曾能读到前台应用但拿不到 AXFocusedWindow，之后出现了真实焦点但桌面条件已变化。六分钟的被动观察也记录了真实全屏。所有未展示的尝试均有独立记录。[首次焦点预检](01-ordinary-no-focus.json) · [桌面条件变更](02-scope-changed-before-show.json) · [普通桌面等候](03-ordinary-admission-watch.json) · [补充预检](04-fullscreen-typing-preflight.json)

原生全屏的补充试验只展示一次。Host 观察到开启，首轮 SystemWide 命中四个按钮。第一轮后，完整的 managed 字典出现差异，当时前后读取的有序 ID 相同。该版本没有保存变化的具体字段，因此原因仍为 UNKNOWN。准备收起时检测到新 HID 输入，清理器没有发出收起操作。后续两个独立样本均确认系统总览已关闭。这组观察与普通桌面收据分别保存。[全屏原始观察](05-fullscreen-component.json) · [输入中断](06-hid-interruption.json) · [终态](11-cleanup.json)

普通桌面与全屏各保留一张截图和一段无声实录，ScreenCaptureKit 的采集范围限于 Dock 与 WindowManager 的顶部系统桌面条，输出为 144×16。普通桌面有 78 个真实帧、6.815 秒，全屏有 19 个真实帧、1.615 秒。影像仅供定位界面时序。公开 JSON 用一致的别名替代硬件和 Space UUID，保留对象索引、PID、几何、时间戳和 AX 错误码。私有原件及公开副本的 SHA-256 已登记。[普通桌面截图](ordinary-strip.png) · [普通桌面录屏](ordinary-strip.mp4) · [全屏截图](fullscreen-strip.png) · [全屏录屏](fullscreen-strip.mp4) · [媒体校验](media.json) · [原件摘要](provenance.json)

## P1 入口与晋级

`run-installed-stage.py spaces` 在读取通过的 P0 原件后逐项核对两轮原始坐标、原焦点、HID、原生清单、Host 遥测、运行 PID/出生代、安装源码 SHA 和 CDHash。相同回执的摘要带入原有安装包诊断。Launch Services 的 `sameProductInstanceRunning` 检查继续由正式启动器执行。当前实机收据在退出前终止，因而本轮没有第三方窗口往返结论。[监督器](../../../../scripts/acceptance/window-engine/host/run-installed-stage.py) · [P1 实际阻塞事件](10-p1-supervisor.json)

获准后沿用已有的签名普通窗口、nonce 和 Swift Host/Rust 路径。独立进程在登记前及迁回后比对同一窗口的 AX/CG 几何、同一前台窗口、Dock 项目子角色顺序、双向归属和原生清单。监督器重新读取绑定本次启动代、挑战号、Host 及夹具身份的完成日志，区分归还、销毁、Host 回归与业务结果。这些新增检查已有编译和离线拒绝测试，其实机派发仍为 NOT_RUN。[登记与日志核对](../../../../scripts/acceptance/window-engine/host/sample-membership.py) · [独立窗口读回](../../../../scripts/acceptance/window-engine/host/fixture-readback.swift)

普通桌面与全屏的观察器均按原输入重新编译，所得二进制 SHA-256 分别与采样收据完全一致。普通桌面的中间版源文件可由记录的 Git 基线和补丁还原。构建验证与实机分项分别记录。[来源、补丁用法与二进制摘要](provenance.json) · [源码补丁](ordinary-observer.patch) · [自动化收据](12-automated-checks.json)

复核同一次普通桌面试验上下 11 秒的系统日志，191 条匹配记录中，Launch Services 在 22:35:23.960 与 22:35:24.753 两次提到系统总览启动器。留存信息能定位展示和收起，不能判定谁请求了 GitHub Desktop 获得前台。收据只保存时间、系统发出方、预先限定的进程标识及事件类别。[焦点事件元数据](13-focus-event-metadata.json)

最后一次源码修改 `0ace430` 的 GitHub 原生引擎 CI 已通过。托管 runner 的系统 build 为 26A434，结果包含 102 项 Rust、91 项 Swift 测试及生产 C ABI 链接与读回。收据将该 runner 的实机资格标为 `NOT_RUN`。[CI 运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45035696496) · [原始 CI 收据](14-hosted-source-result.json)
