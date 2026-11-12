# 副屏原生全屏与焦点归还 · 2026-11-13

后续 02:35 已在同一系统构建上完成浮层开合与普通面板恢复。[复验收据](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)

**01:38 实机裁决**　macOS 27.0（26A428）上，副屏自建窗口真实进入原生全屏一次，并回到原普通桌面和原始窗口几何。主屏原焦点通过前台进程代际、同一 AX 对象及原窗口 frame 核对。工具浮层开合仍为 INCONCLUSIVE。空间行点击和跨空间拖放继续关闭。

本轮从 `fb0badc4597d2eff1ea81186c53403604103244d` 开始。用户授权从当时起 15 分钟暂借副屏焦点。见证使用的许可区间为北京时间 01:31 至 01:45，实际全屏动作发生在 01:38 至 01:39。测试期间只在副屏创建自己的窗，原前台窗口仅作只读比对。

## 实际动作与独立读回

| 项目 | 真机结果 |
|---|---|
| 普通桌面 | 副屏 `C92BDE5E-0D5D-4811-8EF2-04EE7B99A3A9`（旋转 90°，800 × 1280）只有普通桌面 4297。主屏普通记录为 1130、1309，当前为 1309。A→B→A 执行 0/3，没有跨空间移窗。 |
| 焦点演练 | 在副屏登记窗口 187995，取得前台焦点，关闭后在 CG 与 AX 均验证其消失。系统被动归还原焦点后，从头绑定实际全屏窗 187997。同一时刻只持有一扇活动测试窗。 |
| 原生全屏 | 01:38:24 对 187997 发起一次 AppKit 全屏操作。进入通知、窗口 style、AX 全屏状态及连续读回均确认进入。副屏 current 由 4297 变为 4446。保存的 55 份全屏样本均为同一窗口、唯一 membership 4446，AX 与 CG 的全局 frame 均为 `(-800, 0, 800, 1280)`，主屏 current 均为 1309。 |
| 工具浮层 | 隔离 Host 在同一真实全屏区间中启动。未发布首个状态条或 `opened` 事件，控制器 AX 开、合操作均为 0，普通产品面板恢复也未获验证。隔离领域资料前后指纹相同，录音、附件尝试及 START 均为 0。 |
| 退出与清理 | 01:39:33 对同一测试窗发起一次退出，01:39:34 确认回到 4297，frame 恢复为 `(-540, 550, 280, 180)`。两屏原始 current 及顺序一致。两扇登记窗残留 0，系统前台 PID、启动代际、原 AX 焦点对象和主屏原窗 frame 均一致。 |

本轮最终见证 UUID 为 `45F26B9D-EA56-4B35-9090-7CCA522F6422`。完整样本及其 SHA-256 留在本地忽略目录。[系统动作与归还](../../build/verification/native-timed-1113/45F26B9D-EA56-4B35-9090-7CCA522F6422/result.json) · [原始样本指纹](../../build/verification/native-timed-1113/45F26B9D-EA56-4B35-9090-7CCA522F6422/fingerprints.json) · [工具控制器及领域指纹](../../build/verification/native-timed-1113/45F26B9D-EA56-4B35-9090-7CCA522F6422/host-result.json)

## 现场遇到的问题

1. 旧见证在建窗前把重复设置 accessory 策略和 AX 授权合并判定，报告“test GUI Accessibility unavailable”。修正后，同一设备实际读到初始及有效策略均为 accessory、AX 已授权。只在需要时设置策略，两个门槛分别取证。[首次拒绝](../../build/verification/native-timed-1113/582AD5BF-1C62-41C8-B844-4A207F992378/result.json)
2. 首个真实演练窗在隐藏前已成功取得前台，并完成被动归还。重显后 AX 对象改变，见证正确在全屏前停止，清理与焦点归还均通过。校准改用一次性副屏窗口，先确认其 AX 和 CG 均已消失，再独立登记实际目标窗。新的 AX 对象及窗口号均不得复用。该修复已用于上表的实机往返。[原拒绝](../../build/verification/native-timed-1113/7F003C65-C054-4916-84E1-E4FB1F3531CD/result.json) · [校准与归还](../../engineering/window-lab/Sources/NearpaneSpaceWitness/ConsoleFocusLoan.swift)
3. 隔离控制器按 POSIX 实体路径 `/private/tmp/…` 登记见证程序。使用本轮实际签名包的离线复核显示，Foundation 和 Bundle 会返回同一可执行文件的 `/tmp/…` 表示，旧字符串比较在启动绑定时必然失败。现在仍要求登记路径本身为 POSIX 实体路径。系统报告路径须完全相同，或经 `realpath` 核对为同一实体的系统别名。保留签名、程序哈希、进程代际、窗口及焦点检查。任意符号链接替换仍会拒绝。[Host 绑定](../../Sources/NearpaneHost/EnrolledFullscreenFixture.swift) · [路径约束](../../Sources/NearpaneUI/EnrolledFullscreenObservation.swift) · [正反例](../../Tests/NearpaneUITests/EnrolledFullscreenObservationTests.swift)
4. AppKit 记录 Host 启动后约 0.2 秒请求退出，委托返回待排空。65 秒计时器再次调用退出，系统强制结束，虽返回码 0，仍无 `drained` 收据。已在开始退出时撤销这一定时器，增加只在隔离全屏联验输出的阶段、拒绝码及单调时间诊断。代码修复发生在现场往返之后。工具开合、普通面板恢复及修复后正常排空都待真机复验。个人 P5.7 安装和工作资料保持原状。[隔离 Host 退出日志](../../build/verification/native-timed-1113/host-appkit-termination.log) · [启动及退出处理](../../Sources/NearpaneHost/NearpaneApp.swift)

## 离线验证及版本

源码提交为 `9ca6a119b34ac1c7ed6e2cc3cdfee86656650228`。WindowLab 19/19、检查点协议 13/13、工具控制器 6/6、Host 全屏绑定 3/3，共 41 项定向测试通过。已用现场同一签名见证独立复现路径比较，三个旧比较均拒绝，修复后三个比较均通过，严格签名与代码目录身份均有效。验收工具和修复后的 Host 分别构建，Debug、Release 及包内 171 个锁定依赖文件通过校验。[WindowLab](../../build/verification/native-timed-1113/windowlab-tests.log) · [检查点](../../build/verification/native-timed-1113/checkpoint-tests.log) · [控制器](../../build/verification/native-timed-1113/overlay-controller-tests.log) · [路径回归](../../build/verification/native-timed-1113/enrolled-path-tests.log) · [原签包复核](../../build/verification/native-timed-1113/host-path-probe.log) · [Debug](../../build/verification/native-timed-1113/host-debug.log) · [Release](../../build/verification/native-timed-1113/host-release.log)

隔离复测包已独立签封，Host SHA-256 为 `7cc841ecdd18f189368ac340506854c2001df75a93d3c3b787f4027185edb407`。新空资料会话 `68bdac01-cbf9-476b-9901-17c4224b7e14` 尚未启动 GUI。个人 P5.7 可执行文件指纹与基线相同。[签名包、见证包和会话清单](../../build/verification/native-timed-1113/ready.json)

## 接续

本次仅证实本机、自建窗口的全屏、退出及焦点归还。普通 Alpha 的浮层、常规面板恢复和第三方应用覆盖仍待验证。下一次仅需在一个副屏普通桌面上复验隔离 Host 和真实开合。只有副屏实际出现相邻的普通 A/B 时，才能另行验三轮系统桌面往返。
