# Nearpane

日常使用从 Finder 的「应用程序」打开 Nearpane。菜单栏的「打开 Nearpane」集中提供语音档案、截图档案和设置。本机统一安装位置为 `/Applications/Nearpane.app`。[个人 Alpha 使用帮助](docs/ALPHA-HELP.md)

在同一个原生工程中开发 Host、Saytile 文字流、Riftlet 截图托盘和本屏窗口侧栏。当前安装的版本、对应源码和实机验收结果统一记录在[产品完成状态](engineering/verification/PRODUCT_COMPLETION_STATE.md)。原生窗口专项的当前范围与历史工作包见[专项状态](engineering/native-spaces/STATUS.md)。

| 模块 | 当前行为 |
| --- | --- |
| Saytile | 在同一进程使用上游音频控制器、文字修订和编辑草稿库。单控件区分暂停、待命和说话；复制只在点击时发生。默认关闭云端，不读取独立应用的凭据或历史。点击收音前不打开设备。 |
| Riftlet | 在设置中明确连接已有资料库；复用原队列、媒体、锁和回执，不创建替代队列。原应用占用、库缺失或版本不兼容时拒绝连接。截图入口、两列缩略图、展开/补位和附加都属于同一托盘。目录收录与外部草稿授权独立；不自动发送。|
| 本屏窗口 | 列出当前屏幕、当前桌面的窗口，紧接工具区向下排列，各窗按真实尺寸共用缩尺。实际窗口画面需要录屏权限，精确选窗另需系统提供可核对的窗口与焦点。桌面列表和跨桌面拖放已从这里撤出。 |

侧栏以屏幕宽度的 1/8 贴合可用边缘；语音与截图合计占可用高度的 3/8，其余 5/8 留给空间区。菜单栏提供显示、隐藏、设置和退出。Host 配置、摆放与隐藏意图单独保存。语音内容留在 Nearpane 的 Voice 领域库；截图和未确认的附加操作留在已有的 Riftlet 资料库。退出或停用不会删除领域数据，也不会把权限写进 Host 配置。

## 产品定义与实施依据

本工程分支使用本仓库内的 **[PRODUCT_DEFINITION.md](PRODUCT_DEFINITION.md)**、**[视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md)** 与 **[交互规范](design/INTERACTION-SPEC.md)** 作为产品实施依据。细化决策见 [ADR-010](decisions/ADR-010-DUAL-WORKSPACE-MODES.md)、[ADR-011](decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md)、[ADR-012](decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md)、**[ADR-013](decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md)**。原生空间专项有更新裁决时，以 **[2026-11-18 专项决定](engineering/native-spaces/DECISIONS.md)** 为准；未涉及的产品规则继续有效。旧原型、旧测试和早期阶段限制保留历史参考地位。

打开窗口列表和启用窗口自动管理是两个独立操作。Docked 的预留区沿用该屏的持久设置。自动平铺、八窗分流、历史比例和退出恢复的产品规则见 ADR-013。哪些规则已在安装版验证，请查阅[产品完成状态](engineering/verification/PRODUCT_COMPLETION_STATE.md)。

## 本地构建与测试

从源码构建完整应用需要 macOS 26+、Swift 工具链和 Python 3。已安装应用自带运行所需的组件。验证环境为 Apple Silicon、macOS 27.0、Swift 6.4 和 Command Line Tools。单独检出 Nearpane 后直接运行下列脚本，首次全量构建会自动从 GitHub 获取两个固定提交的选定文件。此后的构建可用 `NEARPANE_OFFLINE=1` 从校验过的缓存运行。[依赖锁、来源、许可证与升级方法](Dependencies/README.md)

```sh
scripts/test.sh
scripts/build-app.sh debug
scripts/build-app.sh release
# 从空缓存验证单仓库构建，保留独立日志及两个开发包
scripts/verify-standalone.sh
# 可选：同时在 build/verification/hidden/ 保存隐藏窗口合成图
NEARPANE_RENDER_FIXTURES=1 scripts/test.sh
# 原 Host 独立构建（部署下限 14，不含两个领域模块）
NEARPANE_FOUNDATION_ONLY=1 scripts/build-app.sh debug
```

集成开发包生成在 `build/debug/Nearpane.app` 和 `build/release/Nearpane.app`。独立 Host 开发包在 `build/foundation/` 下。更新日常安装请使用[本地 Alpha 交付流程](docs/ALPHA-RELEASE.md)。打包过程检查可执行文件签名、plist 与资源字节，并通过成品程序的 `--verify-bundled-resources` 调用两个领域原有的资源读取器。这条路径在创建 NSApplication 之前返回，不打开窗口、资料库或连接。开发包未经分发签名或公证；构建不安装或替换应用。

测试采用 Swift Testing。开发包同样使用 SwiftPM 的 native 引擎，避免 File Provider 元数据导致资源包在增量构建中重签失败。该引擎在 Swift 6.4 中有弃用警告。迁移到后续工具链时需复核。全部原始日志、临时库和构建缓存均在忽略目录。

[P3.6 工程准入、现场操作与权限](engineering/verification/P3.6-preflight-closeout.md) · [P3.5 工程收据与运行边界](engineering/verification/P3.5-closeout.md) · [P3.5 验收准备记录](engineering/verification/P3.5-native-acceptance.md)

[完整验收与待验证项](engineering/verification/D-acceptance.md) · [A：Host](engineering/verification/A-host-closeout.md) · [B：Saytile](engineering/verification/B-saytile.md) · [C：Riftlet](engineering/verification/C-riftlet.md) · [阶段文件清单](engineering/verification/changes.txt)

[产品定义](PRODUCT_DEFINITION.md) · [视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md) · [P1 技术门禁](docs/reviews/P1-TECHNICAL-GATE-REVIEW.md) · [历史 P2 基线](engineering/P2-HOST-FOUNDATION.md)
