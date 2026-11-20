# 5.22（90）正式 Host 验收

研究基线为 `3151827`，PR #15 起点为 `6f85f73`，其历史包含 PR #14 的 `629524b`。本页记录 macOS 27.0（26A428）、单块物理显示器上的安装和操作，其他环境的结果另列。[源码路径与技术裁决](../../../research/IMPLEMENTATION-PATH-MAP.md)

## 窗口调度区

已安装的 `f9e981c` 在两个独立回合均通过空、打开两扇文档、关窗测试。三个状态分别为 0、2、0 张窗口卡，独立空间行、占位文字和重复控件均为 0。双窗截图第二张卡有紫色窗口预览，第一张为轮廓，两张预览像素均就绪尚未通过。[空态实拍](window-roster/empty-before-sidebar.png) · [两扇文档](window-roster/two-documents-sidebar.png) · [关闭后](window-roster/empty-after-sidebar.png) · [窗口与侧栏逐项读回](window-roster/results.json)

实机录屏只采集身份已核对的正式侧栏与系统壁纸。12 帧通过前后窗口、几何及配置核验，按实际时戳编码为 14.84 秒 H.264，单视频轨、无音轨。第一次因并发采集超时，只录到打开文档。该尝试和未采集区间随收据保留。此片记录窗口打开及关闭，跨 Space 动画单独验收。[实机录屏](window-roster/installed-sidebar.mp4) · [帧、间隔和哈希](window-roster/recording.json) · [首次不完整录制](window-roster/first-recording-incomplete.json)

## 相邻普通桌面

正式入口为悬浮侧栏中具体窗口的 AX 按钮。验收先绑定安装路径、签名、进程出生时间和隔离数据目录。独立进程只建场、清理并读取 WindowServer 的实际 Space。计入产品切换需要同一意图 ID、源/目标 ID 和 UUID、真实三阶段投递、Host 终态与独立持续到达证据。

| 安装版运行 | 结果与系统读回 |
| --- | --- |
| [第一次普通桌面建场](01-ordinary-setup/results.json) | 前台变化，停止。临时普通桌面已回收。 |
| [既有全屏](02-user-fullscreen/results.json) | 原前台是既有全屏，未向它投递输入。 |
| [自有全屏](03-owned-fullscreen-setup/results.json) | 系统未同时证实两扇窗口归属，收尾原始焦点为 UNKNOWN。 |
| [连续建立普通桌面](04-overview-dismissal/results.json) | 第一次添加后未确认 Mission Control 已退出，第二次添加未投递。随后按创建收据回收，原有三个空间和当时前台均已独立核对。[回收收据](04-overview-dismissal/lease-cleanup.json) |
| [核对原生桌面按钮](05-tile-identity/results.json) | 连续添加和回收两个桌面成功；系统按钮的 AX 归属与旧检测假设不符。 |
| [两扇真实普通窗口](06-background-AX/results.json) | 系统原生控件选中两个临时桌面，各窗口在所属桌面均有精确标准 AX 身份。切走后，第一扇窗口仍有双向唯一 Space 归属，但系统 AXWindows 清单将其省略。此轮两租约均已释放，正式侧栏投递为 0。[两窗口读回](06-background-AX/fixture-second-document.json) · [系统收尾](06-background-AX/lease-cleanup.json) |
| [清点空桌面期间有新用户输入](07-new-input/results.json) | 取消建场，退出两个自有应用。随后按 ID/UUID 独立回收两租约，保留新选中的全屏空间；精确焦点恢复为 UNKNOWN。[回收收据](07-new-input/lease-cleanup.json) |

以上建场成功次数和历史版本的尝试均不计入本候选的往返、10 次或 50 次门槛。

## 构建与兼容性

- 本机使用仓库标准测试入口，524 项 Swift 测试、78 个测试套件通过。macOS 26.7.2 的 GitHub runner 编译了生产 helper，运行真实生产协议与 Host journal 的 13 项 Swift 测试，并完成 41 + 13 项 Python 测试。此前有四次失败和一次工作流返回成功却没有执行 Swift 测试，均保留在基线收据中。工作流现要求四个套件和非零测试的结束记录。[机器收据](baseline.json) · [CI 运行日志](https://github.com/haohongfei2001-png/nearpane/actions/runs/44720154517)
- P1 仅读取系统 ABI。当前系统的 `initWithWindows:spaceID:` 和无冒号 `performWithWMBridgeDelegate` 均存在，后者返回 void；操作对象创建为 0，迁窗请求为 0。[ABI 收据](move-abi.json)
- 同一 macOS 26.7.2 runner 随后也完成了生产 NearpaneUI 在 foundation-only 配置下的编译。保留原主题设置行为，避免了旧 Swift 编译器的 IR 生成错误。[编译及协议收据](https://github.com/haohongfei2001-png/nearpane/actions/runs/44721534963)
- P4 本地翻译/单词本与 Saytile 独立分支保留持久化和最终稿测试；P5 独立分支保留预热 5×20 的统计与真实进程用量采样。正式安装版的原位翻译、完整首句矩阵、多屏、Split View、睡眠恢复和性能门槛仍待实测。[P4 源码与收据](https://github.com/haohongfei2001-png/nearpane/tree/baa28fe4b40205e1014b4f702ba1bdd80c6fce46/engineering/verification/native-spaces/5.22-p4) · [P5 数据和门槛](https://github.com/haohongfei2001-png/nearpane/blob/30595b287e66c7fb79ab0bb5999509745f0eaaaa/engineering/verification/native-spaces/5.22-p5/harness.json)

## 签名候选与回退

`Nearpane-5.22-90-f9e981c-macOS-arm64.zip` 已原位安装。正式 Host 与七个权限助手的指定要求逐项双向相容，辅助功能、事件投递和录屏均由安装版进程实时读回。授权延续依赖这组签名身份和系统授权状态。分发检查仍缺 Hardened Runtime、可信时间戳、公证、staple 和干净 macOS 26/27 首装。旧 `365fdc4` ZIP 作为回退保留在同一内部草稿。[候选与回退 ZIP](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-0d613209d89c24e3816f) · [包哈希](candidate.json) · [签名连续性](installation.json) · [正式权限](live.json) · [包内逐件检查](package-gate.json)
