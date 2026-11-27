# CI47 网易云：官方下载 TLS 握手超时

原始 `result.json` 来自 [CI47 run 46016001883](https://github.com/haohongfei2001-png/nearpane/actions/runs/46016001883)，源码 `01d21fc5ba61161f5cbf54ee494ed13778921910`，完整 artifact `15207145581`。本目录按原字节保留报告，并与原始 ZIP 中的成员逐字节核对；来源和校验见 `SOURCE.json`、`SHA256SUMS`。

本轮官方元数据仍指向网易云 **3.1.14 / build 3459**：

`https://d1.music.126.net/dmusic/NeteaseCloudMusic_Music_official_3.1.14.3459_arm64.dmg`

实际结果是 `download` 阶段 **BLOCKED**，错误为 `URLError: <urlopen error _ssl.c:1129: The handshake operation timed out>`。这是 TLS 握手超时，**不是累计 150 秒下载边界**。报告没有记录已收字节数，不能推断传输进展。没有进入网易云客户端启动、原生歌词或播放控制验收；对应资格均为 `NOT_RUN`。

[CI45](https://github.com/haohongfei2001-png/nearpane/actions/runs/46009188167) 已在同版本客户端上通过单曲原创本地音轨的 18 项普通 App 检查。CI45 源码 `59a4530302e592fc80040c955fffbba339aa3f89` 与 CI47 的生产 `Products/LyricTile/Sources` 无差异；该历史实测继续保留，但不改写本轮的下载 BLOCKED，也不证明商业曲库或播放队列通过。

本归档没有修改下载脚本、扩大累计时限、增加重试或更换来源。
