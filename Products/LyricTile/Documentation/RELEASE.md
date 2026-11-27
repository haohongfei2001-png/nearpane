# LyricTile 发行入口 · Release

独立产品，Apple silicon / macOS 27+；Bundle ID `com.holdsnow.lyrictile`。发布目标固定为 Nearpane 仓库中的 **LyricTile 专属 tag/Release**。不要使用整个仓库的 `releases/latest`：该仓库也发行 Nearpane。

## 当前材料

- 最新源码和证据：[STATUS](../STATUS.md)。已公证 build 4 是历史包，不能用于代表新界面。
- 中文/英文产品页：[Website](../Website/README.md)，现有官网挂载点 `https://nearpane.com/lyrictile/`。正式包未就绪时显示候选状态；不会自动回退下载旧包。
- 用户资料：[安装](INSTALL.md)、[支持范围](SUPPORT.md)、[隐私](PRIVACY.md)、[第三方许可](THIRD_PARTY_NOTICES.md)。隐私与完整依赖许可随包分发。
- 更新源：`https://raw.githubusercontent.com/haohongfei2001-png/nearpane/refs/heads/codex/lyrictile-standalone-20261126/Products/LyricTile/Updates/appcast.xml`。
- 专用 Ed25519 公钥已配置；私钥仍由持有者钥匙串管理。当前空 feed 没有可安装项目。不能将空通道称为“已更新到最新正式版”。

## 最终同一包的构建与校验

`build-app.sh` 生成含版本及构建号的候选 ZIP/DMG。`notarize-candidate.sh` 沿用该 App 的版本与构建号，生成 `LyricTile-VERSION-BUILD-arm64.zip/.dmg`、Apple 回执及精确 `SHA256SUMS`，不会把目录中其他旧包收入新校验文件。

1. 使用现有 Developer ID、专用更新公钥及 feed 构建最新已测源码，构建号必须大于已经分发的构建。不得复用 build 4。
2. 对同一包运行公证脚本；其 App、ZIP、DMG 必须对应相同 commit、版本、构建号。
3. 使用现有 `com.holdsnow.lyrictile.updates.v1` 钥匙串账户为最终 ZIP 签名，随后运行 `write-appcast.py --help` 填入真实的 HTTPS Release asset URL。不要提交临时回环或本机下载 URL。
4. 运行下面的 `verify-release.py --mode release`。它检查包 ID、源码 SHA、递增构建号、ZIP/DMG 与 App 内容一致、哈希、appcast 版本/大小/下载名，以及真实 Ed25519 签名。在 macOS 上还检查 Developer ID、stapler 与 Gatekeeper。
5. 从旧 build 4 升级到这一最终包，检查启动、设置和本地歌词保留；记录具体来源/目标包哈希。既有 2→4 验证只作基线，不冒充新包结果。

```sh
python3 Scripts/verify-release.py \
  --app "$LYRICTILE_FINAL_APP" \
  --archive "$LYRICTILE_FINAL_ZIP" \
  --dmg "$LYRICTILE_FINAL_DMG" \
  --checksums "$LYRICTILE_FINAL_SUMS" \
  --expected-commit "$LYRICTILE_FINAL_COMMIT" \
  --minimum-build 4 \
  --appcast "$LYRICTILE_FINAL_APPCAST" \
  --mode release --output dist/release-verification.json
```

以上 `LYRICTILE_FINAL_*` 是操作者本轮确认的实际文件路径/源码，不是凭据。CI 可用 `--mode candidate` 验证工程产物；这不会声称公证、播放器通过或公开发布。

## 发布顺序

创建该版本独立 Release 草稿；上传最终 ZIP、DMG、`SHA256SUMS`、发行说明和验收摘要。核对 tag 指向实际最终源码，检查 asset 大小与哈希。确认核心闭环及上述发行检查通过后，将该 Release 公开；验证公开下载后再更新 appcast 和官网正式下载字段。官网 manifest 的 `published`、`downloadURL`、`releaseURL`、`version`、`build`、`sha256` 和支持列表必须来自同一次发行，不能指向临时 CI 归档。

历史草稿 `459311386` 属于 build 4；本轮不要直接把它改名为新版本而保留旧附件。可以单独保留历史草稿，不影响新版独立发行。

## 首版发行说明草稿

**LyricTile 1.0.0 — 歌词，自然在旁。**

为 macOS 提供独立的伴随歌词板。播放音乐时自动出现，当前歌词居中突出；长句自适应，悬停后显示音乐信息和控制。无歌词时回到紧凑歌曲摘要，停止播放后释放桌面空间。支持在线查找、选择歌词版本、本地导入与时间校准。包含中英文主要界面及独立更新通道。

发布时写入最终构建号、macOS 和播放器实际通过版本、下载校验值及仍存在的限制。歌词覆盖率因来源和歌曲版本而异；第一版不承诺所有平台或逐字歌词。

**LyricTile 1.0.0 — Lyrics, naturally beside you.**

An independent macOS lyrics companion that appears while music plays. The current line stays centered; long lyrics adapt to the available space. Hover for artwork, song details, playback controls, and progress. Songs without lyrics use a compact summary, and the panel disappears when playback stops. Includes online lookup, version selection, local import, timing adjustment, Chinese and English UI, and a dedicated update channel.

Publish with the exact final build number, tested macOS/player versions, checksums, and known limitations. Coverage varies by source and recording; not every player or song supports word-level lyrics.
