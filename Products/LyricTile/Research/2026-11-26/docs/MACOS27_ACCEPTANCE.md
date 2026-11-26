# LyricTile — macOS 27 实机验收与支持资格

版本：1.0 / 2026-11-26。本文是待执行规格，不是通过报告。必须使用最终 Developer ID 签名、公证后的安装包复核；开发目录成功不能替代发行包成功。

## 1. 交付记录与证据等级

输出 `acceptance/<run-id>/environment.json`、`capabilities/*.json`、`recordings/<R001..R120>/`、`performance/`、`summary.md`。每个 capability 记录遵循 `contracts/player-capabilities.schema.json`。`run-id` 包含日期和 app commit 短 SHA。

`environment.json` 必填：macOS productVersion/build、`csrutil status` 结果、硬件/芯片/内存、显示器与缩放/刷新率、低电量模式、音频输出设备、LyricTile version/build/commit/package SHA256/签名、公证结果、四播放器 bundleID/version/build、helper commit/hash、时区、测试日期。只读环境；不关 SIP、不修改播放器 bundle、不添加 Apple 私有 entitlement。

每条证据标注 `real_player`、`synthetic_fixture` 或 `source_review`。自动化单元测试/模拟时钟/预设歌词/测试 helper 发布的假媒体只能是 synthetic_fixture，不计入120条真实播放样本，也不得作为四平台支持或 macOS27通过证据。

播放器版本、系统 build 或签名包变动后，旧结果保留但不改写为新包通过。至少重跑受影响适配通路与安装包冒烟；重大媒体接口变化才扩展样本，不机械全部重测。

## 2. 120条真实播放样本：全项目合计，不是每播放器120条

recording 指一次真实播放器播放会话，带实际状态轨迹、对应曲目身份及可追溯观测；不是一条日志或一个按钮点击。每播放器30条，共120条。同一曲目在不同播放器重放可以各计1条，同一轨迹复制不计新增样本。

| 每个平台的样本类型 | Apple Music | Spotify | QQ音乐 | 网易云 | 合计 |
|---|---:|---:|---:|---:|---:|
| 普通同步歌词：中文与英文各4 | 8 | 8 | 8 | 8 | 32 |
| 版本识别：live/remaster/伴奏/同名不同艺人 | 8 | 8 | 8 | 8 | 32 |
| 多语言、长行、双语、逐字重叠等排版边界 | 4 | 4 | 4 | 4 | 16 |
| 无歌词、纯音乐、仅文本/逐行、元数据不完整 | 4 | 4 | 4 | 4 | 16 |
| 控制、焦点竞争、退出/唤醒等情景会话 | 6 | 6 | 6 | 6 | 24 |
| 合计 | 30 | 30 | 30 | 30 | 120 |

普通/边界每条至少覆盖60秒真实播放；每播放器至少1条覆盖完整曲目且≥5分钟。来源缺逐字歌词就如实记缺失，不能为凑样本伪造或均匀分摊词时码。可合法播放的测试曲目/人工标注用于独立校准，但须与真实业务样本分组报告。

每条目录含 `metadata.json`（平台、版本、曲目/版本身份、歌词来源与文档hash/时间等级、网络条件、目标场景）、`events.ndjson`、`metrics.json`；必要截图/录像存 `evidence/`。日志禁录 cookie/token/账号凭证；无需上传任何用户资料或完整歌词到外部。

`events.ndjson` 每行记录：monotonicNs、wallClock、source、sourceSequence、playerSession、trackGeneration、sourcePosition/单位/原始时间戳、rate、playing、clockHealth/uncertainty、渲染位置、命令及 expectedTarget、发送/读回/超时。原始事件按到达记录，UI只在行/词变化及校准点打点，避免60Hz全量持久化。

## 3. 执行顺序

1. **环境与接口盘点**：记录四播放器已安装版本；检查实际 `.sdef`/AppleScript支持；验证 Music duration=秒、Spotify duration=毫秒的当前实际值，不能只信旧header注释。
2. **真实数据探针**：Apple/Spotify定向Apple Events；QQ/网易固定BSD adapter。对get/stream使用`--micros`；确认单曲identity、歌词、封面、position均来自真实来源。
3. **自动记录样本**：以选定音乐库/合法可播放曲目驱动上述120条会话；网络失败、权限拒绝、不可播放应记录blocked并补合法样本，不伪装完成。
4. **交互与故障注入**：执行下表；记录原播放器实际行为。UI快照/控件存在不能代替播放器结果。
5. **性能与持续运行**：固定最终包、相同显示条件测试；异常只针对实际问题扩展定位。
6. **生成资格表**：逐平台、逐能力发布supported/conditional/unsupported/unverified，附证据路径；未跑项保留NOT_RUN。

## 4. 必测情景与判据

| 场景 | 每平台最低动作/覆盖 | 判据 |
|---|---|---|
| 暂停/恢复、前后切歌 | 各20次；含快速连续点击 | 真实状态读回；暂停后词/进度冻结；旧曲请求不污染新曲 |
| seek | 20次：前后、小幅/大幅、暂停中、接近曲尾 | 记录请求与实际位置、是否意外恢复播放；slider预览不等于成功；超时回到真实位置 |
| QQ暂停seek | 必须单列 | 若播放器自动开播，明确处理并再次核对目标；未验证恢复策略前禁用暂停seek，不假填supported |
| 两播放器并行 | 四播放器两两搭配至少一次；A固定、B开始/停止 | 观察与控制身份一致；A不应因B抢媒体而悄悄变成控制B |
| 浏览器抢媒体焦点 | Chrome/Edge/Safari至少各一条真实视频/音频 | 保留音乐源选择；没有定向通路时不发送全局控制，不把视频歌词当歌曲 |
| 命令前后竞态 | 发前切焦点、发后立即切焦点，各≥10次全项目 | 记录所有受影响播放器变化；明确报告观测到的误控数与样本数 |
| 源消失/字段迟到 | 退出/重启、封面/艺人晚到、缺position、helper退出 | 不造进度/旧封面；缺时钟降级；不重启风暴；退出无残留helper |
| 生命周期 | 每平台至少睡眠/唤醒、显示器插拔、锁屏恢复各1次 | 重锚、不抢焦点、不跳回旧曲，窗口落在可见区域 |
| 授权 | Music/Spotify拒绝→设置授权→恢复；AX仅若实际启用 | 无需重装；不多索取录屏/FDA/麦克风权限 |

**误控不能仅凭读回“没发现异常”就证明绝对为零。** 全局MediaRemote读取与发送不是原子操作；报告写“本样本N次中观察到0次误控”，同时保留竞态限制。禁止修改全局Now Playing override。未能安全定向的操作不发；可返回原播放器。不要重试不确定是否已执行的next/previous，避免双跳。

## 5. 时钟、歌词与展示能力分开验收

源分辨率、误差、渲染延迟分别记录：`sourceQuantumMs`不等于`clockErrorP95Ms`；`--micros`只避免传输截断，不提高播放器原始准确度。用独立参考比较；用同一适配器值对照自身外推只能验证内部一致，不能证明实际声音同步。

独立参考须在每条记录注明：播放器UI读取、单独脚本测量、可合法测试音轨的已知音频时码或允许录制的音画对照。若只能用播放器UI整数秒，标记参考精度限制；不能由此签发250ms精度结论。歌词自身时码误差与播放器position误差分开统计，不能互相抵消。

能力记录的`clockErrorP95Ms`使用“观测绝对差值P95 + 独立参考不确定度上界”的保守值，未知填null；不把未知填0。对同一时间源另开一个脚本只证明读数一致，不能代替独立音频参考。`conditions`的命令前置条件必须每次发送前全部为true，缺项视unknown；JSON Schema不能代替这项跨字段运行时判断。

| 可发布能力 | 必要条件 |
|---|---|
| 文本歌词 | 真实歌词匹配可信；无需可用clock；不自动伪造滚动 |
| 逐行同步 | 当前真实行时码+健康clock；目标position error P95≤750ms；失准/stale立即降级 |
| 逐字同步 | 当前真实词级时码+健康clock；在对应系统/播放器版本独立测得position error P95≤250ms；不得从LRC均分词时间 |
| 播放/前后曲/seek | 对应能力本机通过且运行时条件成立；每个按钮独立判断，缺seek不能被总的canControl掩盖 |

每平台至少100个**可评估的独立校准点**，分布于≥10条会话，含暂停/恢复与seek；事件数不是独立样本数。校准未达到覆盖或参考不精确，clock精度标unknown，不能宣布word能力通过。UI可以平滑，但不以平滑替代准确度。

无进度的播放器不从0开始计时。稳定播放期间无新事件不自动判死：用helper存活与低频实际health查询判健康。系统时间变化/唤醒/切歌/seek重锚。pause冻结；stale不无限外推；绘制动画提前量不能改写真实position。

## 6. 性能目标与测量方法

以下是M5目标机上的**目标，不是已经测得的结果**。主app+全部本产品helper合计；固定亮度/电源模式/显示刷新率，预热2分钟。主机有明显其他重负载时记录并重采受污染段。

| 工况 | 连续窗口 | 目标 |
|---|---:|---|
| 未播放/暂停静止 | 10min | CPU均值<0.3%单核 |
| 逐行同步 | 10min | CPU均值<1%单核 |
| 逐字同步 | 10min | CPU均值<3%单核 |
| 悬停/切歌/拖动 | ≥30次 | 可短暂超上述CPU；记录峰值和恢复时间，不把峰值当常驻预算 |
| 各工况内存 | 同上 | RSS合计median<120MiB、1Hz采样peak<180MiB |

CPU用各进程累计user+system CPU time增量除以同窗monotonic wall time，乘100%；100%表示占满一个核，不除以核心数。记录子进程创建/退出，防漏计。RSS每秒采样求和；这是采样峰值，必要时用Instruments核对短时峰值。记录采样工具与定义，不把RSS、physical footprint、VSZ混用。

另做一次8小时真实连续使用，含至少两次暂停/恢复和一次睡眠/唤醒，检查内存长期趋势、后台请求次数、helper数量、日志增长、重新连接。静止/不可见时停止逐字帧调度，网络/IPC不得由每帧渲染触发。若预算未达，给实际数据和优化结论；不靠降低真实歌词能力隐瞒超标。

## 7. 发布裁决

Apple Music/Spotify：metadata、精确position、封面/缺图回退、play/pause、前后曲、seek、打开原播放器、授权恢复、包后验证是正式版硬条件；广告/受限曲目按播放器真实capability降级。

QQ/网易：必须完成适配和本机评估，逐项晋级；可正式发布明确的逐行/当前媒体控制子集，继续保留失败原因与下一步。不能写四平台全部支持却隐藏未做项，也不能因某一失焦seek失败就放弃整个中国平台。只有具备独立测量的健康clock才授予word能力。

任何真实误控、切歌显示旧歌词、虚假进度、损坏系统媒体全局状态，均阻止受影响通路发布。合成回归测试可以补证机制修复，但仍须重跑对应真实情景。最终`summary.md`列明PASS/FAIL/NOT_RUN、120条样本分配、性能数值、目标环境、能力矩阵与剩余限制。

依据：`research/media/MEDIA_AUDIT.md`；[adapter固定源码](https://github.com/ungive/mediaremote-adapter/tree/2ef957c736256cee7905c9f3f1c7e279087bf195)、[定向控制更正](https://github.com/ungive/mediaremote-adapter/issues/41)、[Apple公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md)。
