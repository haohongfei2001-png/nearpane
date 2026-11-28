# 5.22（90）交互窗口单次往返验收

2026-11-23，产品源码 `b77111458e18d354d456304efd5c8317e1277104`。**两款应用的真实三窗收件通过。26A428 正式 Host 单窗隐藏与恢复尚未执行，生产资格为 0/2。** [机器总表](qualification.json) · [正式验收合同](../../../native-spaces/ACCEPTANCE.md)

| 项目 | 状态 | 实测结论 |
| --- | --- | --- |
| 三窗输入与文档归属 | PASS，托管 25G332 | 目标窗 133 收到按下、拖动、释放、键盘按下和释放五个系统事件，并写入本次唯一的 UUID。同应用窗口 134、另一应用窗口 132 都是零事件、零文档。独立读回确认焦点、几何、进程代际相符。两款应用均已退出，临时资料已清理。[逐窗收件](hosted-interactive/stage-group-windowserver.json) · [截图](hosted-interactive/three-windows.png) · [3.05 秒录屏](hosted-interactive/real-input.mov) |
| 标准路径 Host 的三窗登记 | BLOCKED，26A428 | 第一轮能两次核实原 AX 焦点及窗口 33546。末轮仍为原生全屏类型 4，且前台缺少可交还的普通 AX 窗口。正式登记入口在请求退出前停止，实体机未创建三窗。[开始读回](01-passive-scope.json) · [末轮读回](07-final-physical-readback.json) · [登记入口](08-roster-admission.json) |
| Spaces 真实交互窗迁入、迁回 | 准入 BLOCKED，动作 NOT_RUN | 正式一次性入口现可登记两款固定签名应用，保留一次性 nonce、写前日志和恢复责任。实体机本轮只读收据未包含完整的 Mission Control 展示和焦点交还，监督器发出零次退出请求、零次迁窗。此前正式 Host 的自有面板往返另有记录。[本轮迁移入口](09-spaces-admission.json) · [此前面板实测](../single-version-26A428/RESULTS.md) |
| Corner 停放、输入隔离与恢复 | 准入 BLOCKED，动作 NOT_RUN | 26A428 的 Corner 入口在退出前停止。托管 26A434 两次读到普通桌面 ID 1，两次均缺 Space UUID，停放次数为零。新包 Guardian 实际拒绝了非 Host 请求，返回码 3，未确认租约。正式 Host 的正向租约、停放时完整手势、Dock、菜单及崩溃接管仍待实测。[实体入口](10-corner-admission.json) · [托管逐次读回](corner-hosted-26A434/result.json) · [Guardian 拒绝回执](guardian-unowned-request.json) |
| 旧角落遮罩 | FAIL | 旧原型收到了真实鼠标按下。此结果独立保留。[失败原件](../../stage-groups/5.22-90/isolation/qualification/corner.json) · [失败录像](../../stage-groups/5.22-90/isolation/qualification/corner.mp4) |
| StageGroup 生命周期 | PASS，限托管窗口目录 | 一个夹具进程退出后两次读回窗口消失，重开得到新一代窗口与独立单窗组。另一应用的原两窗及其组保留。[真实重开收据](hosted-interactive/stage-group-lifecycle.json) |
| 安装版侧栏 A→B→C→A、10/50 次、Apple 同机性能 | NOT_RUN | 等待至少一个后端在目标实体机通过完整资格。生产可选后端数为零。 |

### 正式入口和恢复责任

`interactive-roster` 与 `interactive-spaces` 复用标准安装路径、正式 Host 和嵌入式 Rust 静态库。目标和兄弟窗来自一款 Developer ID 签名应用，旁观窗来自另一款。Host 核验两款签名、进程出生代、CGWindowID、原 AX 对象、AX 与 WindowServer 几何及逐窗双向归属。原位按 PID 投递和系统实际命中分别记录。[三窗登记与事务](../../../../Sources/NearpaneHost/StageInteractivePair.swift) · [签名及各 25 项协议自测](05-signed-fixtures.json)

一次 Spaces 试验先完成自有面板往返，再仅迁移登记的目标。停放时旁观窗应收到系统手势和唯一文档标记，归还后改由目标窗接收。每次独立归属读回同时核对另外两窗。收据缺失仍进入有归属凭据的归还路径，异常或未知结果保留原始日志与恢复责任。Rust 故障注入已覆盖停放后输入观测缺失时的归还尝试。[正式验收合同](../../../native-spaces/ACCEPTANCE.md) · [Rust/Swift/C ABI 收据](15-engine-ci.json)

### 构建、配置与后续实机入口

- 最终源码在 26A428 的 786 项原生测试中通过 783 项、跳过 3 项、失败 0 项。两项 GitHub 工作流通过。引擎工作流的 18 个检查包括 108 项 Rust、118 项 Swift 和生产 C ABI。编译过程中的 Swift 并发类型和 MainActor 错误原件已保留。[本机 xUnit](13-full-native.xml) · [跳过明细](13-full-native-summary.json) · [引擎原始日志](engine-ci-logs.zip) · [中间失败](intermediate-builds/) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45077259040) · [原生 GUI CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45077259015)
- 私有 arm64 候选来自上述干净源码。解包复验通过，14 个可执行文件具有加固运行时和安全时间戳，检查了 46 项资源。Host CDHash 为 `b370a4d032689fd555e079d88518c575e76487db`。Gatekeeper 返回 `Unnotarized Developer ID`，候选未安装。两款固定签名夹具也单独归档并解压复验，二进制归档均保存在本机的 `build/candidates/5.22-90-b7711145/`。[签名与归档 SHA-256](signed-candidate.json) · [夹具归档校验](fixture-kit-archive.json)
- 日常 Host 仍为 `bec6cb2`，PID 32364、进程出生代、CDHash 和配置摘要前后一致。该进程自读的四项权限均有效，活动恢复租约为零。三项正式入口均在申请退出前停止。[开始](02-canonical-host.json) · [收尾](11-host-and-config-after.json)
- 下一次实机执行需要 26A428 的普通桌面及可交还的前台 AX 窗口自然可用。届时先核验唯一标准安装 Host 的新版本、签名、自身权限和恢复责任，用新鲜的双读凭据运行 `interactive-roster`。取得与该 Host 进程代绑定的完整 P0 后，运行一次 `interactive-spaces`。Corner 的正向 Guardian 租约、手势及中断恢复独立验收。[正式监督器](../../../../scripts/acceptance/window-engine/host/run-installed-stage.py)

### 开始时的现场记录

基线为 Draft PR #15 的 `1c789f6`，与上一签名候选 `4701693` 的产品源码一致。目标为 macOS 27.0（26A428）、SIP 开启。普通桌面是本次可见窗口和真实屏幕输入试验的条件。

| 阶段 | 结果 | 依据 |
| --- | --- | --- |
| 实体机只读准入 | BLOCKED | 开始和终态都是全屏 Space 类型 4。与上一轮相比，已重新取得原 AX 对象、同一进程代和 CGWindowID，两次读回相符。HID 计数相同，无新操作。[原始采样](01-passive-scope.json) |
| 唯一安装 Host | PASS，限当前安装 | 标准路径中 `bec6cb2` 自读四项权限；无共享租约或阻塞记录。[进程、权限与配置摘要](02-canonical-host.json) |
| 隔离环境 | 目标构建的独立会话未取得 | 仓库登记的自托管 runner 为零，此机常见虚拟机管理工具清单为空。创建账号、切换登录及修改安全设置的次数均为零。[环境观测](03-isolation-environment.json) |
| 生产资格 | 0/2 | Spaces 与 Corner 各需在目标构建上独立验证真实交互窗口、输入落点及恢复。组切换、10/50 次和同机性能对照待资格通过后启动。 |

### 两款应用的真实输入对照

在托管 macOS 26.7.2（25G332）中，Launch Services 启动两款已签名的隔离应用。系统将五个事件依次送达目标窗 132，其内容视图写入的 UUID 与独立文件读回一致。同应用旁窗 133 及另一应用的窗口 131 均收到零个事件，未写入文档。三个原窗口的 AX 与 WindowServer 几何相符，终态焦点与进程代际符合预期，夹具全部退出。测试源码为 `919d271`。26A428 的正式 Host、Spaces 迁移和 Corner 停放仍各自待验。[原始收据](04-hosted-windowserver.json) · [CI 运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45074297309)
