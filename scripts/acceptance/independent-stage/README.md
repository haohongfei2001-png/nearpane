# Independent Stage acceptance

This entry builds and tests the independent hidden-Space replacement. It never
selects Corner, paints a wallpaper cover, blocks pointer events, or enables Apple's
Stage Manager. The daily installation and its profile are not opened or replaced.

## One entry

From a clean checkout on a macOS console:

```sh
python3 -B scripts/acceptance/independent-stage/run.py /private/tmp/nearpane-independent-01 --scope all --product-host /path/to/built/Nearpane.app --iterations 3
```

`OUTPUT` must not already exist. `--iterations` accepts 1–50. The default is three
complete A→B→C→A engine cycles; increase it only after one complete cycle and
cleanup are confirmed. `--scope source` has no window operations. `--scope runtime`
reuses the source revision and builds a fresh production Rust archive unless
`--archive PATH` supplies one. Existing accessibility and screen-recording access
are observed; this entry does not alter TCC or submit permission dialogs.

`NP_ENGINE_FIXTURE_SIGN_IDENTITY` optionally selects an existing signing identity.
Without it the three test apps and copied product candidate use ad-hoc development
signatures. The product copy has identifier
`com.holdsnow.nearpane.independent-stage-candidate`; the originals remain intact.
Its `NEARPANE_SPACES_CANDIDATE_PIDS` value contains only this invocation's two
fresh fixture PIDs, and its Swift runner additionally verifies their process birth,
executable path, signing digest and window identities.

## What actually runs

1. Rust tests, relevant Swift Core/Host/UI tests and evidence classification tests.
2. Fixture A creates two real ordinary windows. Fixture B creates one. Their PIDs
   differ from the controller. They service commands only for their own windows.
3. The controller calls `np_engine_create_spaces_candidate`, then `NP_LAUNCH`.
   The launch canary is recorded separately as **controller-owned evidence**.
4. `NP_HIDE` and `NP_RESTORE` operate on the foreign windows. Every transition is
   independently checked twice: window→Space membership, Space→window membership,
   process birth/path, CG on-screen presence, geometry, same-app sibling and the
   other-app bystander. No effect is inferred from a successful API return.
5. Same-app independent scheduling, cross-app visible combinations and repeated
   A→B→C→A cycles use the candidate engine. The real yellow button is followed by
   `NP_HIDE_MINIMIZED`, an off-screen membership check, a non-minimized owner
   witness while hidden, and exact restoration.
6. If a product bundle was supplied, its isolated copy opens the actual R4
   `EdgePanel`, `DesktopSurface`, `CurrentDesktopWindows` and
   `StageWindowEngineHost`. The runner locates the production accessibility
   buttons, presses them, and verifies physical foreign-window membership,
   geometry and exact AX focus. It never substitutes a direct engine call for a
   reported R4 click. Real R4 renders are saved as `r4-N.png`.
7. The product runner exercises the yellow-button observer and held-card restore,
   Mission Control, native full-screen entry/return, an existing adjacent ordinary
   desktop through the system Control-arrow action, and App Exposé. Missing system
   prerequisites are reported independently. A synthetic system desktop action is
   **not** reported as a physical three-finger gesture. Native Split View is not
   claimed by these initial runtime receipts.
8. `NP_RELEASE_SPACES` and the production shutdown path return owned windows before
   destroying empty Spaces. The runner closes only the two direct fixture children.
   Original foreground restoration is attempted only while a test app still owns
   the foreground. The product candidate profile stays in the output folder.

## Evidence and interpretation

`summary.json` preserves source, candidate-engine and product results separately.
`runtime/engine.log` contains each engine receipt and independent system readback;
`runtime/engine-result.json` is the final engine result. `runtime/product/product-result.json`
contains actual R4 input counts, system observations, cleanup and remaining tests.
Both original failures and final cleanup survive in the journal.

`FOREIGN_ENGINE_PASS` proves only the stated candidate-engine foreign-window
sequence on the recorded host. `PRODUCT_R4_PASS` additionally requires actual
production R4 presses and physical readback. Exact-target results require
macOS build **26A428** and **SIP Enabled**. Another runner build or SIP Disabled may
provide useful mechanism evidence but does not satisfy that target. None of these
receipts automatically inserts a release qualification or changes the shipped
qualification table.

The historical `9509bd0` self-panel success is retained at
`engineering/verification/window-engine/single-version-26A428/11-formal-panel-cycle.json`.
The same series explicitly reports **zero foreign operations** where single-instance,
startup-only or overview admission prevented the foreign test. Those records are
`NOT_RUN`, not a WindowServer mechanism failure. This entry uses independent fixture
and controller identities to remove that unrelated admission dependency.

## CI

`.github/workflows/independent-stage.yml` runs on the independent development branch.
It compiles the candidate engine, source checks, full application with embedded
tools, cross-process fixture and native-decoupling diagnostic, then uploads the
candidate archive and original receipts. A source failure or an attempted behavior
failure fails the job. A genuinely unavailable console is retained as `BLOCKED`,
so a green compile cannot be read as foreign-window or product acceptance.
