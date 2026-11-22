# Nearpane 5.22（90）交接状态

起始提交 `609469a667fd265482b774c07198f6338051877d`。Swift Host 负责事务和分组，Rust 静态库负责执行，两个后端分别验收。当前生产合格后端为 **0/2**。

| 能力 | 状态 | 当前证据 |
| --- | --- | --- |
| 唯一安装 Host、四项权限、恢复责任 | PASS | 26A428、SIP 开启。Host `bec6cb2`、PID 32364 自读四项权限均通过，活动租约为零。[安装身份与读回](physical-admission.json) |
| 静止按键与安全输入 | 源码 PASS | 实机写入入口在开始和投递前核对安全输入、硬件与会话鼠标按钮。64 组静止按压判定覆盖两个来源的 32 个按钮。[定向测试](input-admission.json) |
| 普通桌面与原焦点 | BLOCKED | 两端均读到原生全屏类型 4，缺少可保留的普通前台窗口。Host 旧遥测只具有缓存读数。本轮零展示、零窗口或 Space 写入。[实机读回](physical-readback.json) |
| 上次 Edge → GitHub Desktop 的发起者 | UNKNOWN | 复核 742 条限定时间内的系统记录，确认一次前台变更。该事件的 activity 与 parent 均为零，没有跨进程因果链接。[系统事件](focus-activity.json) · [上次同一展示的截图与录屏](../p0-p1-admission-26A428/RESULTS.md) |
| Spaces 真实可交互窗口 | BLOCKED | 正式监督器在发出退出请求前停止。透明普通应用窗口只可验证归属和恢复；键鼠与兄弟窗口需要独立证据。[Spaces 准入](spaces-admission.json) |
| Corner 只读签名夹具 | BLOCKED | 第一次提供的是较早升级包的收据，签名身份核对拒绝；用当前安装包匹配收据后，在普通桌面及焦点门槛停止。未投递停放或输入。[首次拒绝](corner-old-image-mismatch.json) · [匹配安装包后的结果](corner-readonly-admission.json) |
| 引擎撤权与所有权 | 源码 / ABI PASS | 基线复现被撤销的请求重新绑定下一代以及两个归属反例。修复后 103 项 Rust、104 项隔离构建测试和 35 项 Swift 测试通过。[撤权反例](engine-original-race.json) · [原始归属失败](engine-original-owner-failures.log) · [Rust](engine-revocation.json) · [Swift](engine-swift.xml) |
| Guardian 接管后、隐藏派发前发生中断 | 源码 / 签名辅助程序 PASS，实机 NOT_RUN | Rust 锁住从未入队的该次意图。原 Guardian 复核窗口并持久确认后，协调器才结束该次责任。106 项 Rust、50 项引擎 Swift、76 项协调器回归通过。真实签名 Guardian 拒绝非 Host 调用。[引擎](guardian-withdrawal.json) · [签名协议](guardian-signed-protocol.json) · [协调器](coordinator-withdrawal.json) |
| 分组命名与布局往返 | 源码 PASS | 实际离场几何只有在整组事务确认后才持久化，重复选择当前单窗保留用户的新位置。70 项离屏用例通过。[源码与测试](stage-groups.json) |
| 非活动组组合预览 | 源码与离屏绘制 PASS，新候选实机 NOT_RUN | 当前显示器已经显示的成员可用其最后有效帧组成一个组。窗口号重用、权限撤回、跨屏和全屏会使相应历史失效，缺帧的覆盖区保持不透明。63 项回归通过。[验收范围与旧版延迟](history-preview/receipt.json) · [离屏组合图](history-preview/offscreen/historical-group-complete.png) |
| Riftlet 与 Saytile | 部分 PASS | 两款浏览器 18 个隔离草稿场景均为零发送。六个冷启动音频文件逐字节恢复。真实麦克风、已登录草稿未跑，中文识别受本地模型阻塞。[版本、测试与边界](../../embedded-tools/5.22-90/2026-11-23/results.json) |
| 生产侧栏 A→B→C→A、10/50 次、与 Apple 的速度对照 | NOT_RUN | 先取得至少一个后端的真实单窗口隔离、输入和恢复证据。 |

下一个实机动作是在普通桌面和稳定前台窗口自然可用时采集一次新收据。`overview-witness --observe-only` 的独立普通桌面读回可供 `corner-readback` 使用，不需要先迁窗。写入路径由同一安装 Host 的完整 P0 读回和恢复责任约束。安全回退基准为标准路径中仍在运行的签名 `bec6cb2`，其签名与配置有历史实机回执。[单版本恢复基准](../single-version-26A428/15-final-regular-host.json)

旧的 `ordinary-stage-fixture.py` 曾在只检查清理时给整次访问标记 PASS，还会为测试创建桌面。原入口现打印 BLOCKED 并退出。原实现逐字节保存，SHA-256 为 `9574e63abce0de7e63c61dd3b3e73988de5a2d6d1d6341e59c4694b7944110c6`。[历史源码](archived-ordinary-stage-fixture.py.txt)
