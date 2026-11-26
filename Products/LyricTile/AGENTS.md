# LyricTile 工作入口

这是 HOLDSNOW 的独立 macOS 软件，放在 Nearpane 仓库中维护。工作范围是本目录及专用 `.github/workflows/lyrictile.yml`；独立 app 不依赖 Nearpane 进程。

## 继续之前

1. 首先读简短的 `STATUS.md`，确认当前实际代码、已测 SHA 与下一步；仅按需读取 `README.md`、`Documentation/IMPLEMENTATION_STATE.md` 和 `Documentation/ARCHITECTURE.md` 的相关章节。
2. 本机继续按 `Documentation/LOCAL_ONLY_HANDOFF.md` 执行。设计、生产模块、解析器、构建和签名公证脚本已经存在；从具体实测缺陷继续。
3. `Research/2026-11-26` 是保留校验值的历史设计/审计快照。实现 ADR 优先于快照中已经改变的未来计划；更新当前文档，不重写历史证据。

## 实施约束

- 使用真实播放器字段、明确的 capability 与真实读回。没有源进度时保持不可同步，不添加演示播放路径或默认通过的时钟资格文件。
- 保留播放器/录音 generation 的异步结果检查、单会话内核锁，以及 TileKit 撤回/确认/显示屏障。
- 真正的显示或移动仍需当前 registry 授权；稳定不动的窗口可以避免重复工作。
- 原创测试输入只在 `Tests` 中使用；设计样句只在已标注的研究原型中展示。
- 对源码变动运行必要的原生编译与现有风险测试。准确区分 fixture、真实 UI/helper、实际播放器、独立时间参考与最终签名包证据。
- 采用低上下文增量开发：禁止检索此前 ChatGPT 对话、整仓/完整 PR 差异/完整测试日志；按模块读取、过滤输出，每个有效单元提交并覆盖更新简短的 `STATUS.md`，不累积历史日志。
- 代码许可、歌词内容使用依据和实际签名配置分别记录。凭据与原始私人播放轨迹留在本机；仓库保存脱敏结果、版本和哈希。

发布支持范围以具体播放器/OS/build 的通过记录为准。现成的四个适配器、CI 绿色或 ad-hoc 签名完整性均不能代替这些实测。

