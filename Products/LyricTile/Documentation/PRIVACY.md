# LyricTile 隐私说明 · Privacy

更新 / Updated: 2026-11-27. Product: LyricTile by HOLDSNOW.

## 中文

LyricTile 是独立运行的 macOS 歌词工具，不需要 HOLDSNOW 账号。应用不包含广告、遥测或向 HOLDSNOW 上传播放记录的服务。

**读取的信息。** 为显示歌词和控制音乐，应用读取当前播放器提供的曲名、歌手、专辑、时长、播放位置、播放状态及封面。Apple Music 和 Spotify 的 Automation 权限只在实际需要时由 macOS 请求；权限用于相应播放器。常规歌词功能不需要麦克风、屏幕录制、辅助功能或完全磁盘访问。

**在线歌词。** 在线查找默认开启，欢迎页会说明，可在设置中随时关闭。开启时，当前歌曲的标题、歌手、专辑和时长会发往 [LRCLIB](https://lrclib.net/docs)。服务端也会收到建立网络连接所需的 IP 地址和识别应用的 User-Agent。LyricTile 不发送原始音频、本地歌词文件、账号凭据或完整播放历史。第三方服务独立处理收到的请求，服务条款由其提供。关闭在线查找后不再发起新的歌词请求；已保存的歌词和导入文件仍可使用。

**本地存储。** 歌词及手动绑定保存在 `~/Library/Application Support/HOLDSNOW/LyricTile/`，偏好保存在 macOS 的应用偏好中。自动缓存限制为 64 MiB、256 项及 7 天期限；手动导入或明确绑定的歌词不按自动缓存规则删除。设置中的清除缓存不会删除用户导入、绑定及其时间校准。卸载应用不会自动抹除这些文件。

**封面与更新。** 播放器可提供本地封面，Spotify 路径也可能按其提供的地址获取封面。检查应用更新会连接配置中的 GitHub HTTPS 更新源及下载地址。自动检查默认关闭，可由用户在应用内检查更新。下载平台会收到正常连接信息；LyricTile 不运行独立的用户分析服务。

**诊断。** 显式导出的诊断可能包含曲名、播放器版本、播放时间、系统版本和本机路径。导出留在用户指定的位置，不自动上传。分享前可检查内容。

**歌词内容。** 歌词、录音及封面的权利归各自权利人。LRCLIB 的开放 API 不等于对每首歌词授予版权许可；本软件不附带第三方歌词库，也不宣称拥有或转授这些内容的权利。用户可以查看当前歌词来源，或导入自己有权使用的歌词。

问题或隐私请求：[LyricTile issue 页面](https://github.com/haohongfei2001-png/nearpane/issues/new?title=LyricTile%3A%20privacy)。请勿在公开 issue 附上私人播放记录、账号或诊断原件。

## English

LyricTile is an independent macOS lyrics companion. No HOLDSNOW account is required. The app contains no advertising, telemetry, or service that uploads listening history to HOLDSNOW.

**Player information.** The app reads the title, artist, album, duration, playback position/state, and artwork supplied by the current player to display lyrics and operate playback controls. macOS requests Automation access for Apple Music or Spotify when needed. Normal lyrics features do not require Microphone, Screen Recording, Accessibility, or Full Disk Access.

**Online lyrics.** Lookup is enabled by default, explained in the welcome screen, and can be disabled in settings. While enabled, the current song's title, artist, album, and duration are sent to [LRCLIB](https://lrclib.net/docs). That service also receives the IP address needed for the connection and an identifying application User-Agent. LyricTile does not send audio, imported lyric files, account credentials, or a complete listening history. Third-party providers process requests under their own terms. Turning lookup off stops new lyric requests; saved and imported lyrics remain available.

**Local storage.** Lyrics and manual bindings are stored in `~/Library/Application Support/HOLDSNOW/LyricTile/`; preferences use macOS application preferences. The automatic cache is bounded to 64 MiB, 256 entries, and a seven-day age limit. Imported or explicitly bound lyrics are protected from automatic eviction. Clear Cache preserves these user files and their timing adjustments. Uninstalling the app does not automatically erase them.

**Artwork and updates.** A player may supply local artwork; the Spotify adapter may fetch an artwork URL supplied by the player. Update checks contact the configured GitHub HTTPS feed and download host. Automatic checks are initially off; you can check in the app. Hosting providers receive ordinary connection information. LyricTile operates no separate analytics service.

**Diagnostics.** Explicitly exported diagnostics may contain song titles, player versions, playback times, operating-system information, and local paths. They remain at the chosen location and are never uploaded automatically. Review them before sharing.

**Content rights.** Lyrics, recordings, and artwork remain the property of their respective rights holders. Access to the LRCLIB API does not establish copyright authorization for every returned lyric. LyricTile includes no third-party lyric catalog and does not claim ownership or a sublicense to those works. You can inspect the current lyric source or import lyrics you are entitled to use.

Questions: [LyricTile issue page](https://github.com/haohongfei2001-png/nearpane/issues/new?title=LyricTile%3A%20privacy). Do not post private listening records, credentials, or unreviewed diagnostic archives publicly.
