# Installed sidebar witness

## 本屏逐窗画面验收

使用已安装的 Nearpane 助手和当前 checkout 的独立 Host 调试模块。首次使用可运行 `NEARPANE_FOUNDATION_ONLY=1 scripts/test.sh` 准备模块，再执行以下单次验收。

```sh
python3 scripts/acceptance/run-current-desktop-selection.py
```

默认场景使用普通文档。用 `all-spaces-documents` 核对四种自建文档窗口的画面、真实宽高比以及关闭和撤下后的剩余集合。用 `public-roster` 检查同应用普通层级辅助面板的排除。系统台前调度可能只提供缩小后的呈现区域或拒绝单窗取图，验收会保留结果。

`mixed-roles` 同时建立普通文档与同进程辅助面板。它只对自建窗口比对拥有者和外部 AX 的身份、角色，以及当前公开呈现、最终清单和侧栏实拍。普通文档须列出且有对应画面，辅助面板须排除。即使读取器报告全局 AX 信息不完整，该用例也保存上述逐窗证据。

正式安装版运行时，`scripts/acceptance/native-spaces/run.sh compare-roster <新目录>` 会把正式卡片集合与独立系统观察中的普通窗口比对，分别报告多画、漏画、重复和未核实的数量。该比对不采集窗口标题或像素。`current-sidebar` 另外检查正式权限引导、合成文档卡片和精确选窗。

默认使用不激活的自建测试面板。这个入口在私有临时目录构建两款窗口夹具和一个隔离控制器，独立验证已登记窗口的内容、比例及增减。成功或失败均会输出本次证据目录，保留日志和已生成的 JSON、局部实拍。夹具退出后按路径注销并删除。确需只编译而不执行时，仍可调用 `build-current-desktop-selection.sh`；使用者负责该目录和 Launch Services 注册的清理。正式安装版侧栏的只读测量使用 `scripts/acceptance/native-spaces/run.sh roster <新的证据目录>`。

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
