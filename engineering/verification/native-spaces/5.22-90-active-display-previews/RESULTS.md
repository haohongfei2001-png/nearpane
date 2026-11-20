# 5.22（90）当前桌面与逐窗预览

## 正式安装候选 `d2d0bb6`

Nearpane 5.22（90）在 macOS 27.0（26A428）、一块 1470 × 956 pt 显示器上进行了四轮同屏实测。两扇真实测试窗各自变色 24 次，正式侧栏确认 **48/48** 次更新。17,295 条源与侧栏呈现记录中，有 5,708 帧侧栏画面同时采到了两个色标，错窗、空白、未识别颜色和灰色中断均为零。单次变色首次得到确认的呈现差合计 P50 为 32.50 ms、P95 为 48.94 ms、最大值为 61.20 ms。考虑采样区间后的 P95 上界为 66.46 ms。Apple 原生同条件样本为零。[各窗逐帧结果](results.json) · [Apple 对照资格](physical-13/apple-reference.json)

| 正式 Host 启动方式 | 已确认变化 | P50 | P95 | 逐窗证据 |
| --- | ---: | ---: | ---: | --- |
| 隔离资料，启用双窗诊断 | 12/12 | 26.20 ms | 51.31 ms | [原始时钟重算](physical-12/replay.json) · [卡片连续性](physical-12/continuity.json) |
| 隔离资料，常规启动并录制整卡 | 12/12 | 34.03 ms | 38.72 ms | [原始时钟重算](physical-13/replay.json) · [卡片连续性](physical-13/continuity.json) |
| 隔离资料，常规启动 | 12/12 | 29.45 ms | 46.41 ms | [原始时钟重算](physical-14/replay.json) · [卡片连续性](physical-14/continuity.json) |
| 隔离资料，常规启动并录制无损整卡 | 12/12 | 29.19 ms | 61.20 ms | [原始时钟重算](physical-15/replay.json) · [卡片连续性](physical-15/continuity.json) |

**五个不同应用同屏。** 本轮分别启动五个签名标识不同的普通应用，各有独立进程、一扇测试窗口和独立色标。初始状态与五次逐窗变色共六个阶段，在同一个正式侧栏窗口、同一帧内读到五张卡。30/30 项卡片与源窗对应，各阶段均至少两次匹配。五个测试进程全部退出，空桌面和原台前调度设置均独立读回。该轮只保存色标与几何收据。[五窗逐项独立复核](five-window/installed/replay.json) · [系统与正式侧栏原始读回](five-window/installed/result.json)

**灰帧原因。** 前一诊断版的采集流仍在交付，B 窗绘制时一次所有者查询失败，侧栏随即画出轮廓。修复后，活采集流仅在进程代际、可执行文件、签名、普通应用身份、共享资格及窗口归属均成立时继续显示。新安装包的正式 Host 记录到 3 次 AppKit 应用查找缺失，均完成了独立身份复核。对应整轮两张卡都未出现灰帧。早期 212.35 ms 样本没有同类跟踪，原始失败保留。[旧版关联收据](physical-11/diagnosis.json) · [修复后的三次读回](physical-12/owner-readback.json)

**无损实机录像。** 第四轮正式侧栏的两张完整卡片共录制 2.55 秒，两扇文档都在画面中变色。30 帧原始呈现逐像素解码并与采集时的摘要比对一致。最大播放边界误差为 7.88 微秒。文件同时保留每帧的原始时钟。[完整双卡无损动画](physical-15/media/paired-cards.apng) · [实机截图](physical-15/media/paired-overview.png) · [独立像素复核](physical-15/media/lossless-pixel-replay.json)

**此前有损录像。** 第二轮的双卡截图和 2.78 秒 MP4 均取自同一个正式侧栏，只含已登记的测试文档。视频有 33 帧、无音轨。独立解码后，66 次卡片色标读回中有 8 次因 H.264 色差超出原始色标阈值，不能用这个有损文件证明原始色值。逐帧延迟使用原始无损采样。[双卡原图](physical-13/media/paired-overview.png) · [实机录像](physical-13/media/paired-cards.mp4) · [完整解码读回](physical-13/media/decoded-cards.json)

**侧栏归属。** 当前安装包在台前调度开启时保留三项工具，实测 0 张窗口卡、0 条采集流。台前调度关闭后，四轮都确认初始桌面为零卡，打开两扇普通窗口后为两卡，窗口退出后归零。上一签名候选在两个真实桌面之间验证了有窗 A → 空 B → 原 A，对应 2 → 0 → 2。物理三指滑动中逐帧表现、两块显示器、双窗原生 Split View 尚待验收。系统调度中心展开动画与台前调度的结果分别记录。[台前调度开启](physical-12/installed-stage-manager.json) · [本轮日常设置恢复](physical-13/lease.json) · [两个桌面间的实际读回](physical-05/paired-preview.json)

**当前安装版隐藏与恢复。** 正式状态菜单隐藏侧栏一分钟，7 次读回均为零活动流和零在途采集，期间没有新增采集请求和交付帧。测试自动恢复侧栏后，原两张卡均重新收到画面。两扇测试窗正常退出，日常配置恢复。首次临时检出的仓库缺少依赖清单，在启动夹具前中止。[逐次系统读回](installed-hidden-minute/actions.jsonl) · [恢复及初次未运行记录](installed-hidden-minute/result.json) · [首次建场](installed-hidden-minute/preflight.json)

**精确焦点。** 普通 AppKit 编辑器夹具的第一次正式选窗和键盘标记落入 A，B 保持空白。第二次选择后 B 已是 key/main，独立标记投递返回已发出，最后 B 仍为空，A 的摘要也没有变化。因此完整的 10 次合同未通过。[两次输入和最终文档摘要](same-space-focus/owned-two-editor/keyboard-readback.json)

**TextEdit。** 对两份全新 TextEdit 文件执行了 1 次正式侧栏按压，收到系统回执。随后的输入前核验未能确认目标，提交键盘标记 0 次。之后独立验证两扇窗口均属于原测试文件，正常退出该测试进程，两次内核读回均确认进程已退出。新的两窗试验在正式控件稳定后收到了按压回执；两次系统读回确认目标焦点，发标记前 AX 窗口数从 2 变成 4，输入被中止。在另一对新文件上实际复制了 4 个 AX 引用，额外项中有一个属于测试 TextEdit 的独立对话框，窗口号与两份文档均不同。未读对话框标题或正文。之后两扇临时文档再次独立验证并正常退出。这一对话框的身份只适用于最后一轮。[按压后读回](same-space-focus/ready-marker-attempt/W01-system-documents.json) · [额外对话框](same-space-focus/bounded-enrollment/diagnosis.json)

两张更早的测试桌面 5094、5095 仍待回收，当前为 5095，原桌面 4、6 保留。[选窗记录](same-space-focus/W01-system-documents.json) · [夹具退出](same-space-focus/recovery-kernel.json) · [桌面清单](physical-12/desktop-readback.json)

**安装、回退与验证。** 当前签名 ZIP 的 SHA-256 为 `a630316f845b90525bd158e64f4eac633a473b0ab47773453e43b3433bd841a4`。上一签名候选为 `32b9f92`。两包均在原 Draft 附件中。从 GitHub 完整下载当前包的 25,241,606 字节，SHA-256 再次匹配。[下载校验](physical-12/github-binary-readback.json) 安装和归档的 248 项逐一一致，系统登记一份 Nearpane，三项已有授权在正常启动的 Host 内读回为允许。560 项 Swift 测试和候选原生 CI 均通过。发行暂存副本的 13 个二进制均有 Developer ID 安全时间戳，公证及干净设备验收待测。PR #15 保持 Draft。[候选和回退](physical-12/candidate.json) · [安装核验](physical-12/archive-installed.json) · [权限](physical-12/permissions.json) · [签名](physical-12/distribution-staging/result.json) · [原生 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44786730117)

## 上一签名候选 `32b9f92`

该候选为 5.22（90）。在 macOS 27.0（26A428）、arm64、一块 1470 × 956 pt 显示器上，正式侧栏的两张窗口卡在三批独立实测中共确认 36/36 次内容更新。原始展示时钟、各窗口的误差区间以及早期失败均可复核。R4 视觉设计沿用 PR #15。

| 实机动态预览 | `32b9f92` 的独立读回 |
| --- | --- |
| 两窗同步 | 系统的两个独立文档源与正式 Host 窗口同时采样，共 4,327 条呈现记录。每窗各 6 次变色全部确认，7 个状态均在同一张正式侧栏画面上连续两帧匹配。错窗、空白均为 0。[机器收据](physical-08/result.json) · [独立重算](physical-08/replay.json) |
| 延迟 | 首次确认呈现差的 P50 为 36.9 ms、P95 与 P99 为 46.48 ms；考虑源与侧栏之间的采样区间，延迟上界的 P50 为 54.45 ms，P95 为 63.8 ms。本轮无 Apple 原生对照。[逐帧数据](physical-08/presentation-frames.jsonl.gz) |
| 动态实拍 | 两个动画各保留同一正式侧栏呈现里的一个 8×8 原生像素块，播放间隔取自系统展示时钟。[窗口 A](physical-08/media/sampled-card-1.apng) · [窗口 B](physical-08/media/sampled-card-2.apng) · [媒体收据](physical-08/media/receipt.json) |

第二批在同一安装版确认另 12/12 次变色。P50 为 33.18 ms，P95 为 44.10 ms，P95 区间上界为 61.36 ms。先前在台前调度关闭时的收尾分类未通过；此次分别核对 OFF 状态下的零卡、ON 状态下的系统辅助表面和原偏好，完整收尾通过。两次实测均有 7 个状态双卡同时命中，空白和错窗均为零。[双卡实机原图](physical-09/media/paired-overview.png) · [第二批独立时钟](physical-09/replay.json) · [外层收尾](physical-09/lease.json)

第二批的两张原生采样动画可同步播放。MP4 只有实际侧栏中两个各 8 × 8 像素的采样区域，按整数倍放大。系统解码读回 29 帧、4.83 秒、无音轨，最大时间误差 5.3 微秒。H.264 有色彩损失，色值以无损 APNG 与帧收据为准。两次完整双卡 MP4 采集均在身份或像素复核处停止，未发布未经核实的整卡视频。[实测局部录像](physical-09/media/two-sampled-patches.mp4) · [解码收据](physical-09/media/two-sampled-patches.json)

第三批确认 12/12 次变色，P50 33.99 ms，P95 与最大值均为 212.35 ms；P95 区间上界 229.18 ms。B 窗第一次变色时，正式卡片中央从源变化后约 46 至 196 ms 连续呈现灰色。受控源仍在变色，另一张卡正常。三批共 36 次最终正确更新。逐帧连续显示和稳定低延迟仍未通过。同期两扇源窗都不透明，灰帧 alpha 为 159–160；正式卡片的离屏渲染中，启用状态下即使输入透明图像，也实测得到不透明底色，这次 212 ms 中断的具体原因尚未确定。[离屏对照](physical-10/offline-card-opacity.json) 此轮整卡 PNG 和 MP4 的抓取资格未成立，原始采样保留。[灰帧逐项收据](physical-10/neutral-interruption.json) · [源时钟](physical-10/replay.json) · [外层收尾](physical-10/lease.json)

对三批原始帧另行核对了半透明灰。只有当相邻两次侧栏呈现均为单一中性色、两端都由同一窗同一相位的不透明源帧夹住时，才计入确认区间。第一批也有两段，最长 33.33 ms；第二批未检出符合条件的区间；第三批两张卡均有确认区间。图像更新次数和连续性独立计分，后续实测发现确认灰段时整体验收将失败。[第一批](physical-08/continuity.json) · [第二批](physical-09/continuity.json) · [第三批](physical-10/continuity.json)

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

实测互斥针对 macOS「台前调度」。打开系统「调度中心」时，侧栏面板采用 AppKit 的 `.transient` 行为。本轮没有调度中心展开动画中两者是否同帧可见的实机判定。

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
- 候选 `32b9f92` 的一次计时批次 12/12 通过。外层收尾在台前调度关闭期间试图用只接受开启状态的分类器核对隐藏系统窗口，记录为 BLOCKED。两扇测试窗和测试进程均正常退出，原偏好及日常资料独立读回恢复。[外层收据](physical-08/lease.json) · [日常资料](physical-08/profile.json)

上述 `32b9f92` 安装 ZIP 的 SHA-256 为 `be2d4cbca0091e5613e8d5e71148e1e8630e3cb16d4977d880f664bbbb9a1a28`。上一签名安装包 `f50d6ac` 的 SHA-256 为 `ca53b88ba1b174a8f0a443990403bb4122dd55ab7796824184e9011c9b3b9bd6`。两个完整包均保存在既有 Draft 附件中。本次更新后，正式 Host 的辅助功能、录屏和事件投递授权均读回允许，248 个文件系统条目与 ZIP 完全一致。[候选及回退](physical-08/candidate.json) · [权限](physical-08/permissions.json) · [安装与归档](physical-08/archive-installed.json)

另外从同一归档制成的独立分发暂存件已经通过 13/13 个 Mach-O 的 Developer ID、加固运行时及安全时间戳检查。它与日常安装及上面的实测 ZIP 分开保存。Apple 公证、票据装订、干净设备安装及 Sparkle 线上更新仍未通过。本轮仅核对有无已配置的非交互公证凭据，未读取密钥。[暂存包结果](physical-08/distribution-staging/result.json) · [13 个签名](physical-08/distribution-staging/package.json)

P0 的 26A428 动作适配器仍关闭。归档回放发现落地后 2.377519 秒换到另一个前台进程，当时仍在目标桌面，随后才读到 Space 改变，原因未知。新增跨动作只读观察器，下一轮单次、连续 10 次以及 50 次正式合同均需各自的新证据。P1 在独立分支确认了实际系统类、两个精确方法签名与模拟调用，真实迁窗为零。[P0 跨动作观察](../5.22-p0/persistent-drift-observer/README.md) · [P1 独立准备](https://github.com/haohongfei2001-png/nearpane/blob/5217dbf4847ef7737cf23d4e6ff3d15b8ea475e6/engineering/verification/native-spaces/5.22-p1-bridge/RESULTS.md)
