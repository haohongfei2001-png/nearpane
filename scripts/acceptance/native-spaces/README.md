# Installed sidebar witness

Run from the implementation checkout on the Mac with the installed candidate already running in its normal login session. Each output directory must be new. This developer-side procedure requires Xcode command line tools and Python; it adds no runtime dependency to Nearpane.

```sh
scripts/acceptance/native-spaces/run.sh preflight build/verification/space-preflight-01
scripts/acceptance/native-spaces/run.sh candidate build/verification/space-candidate-01
python3 -m unittest discover -s scripts/acceptance/native-spaces
```

Preflight loads the installed code identity, independently samples WindowServer and the accessibility tree twice, and reads the installed Host's own permission and capability log. Observer permissions are recorded separately. No action helper is invoked by the witness.

The candidate batch runs four scenarios serially. Each name also works as an individual command.

- `single-window` and `controlled-window` start a disposable regular document fixture with one or two windows. The only selection action is AXPress on the installed sidebar control for the live fixture identity. Exact key/main, AX focus, process birth, membership and synthetic editor content are independent evidence. A marker is addressed only to the test PID after focus confirmation. Both document digests must match the expected edit. The run stops on the first discrepancy and the fixture closes its own windows.
- `title-image` binds the current row's accessibility frame to an on-screen Nearpane window. A ScreenCaptureKit display filter includes only that window. The source rectangle samples a 60 × 17 pt title inside the region above the miniatures, with geometry checked again after capture. The image is a still of the row title only.
- `hidden-budget` uses the installed app's own status menu. After two seconds hidden, it records counters every ten seconds for a further minute and restores the sidebar it hid. A zero count with the Host's screen permission denied has limited coverage.

`fixture-inventory` runs one additional read-only diagnostic. It creates one ordinary document fixture and compares only that process’s AppKit number, AX roles/numbers and layer-zero CG metadata. It never presses a sidebar control or sends keyboard input.

Each scenario produces an immutable manifest, an action journal and per-scenario results. An issued click without the intended external result stays failed or unknown. A completed fixture subtest does not grant W01/W03 real-application compatibility, nor S02/D01/N01 acceptance. A disabled production Space row, missing hardware or absent grants must be reported explicitly; switching from a different privileged program would invalidate the run.
