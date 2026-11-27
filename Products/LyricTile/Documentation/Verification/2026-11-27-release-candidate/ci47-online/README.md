# CI47 · 真实歌曲自动在线歌词验收

## 结论与同源性

本目录保存 **build 47 普通生产 App 的一个真实在线歌词端到端通过记录**：官方 Code Monkey 录音 → 实际 Apple Music 本地播放 → LyricTile 自动识别 → 生产 LRCLIB/repository 自动选择并缓存 → 原生 Accessibility 当前句散列与真实 Music 位置相符。

运行：[CI47 / 46016001883](https://github.com/haohongfei2001-png/nearpane/actions/runs/46016001883)；源码 `01d21fc5ba61161f5cbf54ee494ed13778921910`；小制品 `15206239025`；原 ZIP SHA256 `ea96c1691bdae50104763b743c0b2f27bcbea7356f3bcf71ae72257ee1e56316`。六个原 JSON 按字节复制，文件大小、SHA256 和 ZIP 核验记录见 [SOURCE.json](SOURCE.json)。没有改写原始 PASS/未匹配观察。

普通 App 的实际可执行文件 SHA256 为 `9001398263a302a5afee720f5c445449c6ad7e17b24802c2853e5a3458378ce3`。本次没有使用 App 内的 native verification 入口，没有注入歌词，没有登录账号，也没有归档音频、歌词正文或第三方歌词截图。

## 实际音频、歌曲身份与自动缓存

- 官方完整录音的字节与独立读取的 Music 导入副本一致：4,319,316 字节，SHA256 `3866a8aa2fba54bdc278e8b55b278d73f51c6cf0ad06bf1e9835c409c824d586`。
- Music 读回原始标签：Code Monkey / Jonathan Coulton / Thing a Week Three；时长 189.309005737305 秒。没有编辑元数据。
- 实际当前 Music persistent ID 为 `4F77C5AF1B8D6225`，与导入曲目、播放读回、缓存 recording platform ID 均相同。
- 普通 App 自动选择 LRCLIB `332580`；缓存起初为空，索引绑定已核验。启动 App 后至发现可验证自动缓存的观察耗时 **1.528418 秒**。该数字包含这段启动/识别/请求/落盘观察过程，不单独代表 HTTP 延迟或首次歌词显示延迟。
- 实际优先选择的格式为 `lyricsfileV1Draft`、文档 timingLevel 为 `token`，有 **54 条主歌词 cue**。实际 raw payload 为 17,738 字节，raw 与 parsed document content SHA256 都是 `581d4e66b796f8de2e05c915c8ca9bfcba5830e88cc3cc623863e8a509b6b263`。
- `referenceSourceHashMatched=false` 如实保留：预先记录的是另一种 `syncedLyrics` 文本表示的 hash，而生产采用同一条目的 Lyricsfile 表示；它不是 raw/document hash 不一致。报告已明确该旧 hash 只作信息参考。

## 四次原生观察完整保留

以下时间来自检查 AX 前、后的真实 Music 读回，单位为毫秒；cue 序号从 0 开始。验收器要求前后读回位于同一个有效当前 cue，且实际中心 AX 文本 SHA256 与该 cue 相同。

| 观察 | Music 前 → 后 | 前次读取的期望 cue | 原报告结果 | 说明 |
|---|---:|---:|---|---|
| 1 | 2306 → 2557 | 0 | 未匹配 | AX hash 与前次期望相同，但整项稳定区间门槛未通过，未计作成功。 |
| 2 | 3123 → 3440 | 无 | 未匹配 | 前次读取没有可确认的当前 cue；原始 null/false 均保留。 |
| 3 | 4140 → 4390 | 1 | 通过 | 当前句 SHA256 `b58df2ea5f430bcd7ab72098b56c0c93e9e55107a40f589356c5ddde8f325cae`。 |
| 4 | 7617 → 7850 | 2 | 通过 | 当前句 SHA256 `157d11bf8d0b12dae8aedda2c399f5a90cafdccf76e4fa022f51b2e3a8c563f6`；此前实际通过 Music 将位置跳转至 7.09 秒。 |

两次成功观察均命中普通 LyricTile 进程 `24191` 的唯一可见窗口 `88`，原生窗口 bounds 为 `(832,47,176,192)`，中心点为 `(920,143)`。System-wide AX 命中同 PID、同窗口，角色为 `AXStaticText`；只读取文本散列，没有通过助手发送输入或请求权限。两个匹配 hash 不同，不能用固定不动的一句满足此门槛。

原报告总耗时 **14.266 秒**。结束后临时音频/歌词清理、既有 Application Support 和偏好恢复均为 true，cleanup errors 为空。

## 可以与不能据此宣称的范围

可以确认：这一官方原版录音在真实 Music 中免登录播放时，普通 LyricTile 能通过生产在线服务自动取得对应歌词，并在两个检查点显示与播放器位置相符的当前句，其中一次在真实 Music 跳转之后。

这是单曲、两个匹配检查点的证据。前两次未匹配如实保留；不宣称无延迟、整首无误差、普遍曲库覆盖率、独立声学时钟精度或逐字同步精度。文档包含 token 不等于播放器时钟已经通过逐字资格；原报告 `wordSynchronizationQualified=false`。

同轮 Music 两曲控制流程是独立验收，步骤失败不能由此在线单曲通过改写。其他播放器、性能、签名公证、安装及更新也需分别引用各自实际证据。

官方来源、CC BY-NC 3.0 署名/非商业边界保留在 [source-provenance.json](source-provenance.json)。本测试只临时播放该官方公开录音，音频与第三方歌词正文没有进入本目录或产品；不能把此许可扩大成产品或宣传中的商业分发许可。
