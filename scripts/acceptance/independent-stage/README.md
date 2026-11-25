# Independent Stage acceptance

This entry builds and tests the independent hidden-Space replacement. It never
selects Corner, paints a wallpaper cover, blocks pointer events, or enables Apple's
Stage Manager. The daily installation and its profile are not opened or replaced.

## One entry

From a clean checkout on a macOS console:

```sh
python3 -B scripts/acceptance/independent-stage/run.py /private/tmp/nearpane-independent-01 --scope all --iterations 3
```

`OUTPUT` must not already exist. `--iterations` accepts 1–50. The default is three
complete A→B→C→A engine cycles; increase it only after one complete cycle and
cleanup are confirmed. The `all` scope runs source checks, builds the complete
release application, packages a signed interactive workspace candidate under
`OUTPUT/candidate`, and tests its separate PID-scoped acceptance copy. Supplying
`--product-host /path/to/built/Nearpane.app` reuses an existing complete application.
A failed source check prevents a candidate PASS but still permits the independent
engine experiment and cleanup to produce useful evidence. `--scope source` has no
window operations. `--scope runtime`
reuses the source revision and builds a fresh production Rust archive unless
`--archive PATH` supplies one; it runs the product only when `--product-host` is
explicitly supplied. Existing accessibility and screen-recording access
are observed; this entry does not alter TCC or submit permission dialogs.

`NP_ENGINE_FIXTURE_SIGN_IDENTITY` optionally selects an existing signing identity.
Without it the three test apps and copied product candidate use ad-hoc development
signatures. The product copy has identifier
`com.holdsnow.nearpane.independent-stage-candidate`; the originals remain intact.
The acceptance copy's `NEARPANE_SPACES_CANDIDATE_PIDS` value contains only this invocation's two
fresh fixture PIDs, and its Swift runner additionally verifies their process birth,
executable path, signing digest and window identities.

The full interactive candidate is packaged separately and retains the complete R4
workbench and embedded tools:

```sh
python3 -B scripts/acceptance/independent-stage/package.py /path/to/built/Nearpane.app /path/to/new/NearpaneIndependentStage.app --revision COMMIT_SHA --mode workspace
```

This creates and verifies the signed bundle without opening or installing it.
The input must be a complete application built from the exact clean revision in
`--revision`; an older binary is rejected instead of being relabeled as new code.
When the donor is the raw `build-app.sh` output, packaging adds the existing
profile/window tools and pinned private Python runtime with
`build-helper-runtime.py`. A donor's existing runtime is reused only after all
five sealed files pass their recorded SHA-256 checks. The candidate preserves the
Host's existing audio-input and Apple-event entitlements; these do not grant
system privacy access.

## Interactive workspace candidate

Double-click the produced `NearpaneIndependentStage.app` in Finder, or open that
exact bundle:

```sh
open /path/to/new/NearpaneIndependentStage.app
```

For `--scope all`, this bundle is under
`OUTPUT/candidate/NearpaneIndependentStage.app`. No special command-line argument
or fixture PID environment variable is required. The `workspace` marker starts
the normal `HostAppDelegate`, R4 surface, window catalogue and independent engine;
choosing a group in R4 starts scheduling the real windows. Native Stage Manager
must be off. The candidate uses its own bundle/signing identity and can launch
from this output directory; it does not require the daily application's canonical
installation path. Accessibility and screen-recording access must apply to this
candidate identity. The package does not change TCC or inherit a different app's
permission by claiming its identity.

Click a thumbnail to select its group and restore the selected real window's
focus. A held card's context menu can add that group to the current group; the
member menu can detach an individual window. Editing first returns owned windows
to their original ordinary desktop, applies the existing group model operation,
then activates the result. The group's member picker selects an exact window,
including multiple windows from the same application.

The workspace uses a separate profile at:

```text
~/Library/Application Support/Nearpane Independent Stage/Nearpane Independent Stage Profiles/generations/<UUID>/
```

Its Host, groups and notebook use the generation's `Nearpane/` directory, voice
uses `Nearpane/Voice/`, and the screenshot/file library uses `Riftlet/`. It retains
the existing `EmbeddedModules` for voice, screenshot/file tools, notes and tasks,
including their bundled resources. The candidate does not start the legacy
automatic-tiling supervisor, automatic updater or the daily translation Service.
Bundle verification establishes that these modules and their resources are
present; the independent-stage acceptance does not claim to have exercised every
recording, transcription, attachment or profile-import workflow.

The acceptance runner always requests `mode="acceptance"`, keeps its exact
fixture-PID restriction and output-local profile, and cannot be mistaken for the
unrestricted interactive workspace. CI archives the workspace candidate and runs
the separate acceptance copy only against its newly created fixture apps. Both
copies carry the independent candidate identifier; finish the automated run and
let its app exit before opening the interactive copy.

## What actually runs

1. Rust tests, the production Rust archive, the native Spaces worker's C build and
   `--protocol-selftest`, relevant Swift Core/Host/UI tests and evidence
   classification tests. Source checks reuse the resulting archive for Swift.
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
7. The product runner merges the other app's held group into the current group
   through the production context-menu handler, then presses actual R4 buttons to
   retire/restore both members and precisely focus the second app's member. It
   detaches that member through the same production handler used by the menu and
   verifies that all three independent groups and their original frames survive.
   Handler invocation is recorded explicitly; it does not claim a physical drag
   or an accessibility press of the context menu itself.
8. The product runner exercises the yellow-button observer and held-card restore,
   Mission Control, native full-screen entry/return, an existing adjacent ordinary
   desktop through the system Control-arrow action, and App Exposé. Missing system
   prerequisites are reported independently. A synthetic system desktop action is
   **not** reported as a physical three-finger gesture. The separate Split View
   adapter described below uses the real system menu and authenticated picker;
   the product result records its physical membership/layout checks separately.
9. `NP_RELEASE_SPACES` and the production shutdown path return owned windows before
   destroying empty Spaces. The runner closes only the two direct fixture children.
   Original foreground restoration is attempted only while a test app still owns
   the foreground. The product candidate profile stays in the output folder.
10. After the normal product path and cleanup succeed, the runner launches a
    separate fixture-scoped `hostCrash` pass. It kills only its own direct Host
    child. The Spaces worker must return the original windows after channel loss;
    an independent controller checks original Space membership, frames, CG
    presence and the original Space inventory twice. Worker JSONL diagnostics
    and `hostCrashRecovery` remain separate from the normal shutdown result.

### Native desktop reveal and Split View

Clicking blank wallpaper pauses independent scheduling while retaining the real
hidden Spaces. The runner uses a synthetic click only after the production
wallpaper monitor's AX/CG hit test confirms a blank desktop location. It verifies
that the active window has actually yielded its screen area to the desktop and
that the other groups remain in exactly the same private Spaces. On return it
waits for fresh native ordinary-state and physical window reads. If the system's
wallpaper preference does not reveal the desktop, that native behavior is
`BLOCKED`; invoking the shared production handler alone cannot establish it.
Mission Control, App Exposé and switching ordinary desktops retain their separate
return-all-windows and resume behavior.

`SplitViewHelper`, built beside `FixtureA.app`, accepts one JSON object on stdin:

```json
{"operation":"tile","fixturePID":123,"fixtureBirth":456,"fixtureExecutable":"/path/to/FixtureA.app/Contents/MacOS/FixtureA","nonce":"00000000-0000-4000-8000-000000000001","numbers":[101,102],"home":3}
```

`tile` presses the uniquely identified native Full Screen → Left menu for the
already-focused first fixture window. `pair` reuses the existing signed system
picker reader and exact nonce marker to choose the second window. Each call
rechecks process birth, executable/signature, original AX window identity,
forward/reverse Space membership, foreground ownership and absence of competing
user input. The helper never activates itself or writes Space membership. It
returns `ISSUED` with the AX result or synthetic picker input, `OBSERVED` with
`alreadyTogether` when both fixture members already share the native full-screen
Space, or `BLOCKED` with a specific reason. An issued action is not a PASS; the
product runner must independently establish actual native Split View geometry,
Nearpane handoff and restoration. Unsupported menus, ambiguous selectors and
unconfirmed pointer hits do not trigger coordinate guessing.

## Evidence and interpretation

`summary.json` preserves source, candidate-engine and product results separately.
`runtime/engine.log` contains each engine receipt and independent system readback;
`runtime/engine-result.json` is the final engine result. `runtime/product/product-result.json`
contains actual R4 input counts, system observations, cleanup and remaining tests.
Both original failures and final cleanup survive in the journal.

The product's repeated R4 selections use the same `--iterations` value: three
cycles produce ten baseline thumbnail presses before the group-edit and system
interaction checks. Each successful press records `pressToDoubleReadMS`, from
the actual R4 press to two matching physical readbacks; the result includes
sample count, p50, p95 and maximum. `windowPreviewMetrics` is captured before
shutdown to retain thumbnail request/cache/stream counters. These observations
are reported as measurements, not as a performance acceptance threshold.

`FOREIGN_ENGINE_PASS` proves only the stated candidate-engine foreign-window
sequence on the recorded host. `PRODUCT_R4_PASS` additionally requires actual
production R4 presses and physical readback. Exact-target results require
macOS build **26A428** and **SIP Enabled**. Another runner build or SIP Disabled may
provide useful mechanism evidence but does not satisfy that target. None of these
receipts automatically inserts a release qualification or changes the shipped
qualification table.

On the disposable GitHub runner only, an initial Mission Control preparation
block first triggers verified restoration. Fresh fixture processes are then
created and the normal production controller reads the actual desktop again.
If the ordinary native UUID has become available, this can proceed through the
same engine and R4 paths. An earlier preparation block does not override newer
physical evidence.

If the normal controller still reports `BLOCKED`, zero foreign writes, and
confirmed cleanup, a separate `--platform-only` invocation may exercise the
shipping `np_stage_*` bridge atoms against those same fresh fixtures. It records
the boot, display and raw numeric desktop identity; it never supplies an invented
ordinary UUID to the product. It creates one real hidden Space and independently
hides/returns A0 and B0 while checking the sibling and other app as bystanders.
`runtime/platform-result.json` and `platformForeignMechanism` preserve this
limited `PLATFORM_FOREIGN_PASS` separately. It does not prove the production
state machine, R4 interaction, native UUID qualification, or target SIP behavior,
and cannot promote `engine`, `R4ProductPath`, or `overall`. Unconfirmed cleanup
prevents later product/system-input experiments. This diagnostic is not an
interactive product backend or an automatic product fallback.

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
failure fails the job. A missing runtime prerequisite is retained as `BLOCKED`,
so a green compile cannot be read as foreign-window or product acceptance.

After the independent-window work, CI always collects the read-only native
Stage Manager inventory. Only positively confirmed cleanup permits the two
sequential native edge experiments (`AutoHide` and zero strip rows). Each has
its own fresh directory, fixture lifetime checks and preference/pointer/focus
restoration. `INCONCLUSIVE`, `NOT_RUN` and `REJECTED_RENDERER_SEPARATION` remain
native diagnostic outcomes; no result grants a route-A qualification.

Each push starts two lanes of the same workflow on separate runners. The `full`
lane performs the complete source/build/package/R4 chain. The shorter
`diagnostics` lane builds the actual Rust archive and all runtime tools, then
runs the controlled window and native diagnostics without waiting for a complete
product build. It supplies no product Host and leaves source, candidate and R4
statuses `NOT_RUN`. Its explicit hosted-only environment marker keeps the
original native desktop: Mission Control preparation is not executed, and that
fact is recorded as `desktopPreparationExecuted: false`, zero native desktop
inputs and `workspaceUnchanged: true`. The normal controller still runs first;
only a real blocked, zero-write, cleaned receipt admits the separate platform
probe. This removes a product-UUID prerequisite from mechanism research without
changing the product's ordinary-desktop identity rules. Native edge experiments
still require independent engine/platform and fixture cleanup, plus either
verified workspace cleanup or this explicit record that no preparation ran.
They run only in this lane. Run IDs and
artifact names include the lane; the two processes never share a desktop
session. A manual dispatch with `diagnostics_only: true` selects just the shorter
lane when that interface is available.
