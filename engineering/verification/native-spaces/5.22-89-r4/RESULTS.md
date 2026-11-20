# Nearpane 5.22（89）原生 R4 实机记录

2026-11-20，macOS 27.0（26A428），Apple Silicon。正式安装包读回了同屏全部 4 个真实 Space 的身份和当前选中项。正式安装进程对指定窗口的精确键盘聚焦、切换和迁移均为 0 次确认。录音转写、文件双向拖放、材质校准、三种宽度及计算取消取得独立实测结果。[机器可读收据](verification.json)

## 候选来源

| 项目 | 冻结版本 |
| --- | --- |
| 原生基线 | `implementation/host-foundation-20261109` 的 `c5e0533` 及开放 PR #14 的 `629524b`，包含 build 86 窗口修复和随后的安装签名修复。[PR #14](https://github.com/haohongfei2001-png/nearpane/pull/14) |
| 设计基线 | PR #13 的 `fa7a0bf`，沿用 R4 文档、tokens 和 18 页图册。[README](https://github.com/haohongfei2001-png/nearpane/blob/fa7a0bf34e292db8d1e017056af795c1598725eb/docs/design/visual-reference-20261118/README.md) · [SPEC](https://github.com/haohongfei2001-png/nearpane/blob/fa7a0bf34e292db8d1e017056af795c1598725eb/docs/design/visual-reference-20261118/SPEC.md) · [HANDOFF](https://github.com/haohongfei2001-png/nearpane/blob/fa7a0bf34e292db8d1e017056af795c1598725eb/docs/design/visual-reference-20261118/HANDOFF.md) |
| 实施提交 | `4960465` 接回正式入口，`07b8031` 加入逐窗生命周期及显式组合，`692e614` 完成玻璃实机校准。[候选源码](https://github.com/haohongfei2001-png/nearpane/tree/692e6145a45b90c21de247946ebca828bd9662ee) |
| 安装包 | `Nearpane-5.22-89-macOS-arm64.zip`，SHA-256 `3bc6f3bb17bc477121be227b3f240c811f1f517fbe85844a7c384d2f8e962abb`。GitHub 下载后在普通临时目录解包，严格深度验签通过，247 个文件系统条目、符号链接与文件内容均与 `/Applications/Nearpane.app` 相同。Developer ID 团队 `ZB9D4T66QB`，应用 ID `com.holdsnow.nearpane.alpha`。[ZIP 核验](package.json) |

## 正式安装版的系统结果

单屏 1470 × 956 pt，2×，台前调度开启，独立 Spaces 关闭，SIP 开启。日常配置重新启动后，进程和磁盘签名身份一致。以下权限来自安装进程的当次读回。观察器拥有辅助功能及屏幕读取权限，可以独立辨认自建窗口并采集产品画面。

| 场景 | 结果 | 实机观察 |
| --- | --- | --- |
| 同屏目录与高亮 | 通过 | 3 个普通桌面、1 个全屏 Space，侧栏 4 行逐项匹配，当前 Space 只出现一次。独立滚动区 1 个。完整受控 A/B/C 库存场景仍待测。 |
| 本屏逐窗与 W01 精确键盘焦点 | 阻塞 | 对正式侧栏分别建立一窗、同应用双窗。安装 Host 的辅助功能及事件投递均为否，侧栏没有对应的唯一可点击窗口。发出操作 0，确认焦点 0，键盘标记 0。两次均恢复原桌面、前台与原键盘窗口，并清理测试窗。 |
| 独立窗口、组合及缩略图像素 | 阻塞 | 系统实际测得 540 × 213 与 240 × 383 pt 两扇窗口。正式侧栏显示 0 张对应卡。Host 录屏权限为否，逐窗像素比对次数为 0。图中绿色小窗由台前调度呈现。[受控桌面实拍](screens/controlled-desktop.png) |
| S02 普通空间切换、R01 快速连续选择 | 阻塞 | 签封动作助手就绪，`canSwitch=false`。本批没有新建且带有当次归属凭据的三个普通测试空间。准备及投递均为 0。 |
| D01 跨 Space 拖动迁窗 | 阻塞 | `canMove=false`，缺少可核对的目标测试空间。拖动输入与迁移动作均为 0。迁移后平铺也未取得实机确认。 |
| N01 隐藏采集 | 通过此子项 | 隐藏 60 秒，新增捕获请求 0，已恢复侧栏。样本来自没有录屏授权的 Host，常态占用与动画延迟仍待测。 |

具备授权的隔离调试控制器用同一版本的源代码和真实测试文档另做了两项诊断。逐窗预览识别出 4/4 个不同来源，关闭和撤下后剩余两张，结束时恢复前台。独立选窗按 A、B、A 三次确认了键盘与主窗口，但原前台恢复失败，该独立场景整体记为失败。正式安装版的确认数保持为 0。[隔离四窗](screens/isolated-four-window.png) · [隔离两窗](screens/isolated-two-window.png)

## 壁纸、玻璃与布局

在正式侧栏下方分别采集系统当时的桌面层和不激活的 Apple 壁纸测试窗。蓝黄对照按同一位置计算壁纸变化传入外壳及内容卡的程度。数值为 sRGB 输出的有效遮蔽率。系统浅、深色分别实测，结束后已恢复原浅色外观。系统壁纸设置保持原值。[浅色取样](light-optics.json) · [深色取样](dark-optics.json)

| 区域 | R4 浅色目标 | 浅色实测 | R4 深色目标 | 深色实测 |
| --- | ---: | ---: | ---: | ---: |
| 外壳 | .58 | .586 | .72 | .716 |
| 语音底板 | .88 | .880 | .94 | .938 |
| 托盘底板 | .88 | .880 | .94 | .940 |

推荐、窄、宽分别量得 240、184、368 pt，高度均为 923 pt。两工具、三工具与用户调序通过正式设置运行并恢复。前景另有未通过项，在同一蓝壁纸上调高玻璃透明度，build 89 的启动图标、相机/文件图标与权限说明笔画仍会透入部分背景色。本版仅确认上表的背景测量。[系统浅色](screens/system-light.png) · [系统深色](screens/system-dark.png) · [蓝壁纸](screens/blue-light.png) · [黄壁纸](screens/yellow-light.png) · [Sonoma](screens/sonoma-light.png) · [三工具](screens/three-tools.png) · [窄](screens/narrow.png) · [宽](screens/wide.png)

## 工具交互

| 功能 | 实机结果 |
| --- | --- |
| 文件托盘 | AppKit 拖入、拖出均成功，独立接收端的内容与原件逐字节相同。保存后 60.11 秒卡片退出，持久副本可读。两次拖动保持原前台，结束时仅清理本轮生成且内容匹配的测试文件。[收据](file-tray.json) |
| 语音 | 在从 `/Applications` 正常启动的同一签名应用中使用空白验收配置，通过侧栏开始及暂停。实际麦克风录下 12.6 秒，Apple 本地识别完成，暂停后仍有音频与最终中文转写。关键词及 7、5、12 均匹配，收音状态恢复暂停。公开收据仅保留计数与匹配结果。[收据](voice.json) · [启用态实拍](screens/voice-enabled.png) |
| 备忘计算 | 通过正式侧栏打开空白计算草稿，输入 `(7-2)*3/2` 得到 `7.5`，取消后原表达式仍在。验收清空该测试输入并恢复模块状态。 |
| 截图、原处翻译 | 本机 Host 无屏幕录制和辅助功能授权。未验证真实截图附加到第三方草稿，或第三方选区旁译文和单词本落盘。 |

全屏/Split View 下指定成员聚焦、自动创建及清理 Space、多屏、带授权的历史/实时图回退、完整应用兼容矩阵、动效/减少动态效果、长时间资源占用和升级公证均未取得本版的完整验收。自动建删普通桌面仍未接上正式产品路径。[验收合同](../../../native-spaces/ACCEPTANCE.md) · [专项 Issue #12](https://github.com/haohongfei2001-png/nearpane/issues/12)

## 回归

串行集成回归 515 项、76 组通过。基础配置 422 项、60 组通过。安装验收器防护用例 21 项、签名用例 6 项、依赖用例 8 项通过。较早候选并发运行时一项窗口管理时限用例曾超时，定向重跑及完整串行回归通过。玻璃测试的断言已按原生区域遮罩与校准后的分层值更新。
