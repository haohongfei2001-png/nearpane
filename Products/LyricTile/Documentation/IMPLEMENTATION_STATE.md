# LyricTile · 当前实现与验证状态

**后续开发统一从 [STATUS.md](../STATUS.md) 续接。** 本文的 65 项测试、源码 `75d9e60cb8a0` 与资源数值是早期候选基线；更新后的源码验证单独记录，不能把本页旧结果算作新提交通过。

**工程候选已实现、可独立构建和运行。** 产品位于 `Products/LyricTile`，分支为 `codex/lyrictile-standalone-20261126`，[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。本轮变更仅涉及独立产品目录与新增 LyricTile workflow；基础 Nearpane native 提交是 `6ac5eb63c97b7597e662770bac485be61f571bb8`。

**早期已测源码：[`75d9e60cb8a0`](https://github.com/haohongfei2001-png/nearpane/commit/75d9e60cb8a0eced93ed1c01f99ee109c315a7fe)。** [macOS CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45750660678) · [早期候选安装包与日志](https://github.com/haohongfei2001-png/nearpane/actions/runs/45750660678/artifacts/15085886100) · [保存到仓库的实际证据](Verification/2026-11-26/README.md)。最新源码与候选入口见 STATUS；不同候选用各自源码 SHA 和包 SHA256 标识。

## 已完成的生产实现

| 范围 | 实际交付 |
|---|---|
| 产品与设计 | 54 份研究/设计文件；三种高保真方向、雾白词页定稿、图标 SVG 母版、可交互 HTML、视觉/决策 PDF、动效与多语言/状态/桌面组合规范 |
| 媒体 | Apple Music、Spotify 的 PID 定向 ScriptingBridge；QQ/网易的隔离 BSD MediaRemote helper；真实源身份、能力、时间锚点、一次派发及读回 |
| 歌词 | LRC/enhanced LRC/LRCX、限定 Apple/AMLL TTML、严格 Lyricsfile、解码后 QRC/YRC、纯文本；版本匹配、候选选择、绑定、偏移、缓存与真实 LRCLIB 请求 |
| 时间与渲染 | 单调时钟投影；暂停/恢复/切歌/seek 身份保护；CoreText 字形与词遮罩；未知/过期时间停止同步；逐字必须具备真实词时码和精度证据 |
| 独立界面 | 固定窄词页、hover 封面/播控/seek、独立状态、欢迎/设置/导入/校准/来源/完整歌词窗口、菜单栏、按需权限引导 |
| 桌面 | TileKit 几何与跨进程占位、撤回/确认/提交屏障、生命周期锁；旧 Saytile/Riftlet 只读窗口避让 |
| Nearpane | `NearpaneLyricsModule` 直接提供原生 View 与同一服务层，带显式单会话交接；独立 app 不依赖 Nearpane 启动 |
| 工程交付 | 精确依赖锁、helper 源码构建、App/ZIP/DMG、图标生成、实际 bundle 验证、签名/公证/appcast 脚本、显式本地诊断和资源采样 |

应用运行时没有预设歌曲、假歌词或自造播放进度。原创样词只用于清楚标注的设计稿和测试输入。首版远程歌词源为 **LRCLIB**；本地绑定/缓存/导入可回退。格式回退不是多家网络 provider，自动 AMLL/QQ/网易歌词接口不属于本版已实现范围。

## 已经实际验证

主机是 **macOS 27.0.1（26A434）/ Xcode 27.1（27A9275）/ Swift 6.4 / arm64**，不是用户的 macOS 27.0 M5。完整原始环境输出见 [host.txt](Verification/2026-11-26/host.txt)。

| 检查 | 实际结论 |
|---|---|
| 生产 App 与 Host facade 编译 | PASS |
| 原创风险测试 | **65 个通过，零失败、零跳过**：XCTest 10 + Swift Testing 55 |
| Release App、helper、Sparkle、ZIP、DMG | 构建成功；arm64、rpath、权限声明及 ad-hoc 签名完整性 PASS |
| 三个生产原生界面及退出 | 空态、欢迎、设置加载与内容捕获成功；正常退出码 0；截图已人工检查 |
| 真正 MediaRemote helper 装载 | PASS：真实 get 返回空会话 `null`，17 个私有符号存在；只认证装载与只读协议 |
| 正常 app 空闲样本 | CPU **0.2330% 单核**；RSS 中位/峰值 **61.61 / 61.62 MiB**；本次 hosted idle 样本达到预算 |
| 四个实际播放器与 TCC | NOT_RUN；不能由单元测试或空媒体 get 推导 |
| 独立时钟精度、逐行/逐字/8 小时资源 | NOT_RUN |
| 用户双屏、Spaces/全屏、真实材质与跨 App 交接 | NOT_RUN |
| Developer ID、公证、正式更新升级 | NOT_RUN；目前是 ad-hoc 工程候选 |

**CI 工作流成功不等于全部发行验收通过。** 资源脚本保存真实数值和 `withinTargets`，超预算不会改成 PASS；签名完整性与 notarization 是不同检查。空闲预算是 CPU ≤0.3% 单核、RSS 中位 ≤120MiB/峰值 ≤180MiB。最终正式支持清单必须由确切播放器/OS 版本的实测决定。

## 首个正式版本的边界与验收

1. 独立伴随已有播放器，默认歌词主体，hover 同框保留当前歌词；不扩展播放器、歌单、推荐、社区或账号系统。
2. 四个适配器进入实施范围。Apple Music/Spotify 是首发完整闭环目标；QQ/网易按真实系统源与命令能力发布可用子集，暂停 QQ seek 保持禁用。当前没有伪造任何播放器通过记录。
3. 健康但未经独立精度测量的真实时间锚点可以逐行同步；缺失/过期位置保持静态。真实 token 时码加匹配精度资格才启用连续逐字扫光；本包没有默认“全平台通过”的资格文件。
4. 旧组件没有被自动改造成 TileKit 协议参与者：当前只读避让；完整跨产品协商需各产品接入小型协议。未来 Nearpane 直接嵌入核心模块，不把多个独立浮窗拼成主产品。
5. 发行路线为持有者配置的 Developer ID 直接分发。候选未配置正式更新 feed/公钥时明确显示渠道未连接；歌词内容使用依据与代码许可分别核对。

完整真实用例在 [MACOS27_ACCEPTANCE.md](../Research/2026-11-26/docs/MACOS27_ACCEPTANCE.md)。本机执行只按 [LOCAL_ONLY_HANDOFF.md](LOCAL_ONLY_HANDOFF.md)，不用重新设计、重写解析器或重建工程。

## 实现优先级与证据沿革

实现 ADR 位于 [ARCHITECTURE.md](ARCHITECTURE.md)：真实源健康与独立精度分离、简单有界存储、优化级别不代替授权、旧组件兼容、真实更新配置、当前解析器来源、首个网络 provider。它们覆盖历史研究中后来被细化的计划；研究快照原样保留。

| 提交 / CI | 可复核的阶段结果 |
|---|---|
| `7211d2ab3e6b` | 54 份设计/研究与实施协作契约入库 |
| `189e096b73de` / [CI4](https://github.com/haohongfei2001-png/nearpane/actions/runs/45744887973) | 完整生产 App 与 Host facade 首次编译通过；随后修正 Testing 宏使用与真实 Optional.none 分支歧义 |
| `5a53aac3b2e1` / [CI5](https://github.com/haohongfei2001-png/nearpane/actions/runs/45745479008) | 57 tests 与实际打包通过；空态图捕获，正常退出超时没有记 PASS；随后修正 AppKit 退出调度 |
| `6f7b73c88805` / [CI6](https://github.com/haohongfei2001-png/nearpane/actions/runs/45746365429) | 全流程成功、59 tests、真实 helper 装载；空闲61s约0.3103%单核/60.89MiB，CPU未达目标 |
| `b14f8c3ac65f` / [CI7](https://github.com/haohongfei2001-png/nearpane/actions/runs/45747785088) | 62 tests；宽泛进程路径检查跳过 idle，因此不计性能通过；改为 NSWorkspace 精确 bundle ID |
| `c0bde5461cd9` / [CI8](https://github.com/haohongfei2001-png/nearpane/actions/runs/45749377185) | 65 tests、三个生产界面与 helper 通过；120s空闲0.4737%单核/61.5MiB，CPU未达目标；移除确定的只读序列化与重复授权工作 |
| `75d9e60cb8a0` / [最终记录](https://github.com/haohongfei2001-png/nearpane/actions/runs/45750660678) | 本文当前结果；若源代码再改动，必须标识后续实际验证提交 |

此前资源结果及 NOT_RUN 原样保存于 Verification。它们来自不同 hosted 执行，不据此声称某次代码修改带来确定百分比的性能提升。

