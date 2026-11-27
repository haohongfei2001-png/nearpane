# CI45 在线歌词验收脚本失败原件

本目录保留 build45（`59a4530302e592fc80040c955fffbba339aa3f89`）的原始报告，逐字节复制；失败结果没有重写为通过。完整 workflow 失败，不能作为已验收发行候选。

## 已发生的真实操作

- 只读原生 AX helper 编译通过，但尚未进入其读回步骤。
- 系统 Music 实际导入并播放官方公开的 Code Monkey MP3；原始 title/artist/album、189.309 秒时长、导入文件 SHA256、current persistent ID 都通过。未修改歌曲 metadata，未登录。
- 普通生产 App 使用空的独立默认缓存并自动请求 LRCLIB。脚本执行顺序已经通过实际缓存的 LRCLIB record 332580、raw/document 内容 hash 一致、歌曲元数据、Music persistent ID、新 fetchedAt 与 index 绑定检查，随后在格式判断失败。
- 原始错误是 `The automatic source did not produce timed line lyrics.`；observations 为空。没有原生歌词显示或两句同步通过的证据。音频、缓存和临时 AX 原文已经清理，原 AppSupport/偏好恢复。

## 已查明的脚本假设错误

生产 `LRCLIBProvider.fetch` 优先解析 `lyricsfile`，再尝试 `syncedLyrics` 和 plain。独立检查同一官方 API 的 record 332580，公开响应包含 lyricsfile 1.0：54 个 timed line、299 个 word token。生产解析器将这种文档标记为 `token`；粗粒度播放器时钟仍按行显示，不因此获得逐字同步资格。

旧脚本只允许 `timingLevel == line`，因而在合法 token 文档进入原生验收之前将其误拒。旧 syncedLyrics hash 是另一种响应格式的参考，原来就不是通过条件；它不能用来否定 production 优先选择的 lyricsfile。

本目录 `lrclib-format-metadata.json` 只记录独立 API 核查的元数据、格式计数和 hash，不包含歌词正文。CI45 脚本在失败前未保存实际缓存 timingLevel/originalFormat/raw hash；不能把独立 API 观察冒充这些缺失的原生字段。

修复仅让验收脚本接受 `line` 或 `token`，仍要求至少两个有时间的 lead cue，并在判断前保存安全格式元数据与 raw hash。来源、record ID、实际文件/缓存 hash、Music 读回与两句不同原生当前句 hash 的硬条件保持不变。最新原包的成功原生复验仍待后续 CI；本次不改变生产代码或逐字精度声明。
