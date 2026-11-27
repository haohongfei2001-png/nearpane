# 给本机 Codex：完成 LyricTile 最后签名与发行

继续 `haohongfei2001-png/nearpane` 的 PR #17，产品目录 `Products/LyricTile`。先读 `STATUS.md` 和 `Documentation/RELEASE.md`，继承云端已经完成的开发、原生界面、在线歌词与性能证据。本指令只补本机凭据及云端确实无法完成的最后环节，不重新设计或全量重验。

## 1. 冻结同一候选，沿用已有凭据

最终候选必须取自**最新已成功的 macOS CI**：源码 `<FINAL_SUCCESSFUL_CI_40_HEX_SHA>`、构建号 `<FINAL_CI_BUILD>`、运行 `<FINAL_CI_RUN_URL>`。最终原生验收尚未结束时保留这些显式占位；执行前由 Codex 从最终 CI 的包内 `LyricTileBuildCommit`、`CFBundleVersion` 和 `dist/evidence/release-integrity.json` 核对后填入，不能用随后仅更新文档的分支 HEAD 代替。云端包是候选；**当前最新包尚未取得本机 Developer ID 签名与公证**。已公证 build 4 仅是旧版本和升级来源。

前提：Apple silicon / macOS 27+、可用完整 Xcode、GitHub 仓库写权限，以及本机原有 Developer ID Application、notarytool Keychain profile、Sparkle `sign_update`。沿用 build 4 的 Team `ZB9D4T66QB` 和钥匙串账户 `com.holdsnow.lyrictile.updates.v1`；不生成新更新密钥。凭据在本机使用，不写入仓库或聊天。保留原样 build 4 App 和现有偏好/本地歌词，供升级验证。

以下占位由 Codex 在本机核实并替换，然后连续执行。构建号应与最终云端候选一致且高于已公开分发版本；若该号已用于另一份正式包，使用更高号并记录原因。

```bash
set -euo pipefail
LT_SOURCE_COMMIT='FINAL_SUCCESSFUL_CI_40_HEX_SHA'
LT_BUILD='FINAL_CI_BUILD'
LT_SIGN_UPDATE='/absolute/path/to/existing/Sparkle/bin/sign_update'
export LYRICTILE_SIGN_IDENTITY='EXISTING_Developer_ID_Application_identity'
export LYRICTILE_NOTARY_PROFILE='EXISTING_notarytool_Keychain_profile'
[[ "$LT_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$LT_BUILD" =~ ^[0-9]+$ && "$LT_BUILD" -gt 4 ]]

git fetch origin codex/lyrictile-standalone-20261126
LT_WORKTREE="$(dirname "$(git rev-parse --show-toplevel)")/lyrictile-release-$LT_BUILD"
git worktree add --detach "$LT_WORKTREE" "$LT_SOURCE_COMMIT"
cd "$LT_WORKTREE/Products/LyricTile"
[[ "$(git rev-parse HEAD)" == "$LT_SOURCE_COMMIT" ]]
export LYRICTILE_VERSION='1.0.0'
export LYRICTILE_BUILD_NUMBER="$LT_BUILD"
export LYRICTILE_ARCH='arm64' LYRICTILE_CONFIGURATION='release' LYRICTILE_CREATE_DMG='1'
export LYRICTILE_OUTPUT="$PWD/dist" LYRICTILE_NOTARY_OUTPUT="$PWD/dist/notarized"
export LYRICTILE_UPDATE_FEED='https://raw.githubusercontent.com/haohongfei2001-png/nearpane/refs/heads/codex/lyrictile-standalone-20261126/Products/LyricTile/Updates/appcast.xml'
export LYRICTILE_UPDATE_PUBLIC_KEY='NjwCt0hsJ9Ps97gwa1ZQvHfaVkr69TN0JIjNi7E522w='
bash Scripts/build-app.sh
bash Scripts/notarize-candidate.sh dist/LyricTile.app

LT_EVIDENCE="$PWD/dist/local-release-evidence"
mkdir -p "$LT_EVIDENCE"
LT_APP="$PWD/dist/LyricTile.app"
LT_FINAL_DIR="$PWD/dist/notarized"
LT_STEM="LyricTile-$LYRICTILE_VERSION-$LT_BUILD-arm64"
LT_TAG="lyrictile-v$LYRICTILE_VERSION-build$LT_BUILD"
LT_ZIP="$LT_FINAL_DIR/$LT_STEM.zip"
LT_DMG="$LT_FINAL_DIR/$LT_STEM.dmg"
LT_ZIP_URL="https://github.com/haohongfei2001-png/nearpane/releases/download/$LT_TAG/$LT_STEM.zip"
"$LT_SIGN_UPDATE" --account com.holdsnow.lyrictile.updates.v1 "$LT_ZIP" > "$LT_EVIDENCE/sign-update.txt"
LT_SIGNATURE="$(python3 - "$LT_EVIDENCE/sign-update.txt" <<'PY'
import pathlib,re,sys
m=re.search(r'edSignature="([^"]+)"',pathlib.Path(sys.argv[1]).read_text())
if not m: raise SystemExit('Inspect the existing sign_update tool output; do not invent a signature.')
print(m.group(1))
PY
)"
python3 Scripts/write-appcast.py --app "$LT_APP" --archive "$LT_ZIP" \
  --download-url "$LT_ZIP_URL" --ed-signature "$LT_SIGNATURE" \
  --output "$LT_EVIDENCE/appcast.xml"
python3 Scripts/verify-release.py --mode release --app "$LT_APP" \
  --archive "$LT_ZIP" --dmg "$LT_DMG" --checksums "$LT_FINAL_DIR/SHA256SUMS" \
  --expected-commit "$LT_SOURCE_COMMIT" --minimum-build 4 \
  --appcast "$LT_EVIDENCE/appcast.xml" --output "$LT_EVIDENCE/release-verification.json"
python3 Scripts/run-native-smoke.py "$LT_APP" --output "$LT_EVIDENCE/native-final"
```

使用本机既有 Sparkle 工具流程为最终 feed 保留需要的签名；修改 feed 内容后重新签署，不复制旧签名块。`verify-release.py` 必须通过真实 Ed25519、App/ZIP/DMG 元数据和内容一致性、校验值、Developer ID、stapler、Gatekeeper 检查。最后的native smoke只确认本机刚生成的同一签名包能启动及正确显示窗口，自动保存实际显示比例；不重跑云端全套矩阵。若构建或公证失败，修正具体问题后重复受影响步骤；不要用旧 build 4 代替。

## 2. 只补尚未完成的真实 Apple Music 闭环

先查看最终云端 Apple Music 记录；若已完整通过则跳过本节。若受云端 Music 初始化、TCC 或会话限制，仅用上述同一最终 App 和本机已有合法可播放歌曲补验：自动识别正确曲目和歌词版本，播放/暂停/恢复，前后定位，切歌后切换歌词，Hover 控制真实读回，以及停止播放后消失。按需集中处理一次 macOS Automation 提示。记录实际 macOS、Music 版本、歌曲版本、取得歌词的来源及耗时；无在线结果时可导入本地歌词验证同步，但不得计为在线自动匹配成功。

需要原始证据时，先退出普通 App，再运行同一包的 `--diagnostics --player appleMusic --seconds 120 --output /absolute/new/private-evidence-dir`；该入口只观察，不代替面板控制操作。确认没有明确回归即可；不要求 Spotify、QQ、网易全部通过，不将独立逐字资格或重新八小时长稳设为首发条件。未通过的播放器保持明确限制。只有发现与最新修改有关的具体性能异常，才定向采样定位。

## 3. 升级同一包，然后公开正确渠道

复用本机已经跑通的 Sparkle CLI / 受控签名 feed 流程，将**原样公证 build 4** 升级到上面的最终 ZIP。临时测试 feed 仅用于验证，公开 feed 保留 HTTPS。确认升级后版本、构建号、源码 SHA、签名、启动正常，偏好和本地歌词保留；目标 App 与最终 DMG 的 plist/可执行文件一致。不要把既有 2→4 结果记作此次通过。

检查通过后按用户已有发行授权连续完成：创建 `$LT_TAG` 指向 `$LT_SOURCE_COMMIT` 的 **LyricTile 专属 Release**，上传最终 ZIP、DMG、`SHA256SUMS` 和准确支持范围；公开后重新下载核对哈希，再更新开发分支 `Products/LyricTile/Updates/appcast.xml` 与官网 `main:website/lyrictile/release.json`。官网 manifest 的 `published`、`version`、`build`、`commit`、`downloadURL`、`releaseURL`、`sha256` 必须对应本次最终 DMG，并同步产品分支的 `Website/release.json`。保留 HOLDSNOW 产品页和中英文说明。不要使用仓库通用 `releases/latest`，也不要将历史 build 4 草稿改名冒充新版。

最后在开发分支提交一份简短 `Documentation/Verification/local-release-YYYY-MM-DD.md` 并更新 `STATUS.md` / PR #17：准确源码与构建号、包哈希、公证回执 ID、实际补验和 4→最终版本升级结果、最终下载/feed/官网地址、真实支持范围。私人曲目轨迹留本机。若缺少的仅是不可用凭据或必需的一次系统授权，汇总为一个明确阻塞，保留完整待发布包；不宣称已签名、公证或公开。
