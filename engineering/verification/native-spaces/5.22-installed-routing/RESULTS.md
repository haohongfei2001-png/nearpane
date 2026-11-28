# 独立候选与正式系统入口

2026-11-21 的两次只读核验都显示，当前用户的 Launch Services 和翻译服务唯一指向 `/Applications/Nearpane.app`。该签名 Host 为 5.22（90）、源码 `d2d0bb6`。其确切 PID 持有日常资料锁，未打包此次 P3 的无提示 AppleEvents 探针或 P4 的请求绑定面板。一个独立临时目录中的真实签名归档通过同一套团队、指定要求、源码及 CDHash 检查，系统选择的仍是原 Host。两次核验均为零启动、零 Services 请求、零系统输入。[日常路径收据](routing.json) · [独立签名副本收据](staged-routing.json)

## 只读复查

在 PR #15 的干净原生工作树，既有 `NEARPANE_CANDIDATE_OUTPUT` 可保存签名候选到独立目录。若已有签名候选，直接指定其真实绝对路径。预检核对打包身份、当前进程内核 PID 与出生时间、运行 CDHash、Launch Services 和系统服务实际选择的路径。已有验收会话中可另传 `--home "$NEARPANE_TEST_HOME"` 读取该 Host 的隔离 writer.lock。预检只把满足条件的入口标为可供下一步运行。AppleEvents 授权及服务实际送达各有独立收据。

```sh
REV=$(git rev-parse HEAD)
STAGE=$(mktemp -d /private/tmp/nearpane-private-candidate.XXXXXXXX)
NEARPANE_FROZEN_SOURCE=1 NEARPANE_CANDIDATE_OUTPUT="$STAGE" scripts/build-candidate.sh
python3 scripts/acceptance/native-spaces/installed-route.py --app "$STAGE/Nearpane.app" --expected-source "$REV"
```

当前同用户会话只有一个注册 Host。两份候选的 bundle ID、指定签名要求与 `LSMultipleInstancesProhibited` 均相同。P3 现有真机探针、P4 现有 Services 夹具、P0 的独立观察器核验的是 `/Applications/Nearpane.app`。静态候选可在另一目录检验；实际 P3/P4 可在专用 macOS 环境让同一签名版本占用该正式路径，或在获准正常安装的对应版本上运行。下列命令供该环境使用。两个会话各自创建新的空白资料并恢复原 Host。

```sh
REV=$(git rev-parse HEAD)
RUN=$(mktemp -d /private/tmp/nearpane-services-qualification.XXXXXXXX)
TOOLS=scripts/acceptance/native-spaces
"$TOOLS/build-tool-trials.sh" "$RUN/kit"
xcrun swiftc "$TOOLS/metrics.swift" -o "$RUN/kit/metrics"
python3 "$TOOLS/installed_profile.py" "$RUN/p3-profile" -- python3 "$TOOLS/p3-installed-qualification.py" \
  --expected-source "$REV" --metrics "$RUN/kit/metrics" --output "$RUN/p3.json"
python3 "$TOOLS/installed_profile.py" "$RUN/p4-profile" -- python3 "$TOOLS/p4-service-cycle.py" \
  "$RUN/kit" "$RUN/p4" --expected-source "$REV"
```

## 当前 P0 控件

当前已签 `d2d0bb6` 与复核提交 `b27f651` 中，相关正式视图源码相同。验收器要求 `native-space-window:<display>:<space>:<pid>:<number>`。正式程序里此 AXID 在 `NativeWindowGroupCard.miniature`，唯一构造点传入 `isCurrent: true` 及当前桌面的 `member.source`。普通卡点击走当前窗口选择，原生 Split View 也只显示本屏当前配对。非当前桌面成员模型仅被审计读取。这两版无可从正式侧栏点击的已绑定异桌面目标。P0 单次操作保持未投递。[视图入口](../../../../Sources/NearpaneUI/DesktopSurface.swift) · [分组控件](../../../../Sources/NearpaneUI/NativeSpaceNavigator.swift) · [正式控件匹配](../../../../scripts/acceptance/native-spaces/p0-card.swift)
