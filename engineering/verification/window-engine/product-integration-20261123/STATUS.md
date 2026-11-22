# Nearpane 5.22（90）交接状态

起始提交 `609469a667fd265482b774c07198f6338051877d`。Swift Host 负责事务和分组，Rust 静态库负责执行，两个后端分别验收。当前生产合格后端为 **0/2**。

私有 arm64 候选来自干净源码 `4701693f132759bc16c96b7c4d67d015d3096ef4`，版本 5.22（90）。解压后独立核验 14 个可执行文件的 Developer ID、加固运行时和 Apple 安全时间戳，核对 9 个权限主体与 46 项资源，并执行随包运行时自检。Gatekeeper 返回 `Unnotarized Developer ID`，公开分发及新包标准路径启动待验。归档 SHA-256 为 `710e44482c00be6a18124af90a85ade9448076793e349f4c5bdf3d1b8f00b12b`。[签名清单与 Gatekeeper 回执](signed-candidate.json) · [本轮机器验收汇总](final-qualification.json)

| 能力 | 状态 | 当前证据 |
| --- | --- | --- |
| 唯一安装 Host、四项权限、恢复责任 | PASS | 26A428、SIP 开启。私有包制作后，Host `bec6cb2` 仍为原 PID 32364 和同一出生代，四项权限由 Host 自读，配置摘要一致，活动租约为零。[开始时](physical-admission.json) · [签名结束后](post-build-installed.json) |
| 最终源码回归 | PASS | 目标 Mac 上原生测试 781 项通过、3 项条件跳过。GitHub 引擎 CI 的 18 个步骤通过，含 107 项 Rust、116 项 Swift 以及生产 C ABI。日志测试首次缺少 Carbon 的真实链接失败已存档。真实桌面调度另计。[本机 xUnit](final-native.xml) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45053837173) · [完整 CI 收据与日志](engine-ci.zip) · [首次失败](ci-journal-link.json) |
| 静止按键与安全输入 | 源码 PASS | 实机写入入口在开始和投递前核对安全输入、硬件与会话鼠标按钮。64 组静止按压判定覆盖两个来源的 32 个按钮。[定向测试](input-admission.json) |
| 普通桌面与原焦点 | BLOCKED | 两端均读到原生全屏类型 4，缺少可保留的普通前台窗口。Host 旧遥测只具有缓存读数。前台抽样为系统通知中心，其原始普通 AX 窗口无法取得；历史实测曾无法交还通知界面的焦点。本轮零展示、零窗口或 Space 写入。[实机读回](physical-readback.json) |
| 上次 Edge → GitHub Desktop 的发起者 | UNKNOWN | 复核 742 条限定时间内的系统记录，确认一次前台变更。该事件的 activity 与 parent 均为零，没有跨进程因果链接。[系统事件](focus-activity.json) · [上次同一展示的截图与录屏](../p0-p1-admission-26A428/RESULTS.md) |
| Spaces 真实可交互窗口 | BLOCKED | 正式监督器在发出退出请求前停止。透明普通应用窗口只可验证归属和恢复；键鼠与兄弟窗口需要独立证据。[Spaces 准入](spaces-admission.json) |
| 正式 Host 的普通交互双窗入口 | 源码 PASS，实机 NOT_RUN | Host 可在普通桌面登记同应用目标和旁窗，先保护原焦点，并检查两扇窗完整外框都不会盖住已有窗口。21 项 Swift 和 5 项 Python 定向回归通过，非标准安装位置实际被拒绝。定向测试进程的输入与系统实际命中分别记录。[源码、签名及回归](interactive-host-offline.json) · [拒绝回执](interactive-host-noncanonical.json) |
| Corner 只读签名夹具 | BLOCKED | 第一次提供的是较早升级包的收据，签名身份核对拒绝；用当前安装包匹配收据后，在普通桌面及焦点门槛停止。未投递停放或输入。[首次拒绝](corner-old-image-mismatch.json) · [匹配安装包后的结果](corner-readonly-admission.json) |
| 引擎撤权与所有权 | 源码 / ABI PASS | 基线复现被撤销的请求重新绑定下一代以及两个归属反例。修复后 103 项 Rust、104 项隔离构建测试和 35 项 Swift 测试通过。[撤权反例](engine-original-race.json) · [原始归属失败](engine-original-owner-failures.log) · [Rust](engine-revocation.json) · [Swift](engine-swift.xml) |
| Guardian 接管后、隐藏派发前发生中断 | 源码 / 签名辅助程序 PASS，实机 NOT_RUN | Rust 锁住从未入队的该次意图。原 Guardian 复核窗口并持久确认后，协调器才结束该次责任。106 项 Rust、50 项引擎 Swift、76 项协调器回归通过。真实签名 Guardian 拒绝非 Host 调用。[引擎](guardian-withdrawal.json) · [签名协议](guardian-signed-protocol.json) · [协调器](coordinator-withdrawal.json) |
| 分组命名与布局往返 | 源码 PASS | 实际离场几何只有在整组事务确认后才持久化，重复选择当前单窗保留用户的新位置。70 项离屏用例通过。[源码与测试](stage-groups.json) |
| 非活动组组合预览 | 源码与离屏绘制 PASS，新候选实机 NOT_RUN | 当前显示器已经显示的成员可用其最后有效帧组成一个组。窗口号重用、权限撤回、跨屏和全屏会使相应历史失效，缺帧的覆盖区保持不透明。63 项回归通过。[验收范围与旧版延迟](history-preview/receipt.json) · [离屏组合图](history-preview/offscreen/historical-group-complete.png) |
| 托管桌面的实际窗口生命周期 | 限定 PASS | 两个已登记的普通应用共三扇窗，重开其中一个后，另一个应用的两扇窗和组保留。系统原生归属仍为 UNKNOWN。旧角落原型收到了真实鼠标按下，最小化对照出现额外 Dock 图块，两者均为 FAIL。[实际窗口读回](hosted-windowserver/stage-group-lifecycle.json) · [角落录屏](hosted-windowserver/corner.mp4) · [对照汇总](hosted-windowserver/summary.json) |
| 隐藏桌面图标，点击空白墙纸显示 | 托管桌面 PASS，目标安装版 NOT_RUN | 在隔离桌面，点普通窗口时图标继续隐藏，点空白墙纸时显示，回到应用后再次隐藏。测试恢复原设置及清理了夹具。录屏完整性单列 UNKNOWN。[操作收据](hosted-windowserver/desktop-items.json) · [空白墙纸点击后截图](hosted-windowserver/desktop-items-blankWallpaperRevealed.png) |
| Riftlet 与 Saytile | 部分 PASS | 两款浏览器 18 个隔离草稿场景均为零发送。六个冷启动音频文件逐字节恢复。真实麦克风、已登录草稿未跑，中文识别受本地模型阻塞。[版本、测试与边界](../../embedded-tools/5.22-90/2026-11-23/results.json) |
| 翻译与词本 | 离屏词典与重开 PASS，安装版服务链路未通过 | 系统词典查到 bicycle，在产品内容视图离屏绘出“自行车”，临时词本重开后读到同一条目。Apple 英中翻译资源缺失，正式服务到原位气泡及保存真实译文待验。[固定词离屏实查](final-dictionary.json) · [历史服务与当前系统资源](history-preview/receipt.json) |
| 生产侧栏 A→B→C→A、10/50 次、与 Apple 的速度对照 | NOT_RUN | 先取得至少一个后端的真实单窗口隔离、输入和恢复证据。 |

下一个实机动作是在普通桌面和可交还的前台窗口自然可用时，由标准路径 Host 验证受控双窗与原焦点。先用只读入口核对身份、旁窗和定向输入；Spaces 写入另需一次完整 P0。现有 Rust 单窗写入入口只登记固定签名的透明窗。可交互目标和旁窗完成初次实测后，还须将其精确身份和旁窗不变条件接入该一次性迁入迁回路径，再核对真实系统输入和清理。Corner 须独立取得 Guardian 恢复租约及真实鼠标命中证据。实机回退基准为标准路径的签名 `bec6cb2`。[最终实体机读回](last-physical-host.json) · [备份核对](rollback-backup.json)

旧的 `ordinary-stage-fixture.py` 曾在只检查清理时给整次访问标记 PASS，还会为测试创建桌面。原入口现打印 BLOCKED 并退出。原实现逐字节保存，SHA-256 为 `9574e63abce0de7e63c61dd3b3e73988de5a2d6d1d6341e59c4694b7944110c6`。[历史源码](archived-ordinary-stage-fixture.py.txt)
