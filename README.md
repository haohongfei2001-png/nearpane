# Nearpane

Nearpane 是可自由组合的 macOS 桌面伴随式工作台：在同一应用中使用语音、截图、歌词、空间调度及其他工具。官网：[nearpane.com](https://nearpane.com)。

**唯一产品开发主线：`main`。** 本分支保存最新集成产品；不是对正式发行资格的承诺。产品规格只以 [PRODUCT_CONSTITUTION.md](PRODUCT_CONSTITUTION.md) 为准，开发遵守 [AGENTS.md](AGENTS.md)。

## 当前开发与验收

| 范围 | 当前入口 |
| --- | --- |
| 统一主窗口、模块、仓库、设置与动态侧栏 | [设计](docs/design/2026-11-28-unified-workbench.md) · [设置](docs/design/2026-11-28-settings-convergence.md) · [原生 UI 验收](docs/verification/unified-workbench/8c884573/README.md) |
| Spaces 独立真实窗口调度 | [PR #16（唯一在研产品 PR）](https://github.com/haohongfei2001-png/nearpane/pull/16) · [现行技术路线](engineering/research/NEARPANE-INDEPENDENT-STAGE-DECISION.md) · [工程证据](engineering/verification/independent-stage/README.md) |
| 全屏临时工具工作台 | [设计与实现范围](docs/design/2026-11-28-fullscreen-workspace.md) |
| 既有 LyricTile 独立发行 | [已发布 build 49](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)；原更新通道仅为兼容保留，不是产品主线 |

PR #18 已合并。其源代码在 `8c88457332cf55633d071b2992932a1971ded321` 通过 986 个源码测试及 53 项原生 UI 检查；真实播放器、连续 Spaces 调度、四边布局、模块按需下载安装、独立窗口避让及发行链仍须按当前实现和证据验收。不要将原候选包或旧 Alpha 安装等同于当前主线的正式发行。

## 仓库导航

| 目录 | 内容 |
| --- | --- |
| `Sources/`、`Products/LyricTile/Sources/` | 当前宿主、内置模块与共享歌词领域（一个集成产品，不是第二个开发主线） |
| `Engine/` | 原生窗口调度引擎 |
| `Tests/`、`Resources/`、`Dependencies/` | 测试、产品资源、上游共享组件锁 |
| `scripts/`、`.github/workflows/` | 构建、真实验收、CI 与发行工具 |
| `docs/`、`engineering/` | 当前设计、技术、证据入口；历史资料由[历史索引](docs/repository-history.md)指引 |
| `website/` | 唯一官网源码（GitHub Pages 从 main 发布） |

## 构建

macOS 26+、Swift 工具链、Python 3。首次全量构建按 [依赖锁](Dependencies/README.md)获取共享组件；校验缓存后可使用 `NEARPANE_OFFLINE=1`。

```sh
scripts/test.sh
scripts/build-app.sh debug
scripts/build-app.sh release
scripts/verify-standalone.sh
```

真实窗口专项入口：

```sh
python3 -B scripts/acceptance/independent-stage/run.py /private/tmp/nearpane-independent-01 --scope all --iterations 3
```

[专项验收说明](scripts/acceptance/independent-stage/README.md)。构建不替换日常安装、不发布安装包；候选构建与正式签名发行分别记录。

## 开发方式

每项新工作从最新 `main` 建立一个短期 `feature/<功能>` 或 `fix/<问题>` 分支；PR 直接指向 main。完成验收后合并，删除功能分支。不得建立永久 develop、每版本分支、按 AI 工具或日期分裂的主线。正式发布使用不可变 Git tag 和 GitHub Release。当前例外和历史回查见[仓库治理与历史索引](docs/repository-history.md)。
