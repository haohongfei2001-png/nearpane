# 本地 Alpha 与公开发行的边界

**适用范围：日常 Alpha 的发布与既有安装记录。** 当前独立台前调度候选使用不同的应用身份与资料目录；其完整构建、Finder 入口和验收见[独立候选说明](../scripts/acceptance/independent-stage/README.md)。下述日常安装流程不意味着候选已获产品资格，也不随候选提交自动替换已安装版本。产品与技术路线以[现行裁决](../engineering/research/NEARPANE-INDEPENDENT-STAGE-DECISION.md)为准。

个人 Alpha 默认安装到 `/Applications/Nearpane.app`。已有个人目录安装且系统目录无同名应用时，更新沿用个人目录；首次安装遇系统目录不可写时也使用个人目录。应用标识为 `com.holdsnow.nearpane.alpha`。更新时正常退出正在运行的 Nearpane，使用 `scripts/build-candidate.sh` 将新包原子替换至原安装路径。安装与导出统一生成 `Nearpane.app`，默认选择 Nearpane 团队的 Developer ID Application 证书。若本机有多张匹配证书，通过 `NEARPANE_LOCAL_SIGNING_IDENTITY` 指定指纹。首次导出也要校验 Host 和助手的权限身份，覆盖已有正式包时还要双向验证签名要求。默认安装的包收据为 `build/candidate/package.json`。日常开发使用 `scripts/test.sh` 和 `scripts/build-app.sh`，开发包使用独立的 `com.holdsnow.nearpane.host` 标识。独立验收可用 `NEARPANE_CANDIDATE_OUTPUT` 指定临时目录，验收结束后保留所需的归档与收据，并清理该次临时 App。各版沿用资料格式 1 和单写锁。[Alpha 使用帮助](ALPHA-HELP.md)

用户安装当前 Alpha 时只需完整的 App。窗口管理和资料导入共用签封在包内的 NearpaneAutomation。用于维护本仓库的构建工具仍在开发机上运行。为最终包验证运行环境时可从终端执行 `"<Alpha.app>/Contents/MacOS/NearpaneHost" --check-helper-runtime`。首次构建所用的 CPython 来源和 SHA-256 见[运行环境来源锁](../Dependencies/automation-runtime.json)。

P5.9 增加 Nearpane 独立反馈记录及应用内更新入口。反馈本机库位于稳定资料容器的 `Feedback` 目录，处于各个 `generations` 之外，资料导入与回退保留反馈草稿和原回执。更新框架固定在[更新来源锁](../Dependencies/update-runtime.json)，安装包内各二进制的实际数量及指纹见当次包收据。Nearpane 签名发布通道就绪后才允许联网检查，所需发布配置及安装边界见[应用内更新](APPLICATION-UPDATES.md)。

交付前在本机对冻结的 Alpha 运行以下离线检查。

- `python3 scripts/check-alpha-distribution.py "<Alpha.app>"`。核对完整 bundle seal、所有 Mach-O 的 arm64 slice 与系统版本下限。对实际将交给用户的 App 加上 `--require-install-identity`，校验其跨版本权限身份。增加 `--require-distribution-signatures` 时，本地临时签名必须以状态 2 拒绝。成功核对本地签名不是公证。
- `python3 scripts/rehearse-alpha-signing.py "<Alpha.app>"`。在临时副本上从内向外签署各助手和应用，更新内嵌指纹，再复核签名及输入原件。演练只使用本地临时签名。

真正发行前需要受权的 Developer ID、正式 entitlement 及 TCC 责任主体复核、所有嵌套代码的一致签名和时间戳、公证票据与附票校验。需要在干净系统上确认：不装开发工具时可运行的范围；已授权功能所需解释和撤销；资料、Keychain、辅助功能身份和旧版回退。当前 Apple Silicon Alpha 的完整集成部署下限为 macOS 26；本轮原生验收仅覆盖本机 build，不代表所有 26/27 版本。没有对普通窗口跨设备兼容性、整机续航或公开发行作出验收结论。

参考：[Apple 关于 macOS 分发前公证的要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 5.22（90）私有公证准备与恢复

从最终集成的干净工作树生成私有分发包。使用独立工作树、实验助手缓存和导出目录；保留现有 Developer ID 和嵌套签名的安全时间戳。

```sh
private_stage=$(mktemp -d /private/tmp/nearpane-p6.XXXXXXXX)
revision=$(git rev-parse HEAD)
NEARPANE_FROZEN_SOURCE=1 NEARPANE_SIGNING_MODE=distribution NEARPANE_RUN_ID="p6-${revision:0:12}" \
NEARPANE_CANDIDATE_OUTPUT="$private_stage/export" NEARPANE_LAB_APP_CACHE="$private_stage/lab" scripts/build-candidate.sh
python3 scripts/private_notary.py prepare "$private_stage/export/Nearpane.app" "$private_stage/session" --source "$revision"
python3 scripts/private_notary.py verify "$private_stage/session"
```

已有分发 ZIP 时向 `prepare` 传入该文件和可信收据的 `--sha256`。准备工具保留原始 ZIP 字节，按产品签名清单逐一查验可执行对象的签名（带 WindowEngine 的 5.22 包含 Guardian，共 14 项）、每个架构的 CDHash 和安全时间戳，验证助手/资源指纹，再从归档独立解包读回。输入就绪收据为 `session/prepared.json`。用旧分发 ZIP 在私有目录内演练原子切换与回退可执行 `python3 scripts/private_notary.py rollback-check "$private_stage/session" "$old_zip" --source "$old_revision" --sha256 "$old_sha256"`。

向 Apple 交付需要独立授权。以下命令供届时使用；首次提交前创建唯一请求目录，使同一会话的重复执行停在上传之前。凭证通过本机明确选定的 Nearpane Keychain profile 使用。就绪收据中的文件名和 SHA-256 必须与交付对象一致。

```sh
session="$private_stage/session"
archive=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["archive"])' "$session/prepared.json")
(
  set -eu
  umask 077
  : "${NEARPANE_NOTARY_KEYCHAIN_PROFILE:?Designate the authorized Nearpane profile}"
  python3 scripts/private_notary.py verify "$session"
  mkdir "$session/request"
  xcrun notarytool submit "$session/$archive" --keychain-profile "$NEARPANE_NOTARY_KEYCHAIN_PROFILE" \
    --no-wait --output-format json > "$session/request/submission.json"
)
```

提交后使用原 UUID 取回服务状态。丢失响应时，保存上传意图、归档和 SHA-256，先向服务核实原作业身份；身份仍无法确认时保持 UNKNOWN。服务处理中的状态可重复读取。工具不会自动提交新作业。

```sh
request="$session/request"
job=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$request/submission.json")
xcrun notarytool info "$job" --keychain-profile "$NEARPANE_NOTARY_KEYCHAIN_PROFILE" --output-format json > "$request/info.json"
python3 scripts/private_notary.py reconcile "$session" --submission "$request/submission.json" --info "$request/info.json"
```

服务处理结束后取得同一作业日志。拒绝原因保留在私有日志中。对于已获接受且日志证实归档哈希和所有架构的 CDHash 的作业，在私有副本附票并复验最终 ZIP。

```sh
xcrun notarytool log "$job" --keychain-profile "$NEARPANE_NOTARY_KEYCHAIN_PROFILE" "$request/developer-log.json"
python3 scripts/private_notary.py reconcile "$session" --submission "$request/submission.json" --info "$request/info.json" --log "$request/developer-log.json"
python3 scripts/private_notary.py finalize "$session" --submission "$request/submission.json" --info "$request/info.json" --log "$request/developer-log.json"
```

成功收据 `stapled/result.json` 包含服务 UUID、提交 ZIP 的哈希和最终附票 ZIP 的独立哈希。最终 ZIP 解包后须再次通过 `stapler validate`、`spctl` 和 `syspolicy_check distribution`。同一请求可重新验证已经完成的附票工件，失败保留输入和 `last-finalize-failure.json`。干净 macOS 26/27 的首次安装、权限与资料恢复、Sparkle 签名更新和正式产品能力分别需要实机收据。[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
