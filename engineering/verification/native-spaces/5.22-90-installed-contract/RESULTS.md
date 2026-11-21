# Nearpane 5.22（90）正式安装版验收

本页记录 `0777130` 的历史合同。更新候选 `365fdc4` 已将窗口调度区改为只呈现真实窗口。现装包及其截图见[后续窗口区复测](../5.22-90-window-roster/RESULTS.md)。

2026-11-20，Apple Silicon，macOS 27.0（26A428），一块物理显示器。**核心合同未通过，PR #15 保持 Draft。** 目前正式 Host 已有辅助功能、屏幕录制和事件投递权限。普通桌面切换、精确输入和迁窗仍有实机失败或阻塞。[机器可读汇总](summary.json) · [验收合同](../../../native-spaces/ACCEPTANCE.md)

## 安装、旧版本与权限

正式候选源码为 `0777130ffd7bdaade0b634ede26fb70d811e06b5`。已用同一 Developer ID 团队 `ZB9D4T66QB` 签名并在 `/Applications/Nearpane.app` 启动。先从 91 原位换装到 90 的 `00efb8b`，再换装到 90 的 `0777130`。两次都逐项验证了主程序和七个权限助手与前一包的双向签名要求，并由运行中的 Host 读回三项授权。安装检查沿用同一 bundle ID 和签名要求，允许版本与代码哈希变化；签名身份不连续的包会被拒绝。[首次换装](installation/installed-00efb8b/installation.json) · [最终换装](installation/installed-0777130/installation.json) · [Host 直接读回](installation/installed-0777130/live.json)

以前的两条授权曾只匹配旧构建。本轮另查到正式版与开发中间包同时登记了同一个选词服务。已修正服务声明和打包流程，移除两个旧 App 副本，导出目录也已注销。收尾时系统只登记正式路径，选词服务提供者由两个减为一个。之前每次弹窗的触发方无法逐次还原。本轮保留了现有系统授权。[早期权限记录](../5.22-91-permissions/RESULTS.md) · [旧副本](installation/removed-copies.json) · [服务修复前](tools/service-before.json) · [服务修复后](tools/service-after.json)

**arm64 签名候选** `Nearpane-5.22-90-0777130-macOS-arm64.zip`，24,459,785 字节，SHA-256 `f5bafe650ca73fc1b92b038b55818d3cf3571dc4b558501cac9658fe6640439f`。验收当天的 GitHub 资产与实机使用的包一致；草稿随后更新为上述窗口区修正版。此历史候选未经 Apple 公证。[当前草稿候选](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-0d613209d89c24e3816f) · [源码及资源标识](candidate.json)

## Native Spaces

验收入口可建立带 UUID 和创建回执的临时普通桌面，布置与清理专用文档，保留空桌面。产品输入只经已安装 Host 的侧栏。系统独立读回桌面身份、窗口归属、AX 焦点和两份文档的内容摘要；每次意图、投递、外部结果和清理分别记账。[运行入口](../../../../scripts/acceptance/native-spaces/README.md) · [真实桌面创建与回收记录](leases/)

| 场景 | 实机结果 |
| --- | --- |
| S01 桌面及窗口清单 | 中间候选真实建立 A/B/C，系统确认分别有 1、1、0 扇普通窗口。侧栏 7/7 个桌面身份和高亮一致，C 行可用并提示归属未读全，但 B 漏列 1 扇已确认的窗口。最终候选已补后台窗口双向归属校验，受控建场未能稳定落在目标桌面上，修复效果 **BLOCKED**。[窗口清单原始比对](spaces/s02/actions.jsonl) · [最终建场](spaces/hover-core/results.json) |
| S02 普通空间选择 | 合同内符合三桌面前提的选择 **0/50**。在最终候选上保留三个已证明归属的目标，从专用文档起点另外发起 **9 次**正式行选择，系统确认到达 **0**，失败 **9**，未知 **0**。另有 2 次准备点击也未到达。最后一次读到第三个 Space，成因未知，随即停发。桌面数字快捷键均关闭，已核验的相邻路径经过原有全屏桌面。[9 次逐项读回](runs/retained3/actions.jsonl) · [另一准备点击](runs/retained/actions.jsonl) · [系统快捷键](spaces/adjacent-shortcuts.json) |
| W01 同应用双窗 | 中间候选两次正式按行选窗，系统 AX 均读到指定窗口。首个输入标记与两份文档摘要一致，第二次不符，**1 通过、1 失败**，未达到 10 次。最终候选的独立 TextEdit 实例又记录 1 个意图，未取得已投递的确认，记 **UNKNOWN**；最终回读确认该测试进程已退出。[逐次焦点与输入](spaces/w01/same-app-documents/actions.jsonl) · [最终 TextEdit](spaces/w01-final/actions.jsonl) · [退出读回](restoration/textedit-final.json) |
| D01 单窗跨桌面迁移 | **BLOCKED**。正式 Host 返回可切换、不可迁移；此系统构建未提供当前迁窗后端需要的可链接入口。实际拖动 **0 次**。往返、兄弟窗保持、取消与拖动中关窗均未验证。[正式能力与拖动数](spaces/final-extra/D01.json) · [系统入口检测](move-availability.txt) |
| S03、W02、R01 | **BLOCKED**。可持续操作的普通桌面起点未成立，未取得系统重排后返回、跨桌面精确输入或 20 组连续选择的合格样本。[最终合同运行](spaces/final-extra/results.json) |
| W03、V01、L01/L02、C01、P01、I01 | 本轮未覆盖完整应用矩阵、预览、布局和产品创建/删除场景。P01 的撤销与再授权未执行。I01 的安装、运行身份已确认，核心场景仍未通过。[全项状态](summary.json) |

## 工具、恢复与性能

| 项目 | 实机结果 |
| --- | --- |
| 语音冷启动 | 采到首个有效 PCM 缓冲后才显示就绪。最终候选三次独立冷启动，经内置扬声器和麦克风播放无引导语短句。**今天测试语音、窗外正在下雨**两句的最终稿和录音复识均逐字一致。**蓝色雨伞放在门口**录到 64,000 帧，临时稿和录音复识均 8/8，切入原有全屏后未取得正式暂停及最终稿，记 **UNKNOWN**。中间版第一次短句错识，以及随后调换顺序的两次通过均保留。[最终三句](runs/voice-final/results.json) · [此前错识](voice/02-ordinary-cold/results.json) · [调换顺序复测](voice/03-counterbalanced/results.json) |
| 截图附加 AI 草稿 | **BLOCKED**。正式区域截图入口已调起，无法确认整个选区仅由选择器和夹具覆盖。正式 Chrome 的全新访客资料打开了 ChatGPT 官网（HTTP 200），页面未提供可用输入框。附件 0，点击、回车、提交和发送按钮事件均为 0；访客实例与资料已清理。[截图判定](runs/tools-final/capture/result.json) · [正式浏览器收据](runs/tools-final/official-browser/result.json) |
| 原位翻译、单词本 | **翻译 FAIL，持久化 BLOCKED**。选中合成文本 *The blue bicycle* 后系统服务已投递。在中间版确认模型已安装、正式 Host 已读服务剪贴板的情况下，也没有出现选区旁的翻译气泡。最终版同样未出现气泡，重启前后匹配条目均为 0，缺少可比较的既有条目。两种临时下载的语言模型已恢复到测试前状态。[选区和翻译](runs/tools-final/translation/result.json) · [已安装模型时的诊断](tools/physical-tool-diagnostics.json) · [重启后读回](runs/tools-final/wordbook/result.json) · [语言恢复](restoration/language-restoration.json) |
| 隐藏预算和自动恢复 | **PASS（该子项）**。有录屏权限的正式 Host 从菜单隐藏，2 秒稳定后持续观察 60 秒；没有新增抓屏、活动流、缓存或图库会话。用正式菜单自动显示后，再次读到可见状态。在普通桌面、有活动图库的中间版也完成同一流程。[最终逐次采样及显示](runs/final-hidden/actions.jsonl) · [普通桌面采样](runs/hidden2/actions.jsonl) |
| 全屏、Split View、多屏 | 普通最大化保留普通 Space；从正式侧栏进入专用文档的原生全屏已由 WindowServer 确认。沿产品入口返回未证实，**F01 部分通过**。Split View 到达系统第二窗选择器，无法唯一确认受控第二窗，**BLOCKED**。只有一块物理显示器，**M01 BLOCKED**。[全屏与选择器读回](runs/final-lifecycle/results.json) |
| 恢复 R02 | 测试文档重开后取得新 PID 和窗口编号，系统重新确认归属。正式 Host 正常重开后 PID 更新，数据代际和配置不变。当前登录会话在使用，锁屏/解锁、睡眠/唤醒未运行；显示器插拔缺设备。[重启收据](runs/final-lifecycle/results.json) |
| 性能 N01 | 记录了两次未预热的进程树物理内存读数：135,792,824 和 81,463,504 字节，相隔约 30 秒。完整系统原生 20 次对照及预热后的 5 × 20 次操作 **未运行**，P95 和稳态回收均无结论。[原始内存采样](runs/idle2/results.json) |

## 实机媒体、回归和现场收尾

- 最终安装版的当前桌面行标题由 WindowServer 在取像前裁切到正式侧栏；原生全屏截图和 6.475 秒无音轨录屏仅包含专用文档。中间候选另保留 9.957 秒的侧栏标题实录。[正式侧栏截图](runs/daily-title/current-row-title.png) · [最终全屏截图](runs/final-lifecycle/owned-fullscreen.png) · [最终文档实机录屏](runs/final-lifecycle/owned-window.mp4) · [中间版侧栏录屏](runs/sidebar-movie/installed-space-title.mp4)
- 最终产品源码 Swift 串行测试 **518/518**，验收脚本 Python 测试 **32/32**。中间版的 517 项并行测试中，两项时序测试共记录五个问题；同版串行 517/517。各次结果独立保留。[测试矩阵](build-matrix.json)
- **33/33** 次隔离运行均已恢复日常 Host、核对配置摘要并清除临时资料。独立读回确认共 **16** 个测试普通桌面全部消失，专用夹具进程为 0。原有四个 Space 的身份集合一致，现场次序与开工时不同，收尾保留了现场次序；个别试次的原前台或焦点也未恢复。当前系统仅登记 `/Applications/Nearpane.app`。[收尾核验](daily-final.json) · [各次恢复](restoration/) · [产物 SHA-256](CHECKSUMS.sha256)
