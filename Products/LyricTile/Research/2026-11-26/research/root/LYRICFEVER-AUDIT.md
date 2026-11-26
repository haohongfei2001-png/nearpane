# Lyric Fever 补充源码审计

审计日期：2026-11-26（Asia/Shanghai）。仓库：[aviwad/LyricFever](https://github.com/aviwad/LyricFever)。本轮实际读取浅克隆源码与 LICENSE，固定提交 `20a44f0fc18a39f28824bf288dc8f368b17b9a99`，该提交日期为 2026-04-03。以下是源码证据，不代表已在目标 macOS 27 运行。

## 产品与复用判断

Lyric Fever 已覆盖 Apple Music / Spotify 伴随歌词、桌面与菜单栏展示，因此 LyricTile 不能把“播放器外显示歌词”当成独有卖点。其原生实现适合参考播放器桥接、权限说明和歌词展示的用户路径。LyricTile 的差异应集中于安静的歌词主体、悬停后就近控制、可靠的录音版本匹配，以及 HOLDSNOW 的桌面排列。

LICENSE 为 MIT；复用其具体代码必须保留版权与许可声明。MIT 只处理代码许可，不授予 Spotify 歌词内容或私有端点使用权。

## 实际读取的关键文件与裁决

| 文件 | 代码证据 | LyricTile 裁决 |
|---|---|---|
| [AppleMusicPlayer.swift](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LyricFever/Players/AppleMusic/AppleMusicPlayer.swift) | ScriptingBridge 定向连接 Music，位置秒转毫秒；`currentTime` 混入固定 +400ms、动画 +400ms、AirPlay -2000ms。 | 桥接结构可参考；不继承这些时间常量。播放器时钟、词源偏移与用户校准分开建模。 |
| [SpotifyPlayer.swift](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LyricFever/Players/Spotify/SpotifyPlayer.swift) | 定向连接 `com.spotify.client`；位置秒转毫秒，duration 直接取轨道字段；`fixSpotifyLyricDrift` 等待2秒后、判断仍播放时调用 `play()`。 | 可借鉴元数据/封面桥接。禁止通过额外播放命令“修复”显示时钟，禁止自动恢复本应暂停的内容。 |
| [SpotifyLyricProvider.swift](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LyricFever/LyricProvider/Spotify/SpotifyLyricProvider.swift) | 存取 `sp_dc` cookie，访问 `spclient.wg.spotify.com/color-lyrics/v2/track/…`。 | 不作为首版主歌词来源；不要求用户提取浏览器 cookie，不把私有接口当成稳定官方授权接口。 |
| [LRCLIBLyricProvider.swift](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LyricFever/LyricProvider/LRCLIB/LRCLIBLyricProvider.swift) | 独立 provider 结构展示检索与解析分离的实际实现。 | 参考分层，不照搬旧响应模型；以本轮 LRCLIB 当前文档与真实响应为准，支持 `lyricsfile` / `hasWordSync`。 |
| [KaraokeView.swift](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LyricFever/Views/KaraokeView/KaraokeView.swift) | `NSVisualEffectView`、`.hudWindow`、`.behindWindow`；800×100 的居中横向字幕结构。 | 验证原生材质与字幕容器的可行实现路径；不能直接当成176–224pt歌词板组件。重新实现窄栏排版与状态布局。 |
| [LICENSE](https://github.com/aviwad/LyricFever/blob/20a44f0fc18a39f28824bf288dc8f368b17b9a99/LICENSE) | MIT Copyright (c) 2024 Avi Wadhwa。 | 若复制具体代码，进入 ThirdPartyNotices 与来源锁定清单；本轮交付没有复制其实现代码。 |

## 与最终技术路线的关系

1. Apple Music / Spotify 走定向 Apple Events 的路线有实际开源代码支撑；正式版本的 `.sdef`、TCC、签名身份和播放器行为仍需实机核验。
2. 时间同步采用单调时钟锚点与实际进度读回；显示动画不能写入播放器进度，也不能用统一常数掩盖漂移。
3. 一个项目能拿到歌词，不等于其端点、内容、账号路径适合另一款公开分发产品。首版使用公开文档支持的服务与用户导入路径，并记录来源政策。
4. 不整体 fork Lyric Fever；可复用的 MIT 桥接片段按实际需要择取，保留许可，其余按本轮接口契约独立实现。
