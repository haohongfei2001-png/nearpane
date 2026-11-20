# 5.22（90）当前桌面与逐窗预览

当前正式安装候选为 `32b9f92`，版本 5.22（90）。在 macOS 27.0（26A428）、arm64、一块 1470 × 956 pt 显示器上，正式侧栏的两张窗口卡在两批独立实测中共确认 24/24 次内容更新。原始展示时钟、各窗口的误差区间以及早期失败均可复核。R4 视觉设计沿用 PR #15。

| 实机动态预览 | `32b9f92` 的独立读回 |
| --- | --- |
| 两窗同步 | 系统的两个独立文档源与正式 Host 窗口同时采样，共 4,327 条呈现记录。每窗各 6 次变色全部确认，7 个状态均在同一张正式侧栏画面上连续两帧匹配。错窗、空白均为 0。[机器收据](physical-08/result.json) · [独立重算](physical-08/replay.json) |
| 延迟 | 首次确认呈现差的 P50 为 36.9 ms、P95 与 P99 为 46.48 ms；考虑源与侧栏之间的采样区间，延迟上界的 P50 为 54.45 ms，P95 为 63.8 ms。本轮无 Apple 原生对照。[逐帧数据](physical-08/presentation-frames.jsonl.gz) |
| 动态实拍 | 两个动画各保留同一正式侧栏呈现里的一个 8×8 原生像素块，播放间隔取自系统展示时钟。[窗口 A](physical-08/media/sampled-card-1.apng) · [窗口 B](physical-08/media/sampled-card-2.apng) · [媒体收据](physical-08/media/receipt.json) |

第二批在同一安装版确认另 12/12 次变色。P50 为 33.18 ms，P95 为 44.10 ms，P95 区间上界为 61.36 ms。先前在台前调度关闭时的收尾分类未通过；此次分别核对 OFF 状态下的零卡、ON 状态下的系统辅助表面和原偏好，完整收尾通过。两次实测均有 7 个状态双卡同时命中，空白和错窗均为零。[双卡实机原图](physical-09/media/paired-overview.png) · [第二批独立时钟](physical-09/replay.json) · [外层收尾](physical-09/lease.json)

## 此前安装候选 `f50d6ac` 的实机交互


| 已实测项目 | 实机结果 |
| --- | --- |
| 台前调度开启 | 原安装同时显示系统窗口区和 Nearpane 卡片。当前候选的实际工具面板为 240 × 150 pt，语音、截图和文件三个入口都可见。两次读回均为 0 张窗口卡、0 条捕获流、0 个新增视频帧。[原安装](baseline-duplicate-switchers.json) · [修正后](installed-stage-manager.json) |
| 系统与 Nearpane 交接 | 在隔离的临时普通桌面，登录域与正式 Host 均确认 ON → OFF → ON。OFF 时空桌面两次读回均无卡片，原偏好及桌面顺序恢复。此试验只暂存一个既有偏好键。此前另一次从 Apple 系统设置按下真实开关后也读到 OFF。[关闭读回](physical-03/stage-off-runtime.json) · [返回读回](physical-03/stage-restore-runtime.json) · [系统设置操作](physical-02/stage-off.json) |
| 实机截图 | 图中为独立精确窗口过滤器取得的一个 Nearpane 工具窗，480 × 300 px，已与正式 Host、AX 控件和 WindowServer 窗口号比对。透明处由采集器衬白。[原图](physical-03/compact-tools.png) · [像素与归属收据](physical-03/compact-tools.json) |
| 当前物理显示器的桌面切换 | 正式侧栏在 A 的两个受控窗口、空 B 与原 A 之间 2 → 0 → 2，空 B 零泄漏。通过原生调度中心选桌面。三指触控板动画期间的逐帧跟踪未测。[系统与侧栏读回](physical-05/paired-preview.json) |
| 每窗都显示自己的内容 | 两张卡同屏可见，均携带真实文档标题栏与画面，独立源色标为红/蓝。两次身份核对限定到隔离签名 Host 的同一窗口。[双卡实拍](physical-06/paired-overview.png) · [逐像素记录](physical-06/image-receipt.json) |
| 隐藏后恢复 | 有两条活动流时从正式状态栏隐藏，一分钟隐藏预算通过。重新打开后两条流恢复。[逐时刻读回](physical-05/hidden-minute.json) |
| 安装和权限 | 系统注册一份 Nearpane。三项已有授权均在更新后的正式 Host 内读回允许。归档与安装的 248 个文件系统条目逐项一致。[安装](installation.json) · [权限](installed-permissions.json) · [归档核对](archive-installed-match.json) |

原生卡片按物理显示器、当前 Space、窗口号和进程代际筛选。每个可采集窗口使用独立的 ScreenCaptureKit 流，同屏最多同时保有八条。原生 Split View 从两个真实成员和系统几何读取布局。下列实测记录据此判定内容和延迟。

两张测试桌面尚待系统回收。原桌面为 6，第五次试验创建了 5094、5095。系统全屏窗口均已正常退出，日常资料及台前调度开关已恢复，调度中心仍未返回可操作的桌面列表。当前为 5095；原有普通桌面 4、6 均保留。精确原焦点未知。[桌面恢复收据](physical-05/recovery.json) · [P0–P6 机器清单](results.json)

## 试验及回退

- 首个修订包收起了重复窗口区，也把工具意外折叠。重新安装当前候选后，正式 AX 和屏幕上的窗口尺寸均确认工具已恢复。[首次回归](first-install-hidden-tools.json) · [当前安装](installed-stage-manager.json)
- 第一次建场时 macOS 的紧凑桌面栏未提供可交叉验证的坐标。未向桌面栏发起选择，已删除新增桌面。[第一轮](physical-01/workspace.json)
- 第二次以系统语义按钮选中临时桌面。系统设置关闭台前调度后出现一次新的左键计数，未建立双窗夹具。已恢复唯一改动的偏好、正常退出测试创建的系统设置、回收临时桌面并确认原顺序。精确原焦点未确认。[中断](physical-02/workspace.json) · [收尾](physical-02/recovery.json)
- 第三次实测正式 Host 双向交接和实拍通过。两个已登记夹具窗口在系统列表出现，早期读回未找到相应正式卡片，随后有额外普通层表面，未取得延迟样本。Split View 读取器拒绝了同一临时应用的路径别名。该次已回收桌面及夹具。[双窗](physical-03/dual-preview.json) · [分屏](physical-03/split-view.json) · [收尾](physical-03/workspace.json)

- 第四次用 Launch Services 启动两扇隔离文档。正式侧栏 0 → 2 → 0 张卡，连续两次读到两条活动流，累计交付帧数 738 → 773。系统切到空 B 时，两次都读到 0 张卡并返回 A。像素验收器把 Swift 的 `[CGFloat]` 当作 `[Double]`，导致采样前拒绝，未形成延迟样本。分屏测试确认两扇标准窗口的 AX/CG 几何与桌面归属，额外普通层表面尚未核实，未按下分屏按钮。两张临时桌面已回收。[双窗与跨桌面读回](physical-04/two-window-result.json) · [正式 Host 过滤记录](physical-04/catalog-final.json) · [分屏](physical-04/split-result.json)

- 第五次的 32 批采样只确认 12 次变色中的 5 次，中位取样间隔 482.7 ms。两路受控源均可读，图中稳定未知色保留原判。首次真实按下了测试窗的系统左侧分屏菜单，系统选择器的第二步未完成。第六次在同一已登记空桌面取得清晰双卡原图，常驻计时器在正式 Host 的另一扇窗口覆盖源采样点时停止。[第五次](physical-05/paired-preview.json) · [分屏菜单回执](physical-05/split-view.json) · [第六次](physical-06/paired-preview.json)

- 第六次补测留下 4,308 条原始呈现记录，严格分类为 7/12。两窗 28 个颜色相位与 sRGB 转为 Display P3 后的数值相符，84 个色通道最大误差 2/255；常驻采集器也丢弃了部分早于预计展示到达的合格回调。正式 APP 改为请求带明确定义的 sRGB。读回器单独用两个时钟核对早到的回调。[原始未通过记录](physical-06b/result.json) · [ColorSync/VideoToolbox 复核](physical-06b/color-and-clock-diagnosis.json)
- 第七次在系统单独的 type 4 Space `5101` 确认真实全屏。受控 A 通过 AppKit 正常退出，全屏 Space 消失，两扇窗口的系统归属、AX 标志和夹具读回均回到普通桌面。独立核验后正常关闭夹具，两窗号和原进程都消失。双窗原生 Split View 的第二步仍未确认。[全屏](physical-07/native-round-trip.json) · [已验证的正常关闭](physical-07/normal-exit.json)
- 当前候选的一次计时批次 12/12 通过。外层收尾在台前调度关闭期间试图用只接受开启状态的分类器核对隐藏系统窗口，记录为 BLOCKED。两扇测试窗和测试进程均正常退出，原偏好及日常资料独立读回恢复。[外层收据](physical-08/lease.json) · [日常资料](physical-08/profile.json)

当前安装 ZIP 的 SHA-256 为 `be2d4cbca0091e5613e8d5e71148e1e8630e3cb16d4977d880f664bbbb9a1a28`。上一签名安装包 `f50d6ac` 的 SHA-256 为 `ca53b88ba1b174a8f0a443990403bb4122dd55ab7796824184e9011c9b3b9bd6`。两个完整包均保存在既有 Draft 附件中。本次更新后，正式 Host 的辅助功能、录屏和事件投递授权均读回允许，248 个文件系统条目与 ZIP 完全一致。[候选及回退](physical-08/candidate.json) · [权限](physical-08/permissions.json) · [安装与归档](physical-08/archive-installed.json)

另外从同一归档制成的独立分发暂存件已经通过 13/13 个 Mach-O 的 Developer ID、加固运行时及安全时间戳检查。它与日常安装及上面的实测 ZIP 分开保存。Apple 公证、票据装订、干净设备安装及 Sparkle 线上更新仍未通过。本轮仅核对有无已配置的非交互公证凭据，未读取密钥。[暂存包结果](physical-08/distribution-staging/result.json) · [13 个签名](physical-08/distribution-staging/package.json)

P0 的 26A428 动作适配器仍关闭。归档回放发现落地后 2.377519 秒换到另一个前台进程，当时仍在目标桌面，随后才读到 Space 改变，原因未知。新增跨动作只读观察器，下一轮单次、连续 10 次以及 50 次正式合同均需各自的新证据。P1 在独立分支确认了实际系统类、两个精确方法签名与模拟调用，真实迁窗为零。[P0 跨动作观察](../5.22-p0/persistent-drift-observer/README.md) · [P1 独立准备](https://github.com/haohongfei2001-png/nearpane/blob/5217dbf4847ef7737cf23d4e6ff3d15b8ea475e6/engineering/verification/native-spaces/5.22-p1-bridge/RESULTS.md)
