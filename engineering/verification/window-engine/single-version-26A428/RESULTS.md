# 单版本原位升级及正式 Host 实测

2026-11-22，macOS 27.0（26A428），arm64，SIP 开启。Nearpane 5.22（90）使用原 Bundle ID `com.holdsnow.nearpane.alpha`、Team ID `ZB9D4T66QB` 和产品单实例限制。

## 安装与权限

| 标准路径中的版本 | 常规 Host 首次 PID | Host CDHash |
| --- | ---: | --- |
| 升级前 `d2d0bb6` | 59938 | `27a6616d7c6d916e94633986a81ba488dba21e2d` |
| 刷新的 PR 基线 `217a70d` | 2302 | `eb47c7a75df6d3ae1c641d737707b41dc660248b` |
| 面板修复 `9509bd0` | 16060 | `6315b36637d63050d954c1d484a0399726f22395` |

每次原位替换均先核对回滚副本、严格验签和配置摘要。旧 Host 正常退出后，Launch Services 与内核普查确认进程槽为空，随后在同一 APFS 卷交换应用包。已安装可执行文件通过资源及 ABI 自检，再由 Launch Services 从 `/Applications/Nearpane.app` 启动。两份旧包的历史登记已注销，文件指纹保留。已注册路径、系统首选路径和实际运行路径均指向标准安装。 [第一次升级和登记清理](01-single-version-install.json) · [修复版升级和包指纹](08-corrected-install.json) · [独立进程核对](10-registered-candidate.json)

两版候选分别从各自运行进程回答随机挑战。Accessibility、Input Monitoring、Event Posting、Screen Recording 四项均为允许。旧版未返回 Input Monitoring 字段。升级前后的配置及活动 profile 摘要一致。历史普通窗口由同一 PID、出生代和 CGWindowID 标识，在逐窗锁和会话锁内连续两次读得 `(0,33,1470,923)`。上次写入已完成，无新写入意图。保留当前位置后，备份、原记录与归档的 SHA-256 完全相同。 [窗口与归档收据](02-preserved-geometry.json)

## 第一次正式面板实测

全屏桌面 5184（type 4）上，正式 Host 的两次系统读数一致，空间写入在预检处停止。随后 Apple 的测试准备工具创建了临时普通桌面 5614，未能确认其 Mission Control 缩略图命中点，选择点击为零。工具回收 5614，原四个桌面的身份及顺序恢复。准备前的系统通知窗口并未恢复为前台。之后检测到新物理输入，交还工具发出零次激活，保留用户新选的前台。验收工具已增加双读回的前置条件，只有普通应用的可见零层窗口可以作为准备工作的原焦点。 [正式 Host 全屏读回](03-fullscreen-host.json) · [临时桌面及焦点失败证据](04-ordinary-desktop-fixture.json)

系统自然进入普通桌面 4 后，正式 Host PID 6474 打开自己的透明面板 65972。第一次归属检查返回 `exclusiveBidirectionalMembershipUnavailable`。签名程序对该面板的专属持久日志完整记录打开、关闭及终止清理，创建 Space、迁入、迁回、销毁的派发次数均为零。系统桌面清单前后相同，独立 WindowServer 查询两次确认该面板消失，常规 Host 正常返回。面板归属资格为 **UNKNOWN**，已回收资源的证据单独记账。 [正式 Host 读回](05-first-ordinary-host.json) · [完整清理记录](06-first-panel-cleanup.json)

单独签名的非激活夹具复现了面板登记时序。面板 66055 刚打开时，两个反查掩码均返回空数组，桌面正查命中 0 次。约 18 毫秒后，两种反查均为 `[4]`，正查命中 1 次。整个样本只使用自己的窗口，未投递输入或进行 Space 写入。正式引擎现在保留已打开面板的身份，在既有 120 毫秒期限内复核同一窗口、焦点、拓扑及双向归属。连续两次成立后才能申请迁移租约。多重归属、持续为空或身份变化时停止写入。 [实机采样](07-membership-timing.json)

## 构建与回归

修复版通过 102 项 Rust 测试、86 项 Swift 引擎专项、生产 C ABI 和安装验收工具测试。前一轮沙箱内有四项离线日志测试返回 19，独立复测 11/11 通过，原始失败已保留。修复版本的完整源码检查通过。GitHub 引擎与内嵌工具两项 CI 均通过。 [机器收据](09-source-verification.json) · [回归日志](regression-logs.zip) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44991294162) · [内嵌工具 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44991294189)

## 修复后的正式面板往返

在两段只读观察期间，系统先停留在全屏桌面 5184，随后自然回到普通桌面 4。修复版正式 Host（源码 `9509bd0`，PID 22249）在桌面 4 打开自有面板 66213，创建临时 Space 5643。迁入 5643 和归还桌面 4 后均取得两次双向归属读回。面板关闭，5643 销毁。十六条持久日志与独立核对完全吻合，四次桌面清单一致，终态焦点经两次核对，持有窗口和 Space 均为零。此轮自有面板往返为 **PASS**。当时的 Host 仍要求屏上普通窗口全部属于验收夹具，Mission Control 的可见桌面条检查在展示前返回 **BLOCKED**，外部窗口动作次数为零。 [自有面板与十六条日志](11-formal-panel-cycle.json) · [正式 Host 原始读回](11-formal-panel-host.json) · [同版本常规进程恢复](11-session.json) · [第三方试验入口](11-external-admission.json)
