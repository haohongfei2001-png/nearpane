# Installed sidebar witness

## 正式侧栏合同

从仓库根目录运行下列命令。每项使用新证据目录。在正常 Launch Services 入口启动正式安装版，`installed_profile.py` 验证独占测试资料锁并在结束后恢复日常配置。核心合同经系统 Mission Control 创建普通 A/B/C，保存创建与移除的 UUID 收据。正式 Space 行、Apple TextEdit 或受控文档、独立 WindowServer 及键盘输入分别记录在 actions.jsonl。

```sh
python3 scripts/acceptance/native-spaces/installed_profile.py "$out/profile" -- \
  python3 scripts/acceptance/native-spaces/acceptance.py core-contract "$out/core" \
  --scenarios S01,S02,S03,W01,W02,D01,R01 --performance
python3 scripts/acceptance/native-spaces/acceptance.py cleanup-contract "$out/core"
```

`same-space-documents OUTPUT` 可在一个普通桌面单独执行同应用精确选窗。`run-lifecycle.sh` 使用同一个测试资料入口验证原生全屏、平铺与重启。`r4-voice-cold.py --file-readback` 在每次全新 Host 中核对真实麦克风首句和音频文件。[翻译、截图、单词本与官方草稿](TOOL-TRIALS.md)

## R4 安装版

`run.sh roster <新目录>` 在本屏建立横宽和高窄两扇测试窗，逐一核对正式侧栏身份、独立等比图槽和纵向滚动区。在安装进程具备录屏权限时再比对卡片像素。`r4-scene.swift` 使用 ScreenCaptureKit 仅纳入系统桌面层、两扇登记的测试窗及安装侧栏，把台前调度对测试窗的实际呈现保存在同一画面中。

材质和布局的验收器是独立的命令行工具。各 Swift 文件使用 `xcrun swiftc -parse-as-library` 单独编译。`r4-wallpaper.swift` 采集当前壁纸与 Apple 壁纸样本，`r4-optics.py <采集目录>` 用 Pillow 对蓝黄两次实拍按相同坐标测量。`r4-foreground.py <默认目录> <调节目录> [--dark]` 比较同一壁纸上四处笔画的同坐标像素。`r4-appearance.swift` 通过正式设置切换工具与宽度，结束时复原。`r4-file-drag.swift` 建立真实的 AppKit 拖放来源与接收窗口。`r4-voice.swift` 需要一份绑定当前安装进程的空白验收配置和本地测试音频，由正式侧栏开始和暂停收音。[运行条件、结果与公开截图](../../../engineering/verification/native-spaces/5.22-90-r4/RESULTS.md)

## 本屏逐窗画面验收

使用已安装的 Nearpane 助手和当前 checkout 的独立 Host 调试模块。首次使用可运行 `NEARPANE_FOUNDATION_ONLY=1 scripts/test.sh` 准备模块，再执行以下单次验收。

```sh
python3 scripts/acceptance/run-current-desktop-selection.py
```

默认场景使用普通文档。用 `all-spaces-documents` 核对四种自建文档窗口的画面、真实宽高比以及关闭和撤下后的剩余集合。用 `public-roster` 检查同应用普通层级辅助面板的排除。系统台前调度可能只提供缩小后的呈现区域或拒绝单窗取图，验收会保留结果。

`mixed-roles` 同时建立普通文档与同进程辅助面板。它只对自建窗口比对拥有者和外部 AX 的身份、角色，以及当前公开呈现、最终清单和侧栏实拍。普通文档须列出且有对应画面，辅助面板须排除。即使读取器报告全局 AX 信息不完整，该用例也保存上述逐窗证据。

正式安装版运行时，`scripts/acceptance/native-spaces/run.sh compare-roster <新目录>` 会把正式卡片集合与独立系统观察中的普通窗口比对，分别报告多画、漏画、重复和未核实的数量。该比对不采集窗口标题或像素。`current-sidebar` 另外检查正式权限引导、合成文档卡片和精确选窗。

隔离窗口清单通过 Launch Services 以后台方式打开两个身份核对过的测试包，并记录前台是否保持。这个入口在私有临时目录构建两款窗口夹具和一个隔离控制器，独立验证已登记窗口的内容、比例及增减。成功或失败均会输出本次证据目录，保留日志和已生成的 JSON、局部实拍。夹具退出后按路径注销并删除。确需只编译而不执行时，仍可调用 `build-current-desktop-selection.sh`；使用者负责该目录和 Launch Services 注册的清理。正式安装版侧栏的只读测量使用 `scripts/acceptance/native-spaces/run.sh roster <新的证据目录>`。

Run from the implementation checkout on the Mac with the installed candidate already running in its normal login session. Each output directory must be new. This developer-side procedure requires Xcode command line tools and Python; it adds no runtime dependency to Nearpane.

```sh
scripts/acceptance/native-spaces/run.sh preflight build/verification/space-preflight-01
scripts/acceptance/native-spaces/run.sh candidate build/verification/space-candidate-01
python3 -m unittest discover -s scripts/acceptance/native-spaces
```

Preflight loads the installed code identity, independently samples WindowServer and the accessibility tree twice, and reads the installed Host's own permission and capability log. Observer permissions are recorded separately. No action helper is invoked by the witness.

The candidate batch freezes a read-only preflight, then runs four scenarios serially. Each name also works as an individual command.

- `single-window` and `controlled-window` start a disposable regular document fixture with one or two windows. The only selection action is AXPress on the installed sidebar control for the live fixture identity. Exact key/main, AX focus, process birth, membership and synthetic editor content are independent evidence. A marker is addressed only to the test PID after focus confirmation. Both document digests must match the expected edit. The run stops on the first discrepancy and the fixture closes its own windows.
- `title-image` binds the current row's accessibility frame to an on-screen Nearpane window. A ScreenCaptureKit display filter includes only that window. The source rectangle samples a 60 × 17 pt title inside the region above the miniatures, with geometry checked again after capture. The image is a still of the row title only.
- `hidden-budget` uses the installed app's own status menu. After two seconds hidden, it records counters every ten seconds for a further minute and restores the sidebar it hid. A zero count with the Host's screen permission denied has limited coverage.

`fixture-inventory` runs one additional read-only diagnostic. It creates one ordinary document fixture and compares only that process’s AppKit number, AX roles/numbers and layer-zero CG metadata. It never presses a sidebar control or sends keyboard input.

Each scenario produces an immutable manifest, an action journal and per-scenario results. An issued click without the intended external result stays failed or unknown. A completed fixture subtest does not grant W01/W03 real-application compatibility, nor S02/D01/N01 acceptance. A disabled production Space row, missing hardware or absent grants must be reported explicitly; switching from a different privileged program would invalidate the run.

`retained-selections.py KIT LEDGER_ROOT OUTPUT A.json B.json C.json` 可在同一测试会话的三个现存租用桌面上单独诊断正式行按钮。它检查每个创建回执的哈希、启动会话、显示器、Space ID 与 UUID，并从正式 Host 取行及回读 WindowServer。可进入的起点为租用桌面或当前确由自建文档持有的焦点。此诊断单独计数，完整 S02 由 `core-contract` 验证。
