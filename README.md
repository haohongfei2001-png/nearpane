# Nearpane

当前工程为原生 macOS 常驻侧栏的增量实现，已接入 Saytile 连续文字和 Riftlet 截图托盘；完整产品则以本仓库最新权威定义的 Native/Virtual、持久 WorkRect 和按需呈现为目标。当前工程已通过部分集成及只读桌面验收；真实 Space 动作、八窗平铺、跨空间拖拽、全屏行为尚未通过实机验收。

| 模块 | 当前行为 |
| --- | --- |
| Saytile | 在同一进程使用上游音频控制器、文字修订和编辑草稿库。单控件区分暂停、待命和说话；复制只在点击时发生。默认关闭云端，不读取独立应用的凭据或历史。点击收音前不打开设备。 |
| Riftlet | 在设置中明确连接已有资料库；复用原队列、媒体、锁和回执，不创建替代队列。原应用占用、库缺失或版本不兼容时拒绝连接。截图入口、两列缩略图、展开/补位和附加都属于同一托盘。目录收录与外部草稿授权独立；不自动发送。|
| Spaces | 普通界面保留空间区并标记归属未知。设置中的合成诊断不进入生产事件流，不会切换 Space、移动或激活窗口。其他内置可选模块仍是明确标示的样例。 |

侧栏以屏幕宽度的 1/8 贴合可用边缘；语音与截图合计占可用高度的 3/8，其余 5/8 留给空间区。菜单栏提供显示、隐藏、设置和退出。Host 配置、摆放与隐藏意图单独保存。语音内容留在 Nearpane 的 Voice 领域库；截图和未确认的附加操作留在已有的 Riftlet 资料库。退出或停用不会删除领域数据，也不会把权限写进 Host 配置。

## 当前正式产品权威（2026-11-09）
本工程分支使用本仓库内的 **[PRODUCT_DEFINITION.md](PRODUCT_DEFINITION.md)**、**[视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md)** 与 **[交互规范](design/INTERACTION-SPEC.md)** 作为产品实施依据。细化决策见 [ADR-010](decisions/ADR-010-DUAL-WORKSPACE-MODES.md)、[ADR-011](decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md)、[ADR-012](decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md)、**[ADR-013](decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md)**。相互冲突时以用户更新、更具体的 **ADR-013** 为准；旧原型、旧测试和早期文档仅保留历史参考地位。

最新不可忽略的行为：**非原生全屏持续保留约 1/8 侧边工作区域，即使 Nearpane UI 隐藏也不释放**；窗口通过拖动**具体窗口缩略图**到目标 Space 加入，**单击空间行仅切换整个空间**；默认 1—8 窗渐进无重叠平铺（第三窗：旧两窗右侧上下，新窗左侧半区；第五窗：旧两窗各占 1/8、新窗独占 1/4），第九窗拒绝；用户可改变槽位和比例；Nearpane 显示哪些模块随工作现场变化，但不因此重排普通窗口。只有**真实原生全屏**可以占满整屏，录音等浮层由用户主动唤出、原位置优先。双空间模式为低频设置，主屏唯一 Saytile/Riftlet、副屏空间调度独立配置，全部尺寸提供设定好的默认值并允许在设置中精调。Nearpane 是一款整体产品。

**实现与权威分开：** 下述运行状态、P4.0/P4.1 证据描述的是目前代码，不能当作以上新行为已实现。旧 P4 逐窗点击/窗口重叠用例只证明底层识别或几何能力，**不得作为最终产品交互的通过标准**；真正的跨 Space 拖动、窗口移动/平铺、全屏恢复与权限仍需专门验收。生产 `main` 未因本次文档同步改变。

## 本地构建与测试

整合包要求 macOS 26+、Swift 工具链和 Python 3。验证环境为 Apple Silicon、macOS 27.0、Swift 6.4 和 Command Line Tools。单独检出 Nearpane 后直接运行下列脚本，首次全量构建会自动从 GitHub 获取两个固定提交的选定文件。此后的构建可用 `NEARPANE_OFFLINE=1` 从校验过的缓存运行。[依赖锁、来源、许可证与升级方法](Dependencies/README.md)

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

集成开发包生成在 `build/debug/Nearpane.app` 和 `build/release/Nearpane.app`。打包过程检查可执行文件签名、plist 与资源字节，并通过成品程序的 `--verify-bundled-resources` 调用两个领域原有的资源读取器。这条路径在创建 NSApplication 之前返回，不打开窗口、资料库或连接。开发包未经分发签名或公证；构建不安装或替换应用。

测试采用 Swift Testing。开发包同样使用 SwiftPM 的 native 引擎，避免 File Provider 元数据导致资源包在增量构建中重签失败。该引擎在 Swift 6.4 中有弃用警告。迁移到后续工具链时需复核。全部原始日志、临时库和构建缓存均在忽略目录。

[P3.6 工程准入、现场操作与权限](engineering/verification/P3.6-preflight-closeout.md) · [P3.5 工程收据与运行边界](engineering/verification/P3.5-closeout.md) · [P3.5 验收准备记录](engineering/verification/P3.5-native-acceptance.md)

[完整验收与待验证项](engineering/verification/D-acceptance.md) · [A：Host](engineering/verification/A-host-closeout.md) · [B：Saytile](engineering/verification/B-saytile.md) · [C：Riftlet](engineering/verification/C-riftlet.md) · [阶段文件清单](engineering/verification/changes.txt)

[产品定义](PRODUCT_DEFINITION.md) · [视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md) · [P1 技术门禁](docs/reviews/P1-TECHNICAL-GATE-REVIEW.md) · [历史 P2 基线](engineering/P2-HOST-FOUNDATION.md)
