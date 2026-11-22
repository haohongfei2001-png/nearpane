# Nearpane 内嵌工具

截图托盘和语音模块随 Nearpane 一起构建。在设置的版本信息中可以看到两个内嵌引擎的上游版本、构建号、渠道和源码提交。构建、设置和验收共用 [domains.lock.json](domains.lock.json)。安装独立应用不会改变 Nearpane 已打包的引擎。

| 工具 | 本次接入 | 在 Nearpane 中的行为 |
| --- | --- | --- |
| Riftlet | [1.0.7（53）开发源码](https://github.com/haohongfei2001-png/Riftlet/tree/b20cefbf94e78ed89643cc27fa95af91bd140960) · [上游 PR #122](https://github.com/haohongfei2001-png/Riftlet/pull/122) | Chrome 和 Edge 的 ChatGPT 草稿使用按下瞬间的窗口、标签页、文档和编辑框。原附件的失败可独立回读。新增九个站点配置只识别草稿附件入口，截图继续保留在托盘。 |
| Saytile | [0.20（533）内测源码](https://github.com/haohongfei2001-png/saytile/tree/7c0df4728b113c17297a0cded20472de4ffc3337) · [上游 PR #49](https://github.com/haohongfei2001-png/saytile/pull/49) | 收音、识别、文字修订和手动插入使用同一提交。重开资料时先核对本地音频日志，恢复已落盘的录音帧。Nearpane 默认使用 Apple 本机识别，麦克风由用户启动，资料和凭据各归当前 Nearpane 配置。 |

2026-11-23 核对了两个仓库的 GitHub Releases。Riftlet 的最新正式版为 1.0.5（31），锁定的开发提交包含该版源码。Saytile 当日只有预发布，其中最近发布的是 0.18（492）内测。包内 `source.json` 分别记录编译来源 `upstreamBuild` 和最近正式发布 `latestStableRelease`，后者为 `null` 表示核对时没有正式发布。[Riftlet 正式版](https://github.com/haohongfei2001-png/Riftlet/releases/tag/v1.0.5) · [Saytile Releases](https://github.com/haohongfei2001-png/saytile/releases)

独立 Saytile 的 iCloud、iPhone 与记住待命涉及独立账户、权限或启动策略。Nearpane 的上游版本号说明编译进包的组件；端到端验收范围见[工具验证收据](../engineering/verification/embedded-tools/5.22-90/verification.json)。

## 构建与核对

`bash scripts/test.sh` 和 `bash scripts/build-app.sh debug` 从固定 GitHub 提交取用领域文件。首次取源需要网络，缓存完整后可使用 `NEARPANE_OFFLINE=1`。基础 Host 可用 `NEARPANE_FOUNDATION_ONLY=1` 在空的领域缓存中构建。

锁文件记录来源仓库、完整提交、逐文件 SHA-256、资源范围、原始声明和上游构建信息。解析器核对提交归档和文件类型，重新验证命中的缓存，并原子写入新缓存。打包逐个核对上游资源的相对路径和实际字节。成品的 `Contents/Resources/Upstream/{saytile,riftlet}/source.json` 保存同一来源收据和适配补丁的指纹。

Nearpane 保留两处经过摘要校验的宿主适配。[语音收音补丁](saytile-capture-readiness.patch) 在首个真实 PCM 缓冲后进入待命，关闭时排空已接收音频。[截图适配补丁](riftlet-draft-witness.patch) 让原生点击和 Nearpane 共用一个凭据，并将新增站点的只读检查绑定到原窗口和标签。SwiftPM 编译派生副本，缓存中的上游原件可单独复核。

## 更新流程

1. 核对上游发布、最新产品 PR 和实际产品源码。分别记录产品版本、构建号、渠道以及经过验证的完整提交。如果 PR 尾部只更新证据，比较所选产品提交与 PR HEAD 的源码和资源。
2. 对每个变更的领域运行 `python3 scripts/prepare-domains.py --propose <riftlet或saytile> <40位提交> <新的候选锁文件>`。对照 Git blob 审查源文件、资源、许可证、资料格式和宿主适配。更新锁文件的 `upstreamBuild` 和适配摘要。
3. 运行 `python3 -B scripts/test-dependencies.py`、`bash scripts/test.sh` 和 `bash scripts/build-app.sh debug`。核对旧资料重开、语音与截图主入口及包内来源，在同一 PR 保存验证收据。
4. 截图使用 `python3 -B scripts/acceptance/run-local-adapter.py --product --browser chrome` 或 `--browser edge` 做隔离页面验收。登录服务、系统 Apple Events 和物理麦克风分别记录实测结果。回退时一并还原源码、锁和桥接补丁，对新格式资料使用先前保存的独立配置或副本。

Saytile 和 Riftlet 的原始第三方声明随包保留。可选识别模型仅包含清单，模型权重仍由其单独的分发与许可条件约束。
