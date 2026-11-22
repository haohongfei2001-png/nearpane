# 单版本原位升级及正式 Host 实测

2026-11-22，macOS 27.0（26A428），arm64，SIP 开启。Nearpane 5.22（90）使用原 Bundle ID `com.holdsnow.nearpane.alpha`、Team ID `ZB9D4T66QB` 和产品单实例限制。

## 保持当前 Host 运行的复核

正式 Host PID 32364 以原启动代际回答了一次新的随机挑战，四项系统权限均为允许。正常运行时的只读接口也返回了 Dock 的总览状态。首段 245 秒的系统通知观察没有出现普通桌面，独立读数仍为原生全屏 Space 5568。此时 Host 读到总览已关闭，可见缩略图数量和普通桌面的焦点还原均待测。

两次读取均识别出同一物理显示器及四个受管理 Space 的原生 UUID。当前顺序为 4、5568、5184、6。全量 API 返回 22 条、20 个不同 ID，两个全屏 Space 各出现两次。保留重复次数后，完整清单与先前已清理的基线一致。历史试验使用的 5614、5643 均已消失。原始 UUID 留在私有机器收据中，公开记录使用同一套别名。[正式 Host、完整清单与现场边界](17-live-host-ordinary-admission.json)

已安装版本的第三方迁窗试验通过 `--enrolled-spaces-cycle` 在进程启动时进入。当前 PID 的启动参数没有这个选项。正式侧栏从随包的资格清单载入可用后端，当前源码的清单为空。原运行进程能回答总览状态，未提供接受这次外部窗口登记的运行时入口。第三方窗口、整组切换和稳定性测试仍为 **NOT_RUN**，Spaces 的引擎能力仍待实测。[启动入口](../../../../Sources/NearpaneHost/NearpaneApp.swift) · [常规 Host 的资格清单](../../../../Sources/NearpaneUI/StageWindowEngineHost.swift)

## 安装与权限

| 标准路径中的版本 | 常规 Host 首次 PID | Host CDHash |
| --- | ---: | --- |
| 升级前 `d2d0bb6` | 59938 | `27a6616d7c6d916e94633986a81ba488dba21e2d` |
| 刷新的 PR 基线 `217a70d` | 2302 | `eb47c7a75df6d3ae1c641d737707b41dc660248b` |
| 面板修复 `9509bd0` | 16060 | `6315b36637d63050d954c1d484a0399726f22395` |
| 当前登录会话修复 `bec6cb2` | 32364 | `cefff1e30ec9c0e51c52c91197b92d22e39737bf` |

每次原位替换均先核对回滚副本、严格验签和配置摘要。旧 Host 正常退出后，Launch Services 与内核普查确认进程槽为空，随后在同一 APFS 卷交换应用包。已安装可执行文件通过资源及 ABI 自检，再由 Launch Services 从 `/Applications/Nearpane.app` 启动。两份旧包的历史登记已注销，文件指纹保留。已注册路径、系统首选路径和实际运行路径均指向标准安装。 [第一次升级和登记清理](01-single-version-install.json) · [修复版升级和包指纹](08-corrected-install.json) · [独立进程核对](10-registered-candidate.json)

各次原位安装的候选均由其实际运行进程回答随机挑战。Accessibility、Input Monitoring、Event Posting、Screen Recording 四项均为允许。旧版未返回 Input Monitoring 字段。升级前后的配置及活动 profile 摘要一致。历史普通窗口由同一 PID、出生代和 CGWindowID 标识，在逐窗锁和会话锁内连续两次读得 `(0,33,1470,923)`。上次写入已完成，无新写入意图。保留当前位置后，备份、原记录与归档的 SHA-256 完全相同。 [窗口与归档收据](02-preserved-geometry.json)

## 第一次正式面板实测

全屏桌面 5184（type 4）上，正式 Host 的两次系统读数一致，空间写入在预检处停止。随后 Apple 的测试准备工具创建了临时普通桌面 5614，未能确认其 Mission Control 缩略图命中点，选择点击为零。工具回收 5614，原四个桌面的身份及顺序恢复。准备前的系统通知窗口并未恢复为前台。之后检测到新物理输入，交还工具发出零次激活，保留用户新选的前台。验收工具已增加双读回的前置条件，只有普通应用的可见零层窗口可以作为准备工作的原焦点。 [正式 Host 全屏读回](03-fullscreen-host.json) · [临时桌面及焦点失败证据](04-ordinary-desktop-fixture.json)

系统自然进入普通桌面 4 后，正式 Host PID 6474 打开自己的透明面板 65972。第一次归属检查返回 `exclusiveBidirectionalMembershipUnavailable`。签名程序对该面板的专属持久日志完整记录打开、关闭及终止清理，创建 Space、迁入、迁回、销毁的派发次数均为零。系统桌面清单前后相同，独立 WindowServer 查询两次确认该面板消失，常规 Host 正常返回。面板归属资格为 **UNKNOWN**，已回收资源的证据单独记账。 [正式 Host 读回](05-first-ordinary-host.json) · [完整清理记录](06-first-panel-cleanup.json)

单独签名的非激活夹具复现了面板登记时序。面板 66055 刚打开时，两个反查掩码均返回空数组，桌面正查命中 0 次。约 18 毫秒后，两种反查均为 `[4]`，正查命中 1 次。整个样本只使用自己的窗口，未投递输入或进行 Space 写入。正式引擎现在保留已打开面板的身份，在既有 120 毫秒期限内复核同一窗口、焦点、拓扑及双向归属。连续两次成立后才能申请迁移租约。多重归属、持续为空或身份变化时停止写入。 [实机采样](07-membership-timing.json)

## 构建与回归

修复版通过 102 项 Rust 测试、86 项 Swift 引擎专项、生产 C ABI 和安装验收工具测试。前一轮沙箱内有四项离线日志测试返回 19，独立复测 11/11 通过，原始失败已保留。修复版本的完整源码检查通过。GitHub 引擎与内嵌工具两项 CI 均通过。 [机器收据](09-source-verification.json) · [回归日志](regression-logs.zip) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44991294162) · [内嵌工具 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44991294189)

## 修复后的正式面板往返

在两段只读观察期间，系统先停留在全屏桌面 5184，随后自然回到普通桌面 4。修复版正式 Host（源码 `9509bd0`，PID 22249）在桌面 4 打开自有面板 66213，创建临时 Space 5643。迁入 5643 和归还桌面 4 后均取得两次双向归属读回。面板关闭，5643 销毁。十六条持久日志与独立核对完全吻合，四次桌面清单一致，终态焦点经两次核对，持有窗口和 Space 均为零。此轮自有面板往返为 **PASS**。当时的 Host 仍要求屏上普通窗口全部属于验收夹具，Mission Control 的可见桌面条检查在展示前返回 **BLOCKED**，外部窗口动作次数为零。 [自有面板与十六条日志](11-formal-panel-cycle.json) · [正式 Host 原始读回](11-formal-panel-host.json) · [同版本常规进程恢复](11-session.json) · [第三方试验入口](11-external-admission.json)

## 当前登录会话的正式候选

源码 `bec6cb2` 把 Mission Control 检查绑定到当前控制台中的前台普通窗口。展示前用 AX 焦点对象、CGWindowID、可见层级和进程代连续核对，排除通知窗口、隐藏窗口和旁窗。此操作只读取窗口及桌面条，记录输入是否变化。候选从标准路径启动，自读四项已有授权；核对到唯一登记、旧进程退出及配置相同。签名 ZIP 独立解包后的目录指纹与安装相同。 [安装、签名、四项权限和 ZIP 摘要](12-console-install.json)

本机源码回归通过 102 项 Rust、87 项 Swift 引擎专项、20 项 Host 验收工具测试和生产 C ABI。 [机器测试结果](13-current-source-tests.json) · [回归日志](13-current-source-logs.zip) · [核心引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45013218835)

本次换装后的 245 秒观察窗口中，显示器始终处于全屏 Space 5568（type 4），未收到 Space 切换通知。独立读取仍为 5568。自动审批拒绝在该条件下再次停止并重启 Host 运行相同预检。修正后的可见桌面条在此版本为 **BLOCKED**。终态只读核查确认同一 PID 32364、出生代 1795343882268848、唯一标准路径、四项权限、相同配置以及零活动窗口租约。 [目标系统与逐项资格](14-target-qualification.json) · [最终运行进程](15-final-regular-host.json) · [本版三项 GitHub CI](16-source-ci.json)

| 实机合同 | 结论 |
| --- | --- |
| Spaces 正式 Host 自有面板 | **PASS** 于 `9509bd0` 的一次完整面板往返。当前 `bec6cb2` 的可见桌面条复测 **BLOCKED**。 |
| Spaces 第三方普通窗 | **NOT_RUN**。待可见桌面条和原焦点验证通过后，验证签名外部窗口；其键盘、Dock 和同应用旁窗分别记账。 |
| Corner 单窗与 Guardian | 本轮正式单窗停放、逐段鼠标接收者与 Guardian 恢复租约均为 **NOT_RUN**。 |
| 生产调度及性能 | 合格后端 **0/2**。侧栏 A→B→C→A、10 次、50 次及 Apple 同机性能对照均为 **NOT_RUN**。 |

下一步在本机普通桌面用当前标准安装版核对 Mission Control 可见桌面条与原焦点，达标后由同一验收入口登记并试验一扇签名外部普通窗口。原生全屏停留期间，常规产品继续运行。
