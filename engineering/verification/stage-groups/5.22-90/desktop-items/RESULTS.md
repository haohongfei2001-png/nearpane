# 点击空白墙纸显示桌面文件

Nearpane 的「设置 → 本屏窗口 → 桌面文件和图标」提供「点击空白墙纸时显示」和「始终显示」。用户主动选择后，Host 读取并操作 macOS「显示项目」的「在桌面上」复选框。相同值直接返回，更改后须在同一控件上连续两次读到目标值。缺少现有辅助功能权限时，Nearpane 打开该系统面板并说明应勾选的项目。设置独立于窗口移开、小组件和台前调度。 [Apple 的桌面设置说明](https://support.apple.com/en-ie/guide/mac-help/mchl534ba392/27/mac/27)

| 环境 | 实际文件隐藏、显现、返回应用后隐藏 | 设置和测试文件清理 | 录像 |
| --- | --- | --- | --- |
| 托管 macOS 26，25G332 | PASS | PASS | PASS。[原始收据](44919772760/macos-26/desktop-items.json) · [录屏](44919772760/macos-26/desktop-items.mp4) |
| 托管 macOS 27，26A434 | PASS | PASS | UNKNOWN。ScreenCaptureKit 返回录制完成错误，已保留视频、四张独立采样及原始返回值。[原始收据](44919772760/macos-27/desktop-items.json) · [录屏](44919772760/macos-27/desktop-items.mp4) |
| 实体 Mac，macOS 27.0，26A428，SIP 开启 | 正式安装版 NOT_RUN | 日常安装与设置保留 | 离屏回归 745 项通过，3 项条件跳过。[Swift 收据](swift-regression.xml) · [开发包验签](development-build.json) |

两台托管 Mac 都在普通桌面创建了一份带双色图标的测试文件。点击已识别的普通窗口后两次采样均为零；点击空白墙纸后图标回到原位。Finder 把显现的图标报告为 `AXImage`。点击该应用的真实 Dock 图标后，窗口重新接收点击，桌面图标连续两次消失。两次试验都还原了原设置并删除了测试文件。同一用户的「点击墙纸移开窗口」、台前调度和小组件选项在操作前后读数一致。 [26A434 平时可见](44919772760/macos-27/desktop-items-baselineVisible.png) · [工作时隐藏](44919772760/macos-27/desktop-items-ordinaryWindowClickHidden.png) · [点击空白后显示](44919772760/macos-27/desktop-items-blankWallpaperRevealed.png) · [返回应用后隐藏](44919772760/macos-27/desktop-items-returnedToApplicationHidden.png)

macOS 26 将普通桌面复选框标为 `show-items`，同一行的 `desktop-items` 属于台前调度。macOS 27 的普通桌面标识为 `show-items-on-desktop`。隐藏期间 WindowManager 接收桌面层点击。此时可能没有 AX 元素，观察器用系统进程路径、屏幕范围、窗口层级和点击位置的实际窗号确认空白表面。显示期间再用 Finder 的 AX 命中区分背景与文件。

初次试验遇到控件识别阻塞和墙纸让渡失败。随后一次试验错误地选择了台前调度的复选框，虽然控件值发生变化，图标仍留在桌面。修复后又分别查明了隐藏期间的系统命中及返回窗口时的动画时序。首次 27 云端任务在装载 SwiftPM 夹具前终止。这些结果均保留在对应收据中。 [初次试验](44915679773/) · [Finder 背景回归](44916240148/) · [错误控件的录像与收据](44917089427/) · [隐藏时的系统命中](44917882664/) · [返回应用前的阻塞](44918555595/) · [首次 26 完整闭环与 27 夹具错误](44919159867/)

开发包源码为 `d7ce52d`，验收源码为 `e19808b`，两者产品源码相同。托管程序直接编译生产设置适配器和墙纸观察器，签名普通应用提供真实窗口。实体机验证了独立 arm64 开发包解压后的完整签名及内嵌资源。 [机器总表与文件哈希](verification.json) · [GitHub Actions](https://github.com/haohongfei2001-png/nearpane/actions/runs/44919772760)
