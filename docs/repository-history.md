# 仓库治理与历史索引

唯一主线为 `main`。当前开发入口以 [README](../README.md) 和 [产品宪章](../PRODUCT_CONSTITUTION.md) 为准。

## 保留的工作线

| 分支 | 理由 |
| --- | --- |
| `main` | 唯一永久产品主线 |
| `pro/independent-stage-engine-20261126` | [PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16)；继续既有 Spaces 实机闭环，PR 已改为 main |
| `creative/nearpane-first-film-v2-20261128` | 最新宣传片制作，第二播放器采集的 15 个文件已经合入；成片与大型素材包保持原交付位置 |
| `codex/lyrictile-standalone-20261126` | 仅维护已发布 build 49 的 Sparkle 更新源，迁移前不能删除；不允许在此发展 Nearpane 产品 |

## 历史与恢复

- [统一归档锚点 3b2ae003](https://github.com/haohongfei2001-png/nearpane/tree/3b2ae003286b9a787a852d2a5f6bc674a6bb4649)（包含 28 条旧分支原始 SHA 与处理理由；其 29 个父提交保全主线旧快照及旧分支独有历史，不向 main 合并旧代码）。
- 归档标签：`archive/pre-consolidation-20261128`。只用于历史恢复，不是产品版本。
- [清理前完整主线快照](https://github.com/haohongfei2001-png/nearpane/tree/ff33373b16abfa98acc3c01844b5ee0e8cfb5a5f)：旧设计原型、已归档规范与所有历史验收证据均可从该快照回查。旧产品定义不具有现行权威。
- 旧 PR #7、#8、#9、#10、#11、#13、#14、#15 已关闭（没有冒充合并或验收）；已发布独立 LyricTile 的 PR #17 已关闭，原发行源及兼容通道保留。
- 后续需要历史中未合入的语音模型、截图附加、文件/本地工具、预览或视觉成果时，从最新 main 开新任务，仅选择仍符合宪章的必要增量并重新验收。不得把历史分支整个恢复成产品版本。

## 恢复旧资料

从归档锚点的 `branches.json` 取原分支 tip SHA。用 GitHub 固定 commit URL 查看文件，或者本地 `git show <sha>:<path>`；需要复用时从 main 开临时分支。历史资料不在主线工作目录重复堆叠。

## 清理结果（2026-11-28）

- [实际归档与删除流水线](https://github.com/haohongfei2001-png/nearpane/actions/runs/46125537383) 已通过；28 条历史分支引用删除，归档标签经回读指向 `3b2ae003286b9a787a852d2a5f6bc674a6bb4649`。32 条分支收敛为 4 条；10 个开放 PR 收敛为 PR #16 一个。
- [历史验收依赖审计](https://github.com/haohongfei2001-png/nearpane/actions/runs/46125626421) 发现现行验收脚本仍读取 5.22 原始数据及部分 window-engine 记录，继续保留这些依赖和当前独立 Spaces、统一工作台证据，不把历史证据删除等同于测试成功。
- 已从当前工作树移除 20 份废弃原型/历史副本以及 143 份旧 5.21 原始收据；[旧 5.21 验收目录](https://github.com/haohongfei2001-png/nearpane/tree/ff33373b16abfa98acc3c01844b5ee0e8cfb5a5f/engineering/verification/native-spaces) 全部保留于固定历史快照。文档历史链接改指固定提交。
- 一次性分支归档、依赖审计工作流完成后移除；正常合并后的清理由 `.github/workflows/cleanup-merged-feature-branch.yml` 自动处理短期 feature/fix 分支及 Spaces 旧命名分支，且只删除精确匹配的已合并 head。
