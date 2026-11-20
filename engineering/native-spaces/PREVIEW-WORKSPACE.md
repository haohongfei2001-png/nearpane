# 安装版窗口预览与系统桌面验收

`preview-workspace.py` 使用正式安装和现有资料隔离入口。在同一个会话内，它通过系统 Mission Control 选中自己创建的普通桌面，然后运行[双窗独立像素与延迟验收](PAIRED-PREVIEW.md)。只有显式传入 `--system-switch` 才增加第二个临时普通桌面。

```sh
src="$PWD/scripts/acceptance/native-spaces"
kit=$("$src/build-paired-preview.sh")
"$src/build-split-view.sh" "$kit"
"$src/build-preview-overview.sh" "$kit"
python3 "$src/preview-workspace.py" "$kit" "$out/preflight" --preflight-only
python3 "$src/installed_profile.py" "$out/profile" -- \
  python3 "$src/preview-workspace.py" "$kit" "$out/native" --system-switch --hidden-budget \
  --split-command "$src/split-view.py" --media-command "$src/live-preview-media.py"
```

以上合并后的源码需要使用含 `stageManagerOwnsDispatch`、`deliveredFrames` 的现有 metrics 接收器（PR #15 的 `5720c84`）。同时使用同一 checkout 的 Split 与桌面工具，它们在本 checkout 的 `build/verification/secondary-route-followup` 下校验有主创建单。各输出目录均须是新的。

- 台前调度仅通过 Apple 系统设置的 `stage-manager-on` 总开关操作。两次独立的新进程从实际前台登录域读取布尔值。切换时再分别读取 Apple 签名设置进程内的可用 AX 控件，每次只允许一个已登记普通桌面、一个新设置窗口、一个开关以及一次 AXPress。已有用户设置窗口、输入竞争或浮层均会留下具体拒绝原因。关闭和恢复前后都写入独立收据，恢复在媒体整理之前执行。
- 同桌面两窗的实际颜色、同帧卡片更新和保守时延区间写入 `preview/result.json`。`originalStageSurface`、`offZeroBefore`、`offTwo`、`offZeroAfter`、`restoredSurface` 只导出正式产品的固定工具标识、标题与卡数。已知确有画面后，预算合同使用同一对窗口、正式状态菜单和 60 秒七次读数。恢复时重新核对两张卡和持续增长的帧数。当前协议没有流启动累加计数，收据分别写出各采样点活跃流数、隐藏期间交付帧数与该缺项。
- `--system-switch` 将 A 上两个窗口的 PID、出生时间和原生编号固定。系统正常选择空 B 后，两轮独立的实际窗口正向与反向归属、正式 Host 卡数和工具状态均写入 `system-switch/result.json`。稳定系统 B 出现旧卡的样本即便后来归零也保留为失败。再回 A 核对同一对窗口及卡片。真实三指输入仍单列 `NOT_RUN`。
- Split 在当前租约下最新的已证空桌面进行。它有独立的系统布局、正式 Host 和清理收据。只有完全均匀、属于测试色且有双边 AX 身份证明的像素块才可保存，额外的可读截图由单独的受限捕获器准入。离线媒体整理失败不会阻断台前调度与日常桌面的恢复。
- `workspaceCleanup` 与 `returnedDailySpace` 使用独立系统观测核对临时桌面回收、原桌面 UUID 和焦点。实际正常安装的资料和日常配置另见 `profile/profile-session.json`。原生台前调度的缩略图延迟在此合同为 `NOT_MEASURED`。
