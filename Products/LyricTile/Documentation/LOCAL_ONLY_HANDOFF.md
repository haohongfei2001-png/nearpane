# 给本机 Codex：LyricTile 的剩余执行指令

## 目标与当前边界

在 `haohongfei2001-png/nearpane` 的 `codex/lyrictile-standalone-20261126` 分支继续。独立产品位于 `Products/LyricTile`；对应 Draft PR 为 [#17](https://github.com/haohongfei2001-png/nearpane/pull/17)。首先读取 [STATUS.md](../STATUS.md)，获取最新源码验证、剩余任务及必要文件入口；旧候选证据只作为历史基线，不替代新代码验证。

设计、源码审计、技术裁决、生产实现、格式/时间/匹配/进程/布局测试、独立打包、更新接入、诊断导出及签名公证脚本均在本分支。当前应用不依赖 Nearpane 启动，不应改成网页壳或多个独立浮窗拼装的 Host。不要把研究归档中的“未来待实现”当作当前状态；以实际源码、实现 ADR 和最终 CI 记录为准。

本机仍有必要承担的工作只有：**实际安装的四个播放器与 TCC、macOS 27.0 和用户显示器环境、独立时钟参考与长时间性能、持有者的真实签名/公证/更新配置。** 遇到实测缺陷就在此分支修复并提交证据，不能通过放宽断言或加入假进度使结果变绿。

## 1. 准备同一候选

```sh
git fetch origin codex/lyrictile-standalone-20261126
git switch codex/lyrictile-standalone-20261126
git pull --ff-only origin codex/lyrictile-standalone-20261126
cd Products/LyricTile
sw_vers
xcodebuild -version
swift --version
git rev-parse HEAD
swift test --parallel
bash Scripts/build-app.sh
python3 Scripts/verify-media-helper.py dist/LyricTile.app/Contents/Resources/MediaRemote --output dist/evidence/local-helper-load.json
open dist/LyricTile.app
```

主目标设备是用户的 Apple silicon MacBook Air / macOS 27.0，另有 DELL 4K 显示器。记录实际值，不能把云端 macOS 27.0.1 的结果写成本机 27.0 的结果。`dist` 是生成目录；测试报告写到独立、未提交的本地目录，最后只提交必要的脱敏总结和证据摘要。

## 2. 四播放器的真实垂直验证

先完成下表的最短核心闭环，再按归档 `Research/2026-11-26/docs/MACOS27_ACCEPTANCE.md` 完成正式验收矩阵。每次记录播放器版本/build、OS build、app commit、播放输出路径和实际结果。

| 验证组 | 必须观察到的真实结果 |
|---|---|
| 发现与切换 | 自动发现正确的四个原生播放器；浏览器媒体不会变成歌词来源；用户固定来源不授予全局误控权限；同名不同版本的歌曲不会沿用旧歌词 |
| 时间 | 播放、暂停、恢复、自然切歌、手动切歌、前后 seek、暂停后 seek、睡眠唤醒都重锚；无真实进度时显示不可同步状态 |
| 控制 | 播放/暂停/上一首/下一首/seek 各一次发出并真实读回；QQ/NetEase 丢失系统源所有权后停止全局控制；QQ 暂停 seek 保持禁用 |
| 歌词 | LRCLIB 真请求、正确版本匹配、歧义候选、404、429、断网、恢复；本地 LRC/TTML/Lyricsfile 导入、绑定、正/负提前量、清缓存保护用户绑定 |
| UI | 默认歌词主体；hover 前后同框；歌词不消失；菜单/拖动/seek 不造成反复折叠；中文/英文/RTL/长行/译文、深浅色与降低透明度都可读 |
| 桌面 | 主屏/DELL 4K 的缩放、热拔插、睡眠、Spaces/全屏；旧 Saytile/Riftlet 避让；共享协议重排屏障；Nearpane 直接嵌入与显式交接仅一方拥有会话 |

Apple Music/Spotify 首次需要时才允许系统弹出 Automation 请求。QQ/NetEase 正常路线不要求辅助功能、录屏、麦克风或完全磁盘访问。拒绝权限也必须能回到可理解状态。不要改 TCC 数据库或扩大授权来掩盖问题。

本轮修复的实机重点：在线请求途中导入本地歌词、拖动进度途中切歌、其他组件退出后的自动排列恢复、登录项在系统设置允许/撤销后回到应用的状态。纯异步竞争和布局状态已有回归用例，本机只确认实际播放器和窗口行为。

遇到某个播放器/版本不能可靠提供源进度或安全控制时：保存实际失败证据，保留诚实的降级状态，缩小正式支持声明。第一版的正式支持列表由通过的具体版本决定，不由四个适配器已经存在决定。

## 3. 采集真实源证据

先通过菜单退出普通 LyricTile，避免同时运行两份观察会话。打开目标播放器并播放真实曲目，然后使用**同一个 app 包**的显式诊断入口。以下输出目录必须为新的或空的绝对路径：

```sh
dist/LyricTile.app/Contents/MacOS/LyricTile \
  --diagnostics --player appleMusic --seconds 120 \
  --output /absolute/private-evidence/apple-music-session-01
```

`--player` 另外接受 `spotify`、`qqMusic`、`netease`。采集只观察，不自动发出 transport、不上传。`events.ndjson`、`source.ndjson`、`environment.json` 和 `summary.json` 包含真实字段及时间基准；没有真实曲目会留下证据并失败，不会把空窗口算通过。完整字段和实际 TCC 归属检查见 `MEDIA_IMPLEMENTATION.md`。

逐字连续扫光的 `PlaybackClockQualification.json` 必须由独立参考证据计算，而不是把同一个 MediaRemote/Apple Event 源两次读数的差异当作准确度。至少 100 个有效点、10 个真实会话；记录参考不确定度，保守 P95 ≤250ms，版本/系统/adapter 精确匹配，最长 90 天有效。未完成时保持真实逐行同步，不创建“全平台通过”的默认资格文件。

## 4. 性能与长稳

先让普通 app 在真实状态下运行，从 Activity Monitor 或 `pgrep -x LyricTile` 核实 PID，再执行：

```sh
python3 Scripts/measure-runtime.py --pid ACTUAL_PID --seconds 120 --mode idle --output /absolute/private-evidence/idle-01
python3 Scripts/measure-runtime.py --pid ACTUAL_PID --seconds 120 --mode line --output /absolute/private-evidence/line-01
python3 Scripts/measure-runtime.py --pid ACTUAL_PID --seconds 120 --mode word --output /absolute/private-evidence/word-01
```

`word` 只用于实际已具备真实 token 时间和资格的情况。报告聚合 app 与子进程，CPU 是单核百分比估计；瞬时 helper 可能漏采，边界结果用 Instruments 核对。目标：idle ≤0.3%、逐行 ≤1%、逐字 ≤3%；RSS 中位数 ≤120MiB、峰值 ≤180MiB。通过 `--seconds 28800` 采集八小时长稳。不得把未运行的模式填为 0 或 PASS。

观察切歌后旧任务/封面是否清理、429 是否产生请求风暴、睡眠后 helper 是否重建、音频源停止后 UI/动画是否停转。性能不足先定位具体工作，再改调度/缓存/渲染；不要用降低同步真实性换低 CPU。

## 5. 真实签名、公证、更新

凭据使用本机现有 Keychain/Developer ID 配置。不要将私钥、账号密码、API key 或原始播放记录写入仓库。先配置真实 HTTPS feed 与 Ed25519 公钥，再构建、签名和公证同一份包：

```sh
export LYRICTILE_SIGN_IDENTITY='Developer ID Application: ACTUAL_OWNER (ACTUAL_TEAM_ID)'
export LYRICTILE_UPDATE_FEED='https://ACTUAL_OWNED_HOST/path/appcast.xml'
export LYRICTILE_UPDATE_PUBLIC_KEY='ACTUAL_BASE64_ED25519_PUBLIC_KEY'
export LYRICTILE_BUILD_NUMBER='ACTUAL_INCREASING_BUILD'
bash Scripts/build-app.sh
export LYRICTILE_NOTARY_PROFILE='ACTUAL_EXISTING_KEYCHAIN_PROFILE'
bash Scripts/notarize-candidate.sh dist/LyricTile.app
```

这些大写值是清楚标注的配置位置，不是可复制的真实凭据。缺少配置时继续使用候选渠道；不要伪造公证票据。`notarize-candidate.sh` 会保存 Apple 返回结果，验证 stapler/Gatekeeper，再生成已公证 ZIP/DMG。

用与包中公钥对应的真实 Sparkle `sign_update` 工具对最终 ZIP 签名，再用 `Scripts/write-appcast.py --help` 生成 appcast。序列化脚本只检查字段，不声称替你验证私钥归属；必须实际从一个旧签名构建升级到新构建，并验证错误签名被拒绝。无 feed 的候选会明确显示“尚未连接正式更新频道”。

公开稳定发行前记录 LRCLIB API/歌词内容授权适用性、地域与署名条件；代码 BSD/MIT 许可不等于歌词/封面许可。当前包没有内置歌词数据库。此分支不自动创建公共 stable Release；后续发布沿用用户实际授权的渠道与持有者配置。

## 完成记录格式

新增 `Documentation/Verification/local-YYYY-MM-DD.md`，至少包含：确切 commit 与包 SHA256、实际环境、各播放器通过/失败/未运行的用例、精度测量方法与误差、资源与八小时结果、双屏/交接结果、签名公证票据标识、最终正式支持清单、仍存在的限制。原始私人轨迹留本机，仓库记录脱敏结果与文件哈希。

完成必要修复后提交本分支并覆盖更新简短的 `STATUS.md`，将详细证据放入独立验证记录。保持 PR #17 与实际结果一致。如果当前最新 CI 已经通过，不要以重做设计、重写解析器或重新搭建工程作为前置步骤。

