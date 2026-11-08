# Real-device calibration plan — NOT TESTED

This is a future procedure, not an execution script or authorization. The current
task authorizes preparation and pure tests only; no visible fixture was built or
launched. Live AX/CG correspondence, real coordinate accuracy and every activation
case below remain **NOT TESTED**.

## Gates and scope

1. Obtain separate explicit authorization to launch visible dedicated fixture
   windows and to manipulate **those fixture windows only**. This does not permit
   changing unrelated user windows. No such authorization exists in this run.
2. Use existing AX trust only. If absent/revoked, record NOT TESTED and stop that
   path. Requesting Accessibility permission requires separate authorization;
   this package contains no permission request. Screen Recording is unnecessary
   for metadata calibration and must not be requested.
3. Activation/raise/focus, application activation, cross-Space behavior and Spaces
   switching require an additional explicit action authorization. Geometry
   calibration is not activation authorization. Mission Control settings remain
   unchanged; off/on Spaces experiments belong to P1-B.
4. No screenshots, screen recording, pixel capture, real-document titles or user
   content. Use fixture-only metadata and anonymized IDs in committed evidence.

## Controlled fixture specification

After authorization, build a dedicated test app (not part of this preparation
package) with at least two standard windows in one process, plus a second app
instance with a distinct process lifecycle. Use asymmetric rectangular outer
frames; stable explicit AXIdentifier strings; distinctive synthetic titles; and
a fixture-generated window nonce visible in metadata. Include duplicate-title,
untitled and duplicated-AXIdentifier cases, retaining the ground-truth association
inside the fixture process. Use public fixture-owned window numbers to establish
an independent CG/AX correspondence oracle. Do not infer the oracle from the
matcher under test. Fixture local content coordinates and outer window frames
must be recorded separately to avoid title-bar/decorations errors.

Manual authorized placement is sufficient; no automatic window controller is
required. Document initial topology and fixture state for recovery. Closing or
restarting fixture apps must also be within that future authorization.

## Geometry measurements

Record OS build, architecture, toolchain, display UUID aliases, primary display,
AppKit full frame, visible frame separately, CG bounds, rotation, backing scale,
mode dimensions and topology revision. These are a future targeted calibration
record, not a rerun of the original Spaces inventory or ABI experiment.

Use a monotonic sampling interval around CG and AX reads; retain nulls, missing
attributes, timeouts and changing samples. Collect stable observations after
animation ends without treating stability as an atomicity guarantee. Invalidate
all targets when topology/session changes. Check the global primary-anchor
relation before comparing windows; do not fit independent transforms per window
or absorb a mismatch into a scale factor.

For each supported display and rotation, measure at least three independent
stable repetitions of each case:

| Case | Required comparison |
|---|---|
| Four corners and center | independent known fixture outer frame vs AX and CG |
| Full width and full height | origin, width, height, decorations and work-area insets |
| Asymmetric split | two unequal fixture windows under one shared preview transform |
| Negative display origin | left and above-primary arrangements already available |
| 90/270 rotation | labelled asymmetric corner coordinates; reject reflection/axis swap |
| Mixed backing scale | logical point agreement; AppKit backing conversion oracle |
| Cross-display rectangle | every display clip, area conservation, no lost gap/offscreen area |
| Overlap | exposed strip, intersection and covered area against known fixture z-order |
| Exact seam and viewport margin | half-open edge ownership and letterbox rejection |

Unavailable topologies/rotations stay NOT TESTED. Do not rearrange displays or
change rotations merely to fill the matrix without authorization. A forward
golden-coordinate check is mandatory: a round trip alone can hide matching inverse
bugs. Real backing calibration must use framework conversions/mode evidence,
not just multiply by a guessed scale. Native panel pixels are a different domain.

## Identity, disappearance and activation measurements

For live **read-only** matching, compare the fixture's independent association
table with all candidate edges. Keep unknown/ambiguous outcomes, including hidden,
minimized, offscreen and unsupported-role windows. The current resolver refuses
those target categories. Test retained AX object replacement, process restart,
window close/recreation, duplicate titles/identifiers, stale revisions, clock
expiry, topology change and permission loss. Synthetic PID/CG ID reuse tests do
not prove the OS will reuse those IDs during a real trial. Do not force system
state changes; record unreproduced reuse as NOT TESTED.

Only after **explicit activation authorization**, a separately reviewed harness
may test current-Space non-main-window activation, same-app window selection,
different-app selection, cross-Space activation and exposed overlap hits. Each
case needs at least three repetitions with an independent read-only before/after
oracle for the exact fixture window, frontmost PID, actual visible Space relation
and unintended changes. A successful API return or app activation alone is not
proof of the selected window. Never fall back to another window, app activation
or automatic retry after an unknown outcome. Preserve failed trials and recover
only within the granted fixture scope.

## Thresholds and receipt schema

| Metric | Preparation threshold | Future real-device threshold |
|---|---|---|
| Mathematical round-trip max component error | `<= 1e-9` logical points | `<= 1` logical point |
| Absolute x/y position error | golden-coordinate assertions `<= 1e-9` | each component `<= 2` logical points |
| Absolute width/height error | golden rectangle assertions `<= 1e-9` | each component `<= 2` logical points |
| Matching frame discrepancy | each of x/y/w/h `<= 2` | same; never enough alone for identity |
| Wrong unique association / wrong activation | zero in synthetic cases / not executed | **zero**, every individual trial |
| Hit-test target | exact expected ID or blocked/ambiguous | exact independent expected fixture ID |
| Transform orientation | independent quarter-turn goldens | zero reflected, swapped or wrong-origin cases |

These are Nearpane engineering thresholds, not Apple guarantees. Report **max,
p50, p95 and RMS**, plus counts, rejection categories, coverage, per-display/case
results and all failures. Max thresholds apply to every sample, not just p95.
Synthetic numerical precision must never be presented as measured real-device
error. The 0.5 s target age / 0.25 s sampling policy requires live latency evidence
before any production decision.

Each future receipt must include revision, observer session, monotonic start/end,
OS/build, anonymized topology, source/permission completeness, expected fixture
identity, observed CG/AX records, candidate graph/confidence, error components,
status (`PASS`/`FAIL`/`NOT TESTED`) and reason. Archive exact commands, source/tree
identity, hashes, raw fixture-only samples, sanitized aggregate JSON, failure
samples and SHA-256 manifests. No screenshots are necessary. Preserve every
attempt; never overwrite a failure with a later success.
