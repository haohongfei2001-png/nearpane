# 支持范围与证据 · Support and evidence

更新：2026-11-27。**当前源码、最新包及本轮验收以 [STATUS.md](../STATUS.md) 和其链接的原始证据为准。** 本表保留证据适用范围，不将历史结果移植给新包。

| 对象 | 已有证据 | 可以据此声称的范围 |
|---|---|---|
| macOS 27 / Apple silicon | 旧 build 4 在 MacBook Air 实机运行；新候选在 macOS 27.0.1 arm64 原生 CI 构建与启动 | 首发目标平台；不承诺 Intel 或 macOS 14–26 |
| Apple Music 1.7 | 旧 build 4 的本地音轨、生产适配器、面板及控制验证；本轮新增云端结果见 STATUS | 证据中的本地播放路径；不是 Apple Music 全云端曲库或每首歌歌词覆盖承诺 |
| QQ Music 11.11.0 | 旧 build 4 的本地音轨与系统 Now Playing 路径验证 | 该历史客户端/系统组合；最新包需对应回归证据 |
| Spotify 桌面版 | 已实现适配器；尚无已登录实际播放的通过记录 | 待验证；不列为已通过首发支持 |
| 网易云音乐 | 已实现独立适配器；无可用实际播放通过记录 | 待验证；不列为已通过首发支持 |
| 歌词布局、长句、英文、深浅色、hover | SwiftUI/AppKit 原生夹具截图与交互状态测试 | 真实原生渲染，测试歌曲输入；不等于真实播放器端到端通过 |
| LRCLIB 在线请求 | 使用真实官方接口；具体样本和成功/失败见本轮验证记录 | 只报告实际抽样结果；不宣称全部歌曲覆盖 |
| 连续逐字扫光 | 代码支持真实 token 时码及对应精度资格 | 首版不承诺每首歌逐字；缺资格时仍提供真实逐行同步 |
| 长稳及升级 | build 4 八小时、build 2→4 Sparkle 升级及公证证据 | 历史同一包基线；最新签名包和升级仍需对应最终核验 |

## 首发口径

首先发行通过核心闭环的播放器与版本，不把四个播放器全部通过、完美逐字、所有显示器或重复八小时测试设为硬性条件。某项尚未运行只限制该项承诺；真实失败需要明确记录和处理。可用歌词取决于提供方、地区、曲目元数据和录音版本，LyricTile 不是音乐订阅或歌词内容授权服务。

## English

The initial platform is **Apple silicon, macOS 27 or later**. The exact current build and its evidence are recorded in [STATUS](../STATUS.md). Build 4's Apple Music 1.7 and QQ Music 11.11.0 local-playback results, eight-hour run, notarization, and build 2→4 update are historical results for that package. They do not certify a newer binary.

Spotify and NetEase adapters exist, but an adapter is not a successful real-player qualification. They remain unverified unless a current evidence record says otherwise. Native layout fixtures demonstrate the actual AppKit/SwiftUI rendering with authored input; browser checks and service requests are separately labeled.

The first release can support the players that pass the complete core path. It does not require all four players or perfect word-by-word timing. Lyrics availability depends on provider coverage, region, metadata, and the actual recording version. LyricTile is not a music subscription or a content-licensing service.
