# Route A: native engine / native renderer separation

Research and executable diagnostic, 2026-11-26. This directory is not a production backend.

## Decision

**Do not base Nearpane's production window scheduler on Apple's native integration.**
The reviewed interfaces control or observe Apple's existing stages and strip. No examined
source demonstrates all three of: disabling that renderer and edge reveal, retaining native
window scheduling, and independently controlling complete group membership. This is an
**unqualified route**, not a proof that private native separation is impossible.

The product requirement remains a complete replacement with only Nearpane's R4 thumbnails.
AutoHide, an empty AX list, offscreen thumbnails, zero-size rendering, covering native UI and
blocking pointer motion do not meet that requirement.

## Findings and source boundaries

| Source | What it demonstrates | What it does not demonstrate |
| --- | --- | --- |
| [Apple Mac User Guide](https://support.apple.com/guide/mac-help/organize-your-desktop-with-stage-manager-mchl534ba392/mac) | With recent apps hidden, moving to the screen edge reveals Apple's list again. Grouping uses the strip. | A supported replacement renderer or an independently disableable native strip. |
| [Upstream `strip_ax.rs`, v1.9.2](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/apple/strip_ax.rs) | `WindowManager` exposes `sm.space` → `sm.strip` → items carrying `AXWindowsIDs` and frames. The source records transient empty lists after changes and omits the active stage. | A complete authoritative group catalog, or control over rendering. |
| [Upstream `engine.rs`, v1.9.2](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/apple/engine.rs) | Apple mode is explicitly a null-hide engine: it leaves Apple's window scheduler and strip in charge. | Independent Nearpane hide/restore or renderer replacement. |
| [Upstream routes](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/apple/routes/mod.rs) and [rejected routes](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/apple/routes/rejected.rs) | Production integration uses focus, posted Shift-click and drag. The author records `AXPress`/`AXAddToStage` returning success without effect on macOS 27.2. | A verified direct group mutation API on the user's macOS 27.0. Return success alone is insufficient. |
| [Independent AX investigation](https://github.com/TheGuyWithoutH/mac-computer-use/blob/main/NOTES.md) | Reports `AXAddToStage` materialization in some observations and fallback to `AXPress`. | Stable behavior across OS builds. This conflicts with the upstream 27.2 observation, reinforcing the need for actual membership and focus readback. |
| [Preference discovery](https://gist.github.com/ejkarne/c73028e447d716b02063b0870c12c6be) | Documents historical `AutoHide`, `LeftStripMaximumRowCount` and geometry keys extracted from the system binary. | That these keys are still honored on 27.0, that zero rows disables rendering, or that scheduling survives. Later comments report versions where writes have no effect. |
| [Original log investigation, macOS 13.1](https://eclecticlight.co/2023/01/19/how-stage-manager-works-in-the-log/) | The author's logs show WindowManagement, SkyLight, Launch Services and RunningBoard collaborating; stage changes are integrated with Spaces. | Separation of daemon renderer from scheduler, current-build ABI or current-build permissions. |

The latest upstream checked is `19e6e490bc91e65cef6a782075b5450e3159fd2d`, release
[v1.9.2](https://github.com/eugene-tea/stage-manager/releases/tag/v1.9.2), published
2026-11-24. Earlier fixed research commit `69a73665488243bf78982c6d523ac4e0850c1ddb`
is v1.9.1. The Apple integration architecture above remains strip-dependent.

## Actual target inventory

The [2026-11-25 read-only target receipt](evidence/macos-27.0-26A428-inventory.json)
was collected remotely on **macOS 27.0 / 26A428, arm64, SIP enabled**. The three
frameworks loaded successfully and exposed 394 Objective-C runtime classes. Both bridged
Space-operation classes exist; they inherit the no-argument, void-returning
`performWithWMBridgeDelegate` from `SLSAsynchronousBridgedWindowManagementOperation`.
`WMClientWindowManager` exposes stage metadata and bridged-operation selectors.

The executable imports `StageManagerStripSystemGesture` show/hide directions and a layout
model containing both stage-enabled state and strip properties. The preference-controller
class is a Swift object with no directly enumerated Objective-C methods. These are concrete
ABI and architecture observations, **not** evidence of an independently disableable native
renderer. No private selector was invoked. Stage Manager remained disabled, and all three
observed preferences were identical before and after. The receipt deliberately excludes
the user's window inventory and records `capabilityProven: false`.

## Executable experiment

No extra Python packages are needed. Build requires Xcode command-line tools. Inventory can
run on a hosted macOS runner; an edge experiment needs a logged-in desktop. Permission
status is recorded, and unavailable Accessibility or screenshot access produces incomplete
evidence rather than a passing result. The program does not request TCC prompts.

```sh
python3 tools/native-stage-decoupling/run.py inventory
python3 tools/native-stage-decoupling/run.py edge-sweep --enable-native --autohide
python3 tools/native-stage-decoupling/run.py edge-sweep --enable-native --zero-rows
```

The second command is a negative control for Apple's documented AutoHide behavior. The
third tests a historically observed preference with no assumption that it works. A value
read back from preferences only proves the value was stored, not that WindowManager used it.

Each run creates its own `/tmp/nearpane-route-a-*` directory. `--output` may instead name a
new directory. The experiment automatically creates two temporary regular app bundles,
each with two windows, activates A → B → A, then moves the pointer to the left and right
edges of every active display at three heights, collecting repeated observations. It never
clicks the strip or intercepts mouse events. `--no-fixtures` is available for an existing
controlled-window test session.

Outputs include:

- OS/build, architecture, SIP status and WindowManager's declared entitlements;
- loaded SkyLight/WindowManagement/WindowManager framework metadata, Objective-C classes, selectors and
  type encodings, plus selected symbol presence (no discovered selector is invoked);
- WindowManager's linked frameworks and filtered static and Swift-demangled symbols,
  including renderer/strip/stage/Space names;
- numeric CG window identities, actual onscreen flags and frames, AX stage IDs and frames,
  frontmost PID, pointer position, and permission state;
- the fixture activations' independent snapshots, and cropped native-edge screenshots
  when screen capture is permitted;
- absent-aware original preferences, applied values, restored values and a final snapshot.

The runtime inventory is of frameworks loaded in the diagnostic's process. It is **not** an
inspection of WindowManager's private process memory. It does not inject code, use root,
restart system processes, modify SIP or assume that finding a class grants access to the
daemon's live objects. Stripped system symbols can leave `nm` evidence incomplete; errors
are preserved. Class or symbol presence alone is not a capability result.

`SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation` and
`SLSBridgedMoveWindowsToManagedSpaceOperation` are Objective-C **classes**, not C functions.
Their availability is recorded in `classes`, with superclass and method type encodings;
looking up their bare names with `dlsym` cannot establish absence. `WindowManagement` and
`WindowManager` are distinct private frameworks, and the inventory covers both.

## Result contract

`result.json` uses:

- `REJECTED_RENDERER_SEPARATION`: a native AX strip member and its CG onscreen thumbnail
  corroborate that native rendering survives this candidate setting.
- `INCONCLUSIVE`: no such positive match. Empty AX, missing permissions or no sampled strip
  cannot establish that rendering/edge reveal was disabled.
- `NOT_RUN`: native Stage Manager was not observed enabled.
- `INVENTORY_ONLY`: metadata was collected without an interaction experiment.

The tool never reports successful separation. A future candidate needs a concrete callable
mechanism, a real grouping/switching/minimize protocol, successful independent group
readback while rendering stays disabled, and reproduction on macOS 27.0 / Apple Silicon /
SIP enabled. If runtime metadata reveals a plausible method, its receiver, method encoding,
daemon connection and restoration semantics must be understood before adding a narrow
experiment; blindly calling selectors is not an experiment.

Only the keys changed by this run are restored, preserving absence as absence. Fixtures
receive a stop marker. Pointer and prior application are restored on normal completion and
handled interruption; final state and any restoration error are recorded. The tool does
not restore other applications' geometry because it never directly changes it. Native
Stage Manager itself can affect layout while temporarily enabled, so perform this in the
same controlled fixture session as the unified product validation. A forcibly killed
process can be recovered with:

```sh
python3 tools/native-stage-decoupling/run.py restore --output /tmp/nearpane-route-a-EXACT_RUN
```

Regression checks for false-positive evidence classifications:

```sh
python3 -m unittest discover -s tools/native-stage-decoupling -p 'test_*.py'
```
