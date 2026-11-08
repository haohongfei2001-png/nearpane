# Nearpane

原生 macOS 常驻侧栏。一个非激活的 AppKit 面板承载 Saytile 连续文字、Riftlet 截图托盘和预留的 Spaces 区域。当前工程已通过离线集成验收；真实桌面、麦克风、浏览器草稿和云端服务未做现场验收。

| 模块 | 当前行为 |
| --- | --- |
| Saytile | 在同一进程使用上游音频控制器、文字修订和编辑草稿库。单控件区分暂停、待命和说话；复制只在点击时发生。默认关闭云端，不读取独立应用的凭据或历史。点击收音前不打开设备。 |
| Riftlet | 在设置中明确连接已有资料库；复用原队列、媒体、锁和回执，不创建替代队列。原应用占用、库缺失或版本不兼容时拒绝连接。截图入口、两列缩略图、展开/补位和附加都属于同一托盘。目录收录与外部草稿授权独立；不自动发送。|
| Spaces | 普通界面保留空间区并标记归属未知。设置中的合成诊断不进入生产事件流，不会切换 Space、移动或激活窗口。其他内置可选模块仍是明确标示的样例。 |

侧栏以屏幕宽度的 1/8 贴合可用边缘；语音与截图合计占可用高度的 3/8，其余 5/8 留给空间区。菜单栏提供显示、隐藏、设置和退出。Host 配置、摆放与隐藏意图单独保存。语音内容留在 Nearpane 的 Voice 领域库；截图和未确认的附加操作留在已有的 Riftlet 资料库。退出或停用不会删除领域数据，也不会把权限写进 Host 配置。

## 本地构建与测试

整合包要求 macOS 26+（SaytileKit 的系统下限）。记录环境为 Apple Silicon、macOS 27.0、Swift 6.4 和 Command Line Tools。其他系统版本和 Intel 未实机验证。构建脚本只从相邻的既有 `saytile` 与 `Riftlet` 仓库读取固定提交的指定源码，并在当前仓库的忽略缓存中逐文件校验 Git blob；不克隆、切换分支或访问网络。固定版本与来源见各阶段收据。

```sh
scripts/test.sh
scripts/build-app.sh debug
scripts/build-app.sh release
# 可选：同时在 build/verification/hidden/ 保存隐藏窗口合成图
NEARPANE_RENDER_FIXTURES=1 scripts/test.sh
# 原 Host 独立构建（部署下限 14，不含两个领域模块）
NEARPANE_FOUNDATION_ONLY=1 scripts/build-app.sh debug
```

集成开发包生成在 `build/debug/Nearpane.app` 和 `build/release/Nearpane.app`。打包过程检查可执行文件签名、plist 与资源字节，并通过成品程序的 `--verify-bundled-resources` 调用两个领域原有的资源读取器。这条路径在创建 NSApplication 之前返回，不打开窗口、资料库或连接。开发包未经分发签名或公证；构建不安装或替换应用。

测试采用 Swift Testing。当前 CLT 的测试签名和宏发现需要 SwiftPM 的 native 测试引擎；该引擎的弃用警告及已知工具链警告保留在本地日志。临时库、构建缓存、原始日志和渲染图均不提交。

[完整验收与待验证项](engineering/verification/D-acceptance.md) · [A：Host](engineering/verification/A-host-closeout.md) · [B：Saytile](engineering/verification/B-saytile.md) · [C：Riftlet](engineering/verification/C-riftlet.md) · [阶段文件清单](engineering/verification/changes.txt)

[产品定义](PRODUCT_DEFINITION.md) · [视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md) · [P1 技术门禁](docs/reviews/P1-TECHNICAL-GATE-REVIEW.md) · [历史 P2 基线](engineering/P2-HOST-FOUNDATION.md)
