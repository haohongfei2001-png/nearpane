# P1-C — Window identity and geometry preparation

**Date:** 2026-11-09 (Asia/Shanghai; machine receipts use UTC)

**Issue:** Nearpane #3 — P1-C: Prove window identity, activation safety, and display geometry

**Branch:** `spike/p1-window-geometry-20261109`

**Base HEAD:** `beb6471fe360004425760a024636e5a63dbe87d1`

**Scope:** preparation and pure geometry only. P1-C live proof and P1-Core remain open.

**Result:** preparation **PASS** — 43 pure tests passed, release build passed;
live matching, calibration and activation **NOT TESTED**.

## Inputs and isolation

Read the gate review at `docs/reviews/P1-TECHNICAL-GATE-REVIEW.md` and the baseline
and architecture documents at their actual checkout paths:

- `engineering/P1-READONLY-BASELINE-20261109.md`
- `architecture/MACOS-SPACES-FEASIBILITY.md`
- `architecture/NEARPANE-ARCHITECTURE.md`

This base contains documents and a prototype, not a Swift application. The new
package is isolated under `experiments/window-geometry/`. Existing documents and
prototype files were preserved. No original Spaces inventory probe was rerun,
no P1-A ABI work was duplicated, and no production Spaces orchestration was added.

## Deliverables

| File relative to `experiments/window-geometry/` | Purpose |
|---|---|
| `Package.swift`, `.gitignore` | two libraries, pure test target, local build/cache exclusion |
| `Sources/WindowGeometryCore/Geometry.swift` | explicit coordinate spaces, quarter turns, per-display backing scales, cross-display clips, preview mapping, hit/occlusion geometry |
| `Sources/WindowGeometryCore/WindowIdentity.swift` | lifecycle/PID + CG + AX metadata, bipartite ambiguity, revision/session/topology/age validation |
| `Sources/ReadOnlyWindowMetadata/ReadOnlyWindowObserver.swift` | bounded, per-PID public metadata reader; no permission request or system action |
| `Tests/WindowGeometryCoreTests/GeometryTests.swift` | independent golden cases and deterministic numerical sweep |
| `Tests/WindowGeometryCoreTests/IdentityTests.swift` | matching, duplicate/ambiguous IDs, stale targets and fail-closed hit tests |
| `scripts/verify.py` | reproducible offline verification with append-only receipts |
| `README.md` | contracts, units, confidence, limitations and usage |
| `CALIBRATION.md` | real-device test procedure, independent oracle, thresholds and authorization gates |
| `evidence/*/` | exact commands, environment, stdout/stderr, source hashes, metrics and attempt status |
| `SHA256SUMS.txt` | final source/docs/evidence integrity manifest, paths relative to repository root |

This report is the only new file outside the experiment directory. The delivered
commit contains it and the package; exact HEAD is reported at handoff. Verification
receipts store the input HEAD plus tested-source SHA-256 because tests run before
the commit. No self-referential commit hash is embedded in its own contents.

## Safety and evidence boundaries

The core has no macOS observation or action calls. The separate reader compiles
against public APIs, retains only the selected PID's metadata in memory, checks
existing AX trust without prompting, and records unknown/error states. It has no
executable entry point and was **not invoked**. No trust preflight from a past
baseline is reused as current evidence.

`WindowTarget` is a short-lived, immutable observation reference. Its unique
metadata confidence does not grant activation capability. Two-way matching is
required; title-less geometry-only matches and ambiguous candidates cannot issue
targets. All revisions, session/topology changes, process restart, different AX
object, stale timing and metadata drift invalidate old targets. Observations are
not atomic and do not guarantee absence of ID reuse between reads.

Already-oriented CG/AppKit desktop coordinates are never rotated again or scaled
by backingScale. Backing conversion is local to each display. Unsupported logical
unit mismatches and mirrored/overlapping display topology fail closed. Window
fragments crossing displays retain separate scale/rotation conversions. Real
rotation convention and point/pixel calibration remain unverified.

No user or fixture window was launched, raised, focused, moved, resized or closed;
no application activated; no Space switched; no Mission Control setting changed;
no pixels captured; no Accessibility or Screen Recording permission requested.
There is no native test-window fixture in this delivery: synthetic metadata
fixtures suffice for this phase, and a future controlled fixture is specified in
`CALIBRATION.md` without launching anything now.

## Verification and receipts

Verified environment: macOS 27.0, build 26A428, ARM64; Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), Command Line Tools SDK.

From `experiments/window-geometry/`, verification invocations and all expanded
subcommands are preserved in each `receipt.json`:

```sh
python3 scripts/verify.py --receipt 20261109-preparation-01
python3 scripts/verify.py --receipt 20261109-preparation-02
python3 scripts/verify.py --receipt 20261109-preparation-03
python3 scripts/verify.py --receipt 20261109-preparation-04
python3 scripts/verify.py --receipt 20261109-preparation-05
```

Attempt 01 is retained as a failed verification attempt: Command Line Tools
could not resolve XCTest, so no unit tests executed; release libraries did build.
The tests were ported to the installed Swift Testing while the release build
finished, so that attempt correctly records `sourceUnchangedDuringVerification:
false`. The replacement uses native Swift Testing and does not install anything.
Attempt 02 is also retained: the installed Swift Testing macro library was not
automatically loaded by the build engine; no tests executed. A small compiler
type-check verified that explicitly loading `libTestingMacros.dylib` fixes that
failure. The runner locates it from `xcrun --find swiftc` and passes it only to tests.
Attempt 03 compiled the tests but failed to sign the generated test bundle because
it had Finder metadata. It did not execute tests. Attempts 02 and 03 both passed
their release builds. The final command selects SwiftPM's native build engine;
no file attributes, system signing policy or toolchain installation were changed.
Attempt 04 exposed native SwiftPM's missing CLT Testing framework search path;
tests did not run and the release build passed. The final runner supplies that
framework path, its runtime rpaths and the macro library explicitly. It retains
the native engine's deprecation warning and skips redundant release builds if a
test command fails.
The SDK also emits a linker search-path warning for a missing Command Line Tools
Developer/Library/Frameworks directory; this is recorded, not hidden.

Final attempt 05 passed with unchanged tested source. There were 16 geometry tests
and 27 identity tests, **43 passed / 0 failed**. The final release build exited 0;
its five module/object SHA-256 values were rechecked against files on disk. The
source boundary check found no prohibited calls in the experiment sources. No
additional test reruns were needed after this pass.

| Final check | Status | Receipt |
|---|---|---|
| Pure unit tests | **PASS** | [swift-test.log](../experiments/window-geometry/evidence/20261109-preparation-05/swift-test.log) |
| Release libraries | **PASS** | [swift-build-release.log](../experiments/window-geometry/evidence/20261109-preparation-05/swift-build-release.log) |
| Commands, toolchain, matrix and artifact hashes | **PASS** | [receipt.json](../experiments/window-geometry/evidence/20261109-preparation-05/receipt.json) |
| Exact tested source | **MATCHES final files** | [source-sha256.json](../experiments/window-geometry/evidence/20261109-preparation-05/source-sha256.json) |
| Supplemental static boundary check | **PASS** | [static-boundary.json](../experiments/window-geometry/evidence/20261109-preparation-05/static-boundary.json) |

The deterministic sweep uses 36,000 rectangles over 4 rotations, 3 scales and 3
origin arrangements; it produces 144,000 component-error measurements from AppKit,
oriented/unrotated backing and preview round trips. Independent golden coordinates,
hit-test cases, cross-display area and failure cases are separate assertions.

| Numerical metric | Logical points |
|---|---:|
| Maximum | `6.536993168992922e-13` |
| p50 | `5.684341886080802e-14` |
| p95 | `2.2737367544323206e-13` |
| RMS | `1.171245939850167e-13` |
| Synthetic pass threshold | `1e-9` |

These are **synthetic numerical errors**, not measured real-device errors. The
full metric record is [geometry-metrics.json](../experiments/window-geometry/evidence/20261109-preparation-05/geometry-metrics.json).
All four unsuccessful tooling attempts remain archived; none executed a test or
performed a desktop action.

SHA-256 of final `receipt.json`:
`103cfe6ffb7285f93a1d40fcaaabfac70bba75ce38bfa73fcf0a2cdb56077bc4`.

SHA-256 of `geometry-metrics.json`:
`b761ae349870918d87f74ba3ae9fe32f4cad394fb828fe8e730848c91f44602f`.

The complete source/docs/evidence inventory is in
[SHA256SUMS.txt](../experiments/window-geometry/SHA256SUMS.txt); validate it from
the repository root with `shasum -a 256 -c experiments/window-geometry/SHA256SUMS.txt`.
Build/cache products remain local under the ignored `.build/`; no generated
binaries or cache directories are committed. Prior evidence files were not
overwritten, and no reset/clean was used.

## Remaining authorization and acceptance gates

| Case | Current status | Requirement for live completion |
|---|---|---|
| Live AX/CG unique matching | **NOT TESTED** | controlled fixture oracle, existing trust, permission gate if absent |
| Actual AppKit/CG/AX geometry and backing calibration | **NOT TESTED** | explicit fixture launch/placement authorization; calibration matrix |
| Same-app and different-app exact-window activation | **NOT TESTED** | explicit focus/activation authorization and independent postconditions |
| Cross-Space activation and Space switching | **NOT TESTED** | explicit action/Space-switch authorization; P1-B relation evidence |
| Real close/recreate/PID reuse/permission loss | **NOT TESTED** | fixture lifecycle/permission-change authorization; no system state forcing |
| Mirroring, hotplug, Stage Manager, arbitrary rotation/other OS builds | **NOT TESTED / unsupported** | separately scoped compatibility work |

Current synthetic acceptance is `<= 1e-9` logical points for round trips; future
real-device limits are each x/y/width/height component `<= 2` points and round trip
`<= 1` point, with zero wrong associations or wrong-window activations. These are
Nearpane engineering criteria, not platform guarantees. Live errors must remain
unknown until measured. No further authorization is requested by this preparation
delivery; the pending gates explain why issue #3 and P1-Core cannot be closed.
