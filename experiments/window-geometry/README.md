# P1-C window identity and geometry preparation

Issue #3; isolated experiment, not a production Desktop Orchestration provider.
There is **no application or executable target**, no action adapter, and no visible
test window. Tests use synthetic metadata only. Building the libraries does not
read the desktop or preflight permissions.

## Verification

From this directory:

```sh
python3 scripts/verify.py --receipt <new-unique-directory-name>
```

The script runs Swift Testing via `swift test --disable-xctest --enable-swift-testing`
and `swift build -c release`, both with `--build-system native` and
`-Xswiftc -warnings-as-errors`, plus a source boundary check. All SwiftPM caches
stay in `.build/`. `--disable-sandbox` disables SwiftPM's nested manifest sandbox;
the surrounding execution sandbox remains in effect. No dependency is downloaded.
The package declares no external dependencies. The installed Command Line Tools
provide Swift Testing but not XCTest; the first unsuccessful XCTest attempt is
retained in `evidence/20261109-preparation-01/`.
The runner explicitly loads the installed TestingMacros library when present;
Swift 6.4's build engine did not discover it automatically on this CLT installation
(attempt 02). No system configuration or toolchain files are changed.
The CLT default swiftbuild engine then failed while signing its generated test
bundle because the workspace file provider attached Finder metadata (attempt 03).
The runner uses SwiftPM's native command-line build engine instead. It does not
remove file attributes, reset build directories or change signing/security policy.
The experiment's minimum build target is macOS 14 to match the installed Testing
framework; this is not a claim of live support on that or any other OS version.
The runner also provides the CLT Testing framework search path and runtime rpaths
explicitly (missing native discovery was recorded in attempt 04). Build-engine
deprecation warnings remain in the logs. Release verification follows successful
tests; a failed test command does not trigger another release build.

Each invocation creates a new evidence directory and refuses to overwrite an
existing one. Logs, failures, toolchain/OS receipts, tested source SHA-256 values,
numeric metrics, and release-module hashes are preserved. `inputGitHEAD` is the
HEAD before the new work is committed; `source-sha256.json` identifies the actual
tested source, including uncommitted changes. The final Git commit identifies the
delivered tree. Hash manifests exclude themselves.

## Coordinate contract

`WindowGeometryCore` imports Foundation, not AppKit or Accessibility. Units and
origins are explicit:

| Space | Origin / axes | Units |
|---|---|---|
| AppKit global | supplied primary display's lower-left; y up | logical points |
| CG / AX desktop | supplied primary display's upper-left; y down | logical points in this experiment's accepted contract |
| Oriented backing | each display's already-oriented upper-left; y down | backing pixels, not necessarily native panel pixels |
| Unrotated backing | abstract raster before the supplied clockwise quarter turn | backing pixels |
| Preview | caller's top-left-origin viewport; y down | caller's UI points |

For a display with AppKit frame `A` and CG bounds `C`:

```text
CG.x = C.x + AppKit.x - A.x
CG.y = C.y + A.maxY - AppKit.y
AppKit.x = A.x + CG.x - C.x
AppKit.y = A.maxY - (CG.y - C.y)
```

Rectangles transform all four corners, then take min/max. These formulas do not
rotate or scale already-oriented desktop bounds. `A` and `C` must have equal
logical dimensions within `1e-6` points; otherwise construction fails. The
desktop constructor checks that every display agrees with the **same primary
anchor**, rejects duplicate display IDs and overlapping/mirrored extents, and
preserves negative origins and gaps. Empty, nonfinite, negative-size and
overflowed geometry fails closed. Arbitrary-angle rotations are unsupported.

Backing conversion is local: subtract `C.origin`, then multiply by that display's
scale `s`. For CG-local `(x,y)` in an oriented extent `(w,h)`, unrotated coordinates
before multiplication by `s` are:

| Clockwise turn | Unrotated `(u,v)` | Inverse CG-local `(x,y)` |
|---|---|---|
| 0 | `(x,y)` | `(u,v)` |
| 90 | `(y,w-x)` | `(w-v,u)` |
| 180 | `(w-x,h-y)` | `(w-u,h-v)` |
| 270 | `(h-y,x)` | `(v,h-u)` |

This is an explicitly defined mathematical raster convention. Its correspondence
to a real display's rotation metadata, modes and backing conversions is **NOT
TESTED**. Do not infer physical native resolution from backingScaleFactor.

Cross-display windows produce one clipped `DisplaySlice` for every intersection,
with separate AppKit/backing rectangles and area fractions. There is no single
mixed-scale pixel rectangle. Offscreen/gap area is reported by `uncoveredArea`.
Use full display frames, not `visibleFrame`, for the desktop transform. Menu/Dock
work-area insets may be passed as an explicit clip; they never change the origin.

`PreviewTransform` uniformly fits one supplied display/Space extent into a
viewport, with letterboxing. Every window uses that same transform. This package
does not discover or assign Space membership. `unproject` rejects letterbox and
outside points. Rectangular hit regions use half-open `[min,max)` extents, the
lowest front-to-back index wins, tied indices are ambiguous, and an unresolved
front window blocks selection of windows behind it. Rectangle subtraction gives
conservative visible fragments. Unknown shapes/transparency/shadows cannot be
inferred from metadata: treating their full rectangle as an occluder sacrifices
coverage rather than permitting click-through. The caller must include **all**
visible occluders, including non-targetable/system windows; a per-PID sample alone
is not enough to construct a live hit map.

## Identity and freshness contract

`WindowTarget` is an immutable, nonserializable observation reference consisting
of PID, process launch microseconds, CGWindowID, observer-local retained-AX-element
token, optional AXIdentifier, full corroborating metadata, observer session nonce,
snapshot revision, OS/source build token, topology token, sampling interval and explicit confidence.
It is **not an activation permission or proof of an exact OS identity**.

The matcher constructs a bipartite graph using equal PID+launch evidence, AXWindow
role, equal nonempty titles when both are available, and at most 2 points of error
in **each of x, y, width, height**. Both CG and AX sides must have exactly one
candidate. It does not greedily select a winner or infer a global assignment.
Duplicate CG IDs, duplicate AX tokens or a shared candidate are ambiguous.

| Confidence | Meaning | Can issue observation target? |
|---|---|---|
| `corroboratedMetadata` | unique in both directions, comparable equal title, matching process and geometry | only with every additional guard below |
| `geometryOnly` | unique geometry but missing/empty comparable title | no |
| `ambiguous` | multiple correspondences or duplicate runtime IDs | no |
| `unknown` | missing lifecycle, unsupported role, missing geometry or no candidate | no |

AXIdentifier is optional and may be duplicated; it is **not** a public bridge to
CGWindowID. A fresh AX nonce is bound to a retained AXUIElement using CFEqual, never
an array index. Identifiers are retained as corroborating metadata, not used to
override contradictions. No private AX window-ID function is used.

Target issuance also requires a complete, consistent snapshot with a nonempty
topology token, revision > 0, bounded monotonic times, a visible layer-zero CG
window, and an AXStandardWindow with minimized explicitly false. Unknown
visibility, hidden/minimized/offscreen/dialog windows remain non-targetable in
this phase. Such cases require later dedicated evidence, not automatic fallback.

Default policy: maximum age **0.5 seconds from sampling start**, maximum sampling
duration **0.25 seconds**. These are conservative experiment settings, not measured
system latency guarantees. Validation never renews a target's age. It rejects
observer restart, source build or topology change, *any* revision change, changed sampling times,
PID restart, different AX token, missing window, metadata drift, ambiguity,
incompleteness, transient state and backwards/nonfinite clocks. A new revision
requires an explicitly newly issued target, even if PID/CG ID/title/frame repeat.
The future snapshot owner must revoke revisions on sleep/wake, permission changes
and process/topology lifecycle signals, and mark consistency unknown when events
may have been missed. The reader's `systemUptime` sampling clock is not itself a
sleep/wake invalidation mechanism. No runtime lifecycle monitor is implemented.

There is no durable window identifier in this experiment. CG ID reuse between
observations, app-provided AX ID reuse, stale NSRunningApplication information,
and changes after the last observation remain possible. Metadata reads are not
atomic; matching title+frame is corroboration, not an OS identity guarantee.
Future action code would need fresh live resolution, live postconditions and a
separate authorization/capability gate. It is deliberately absent here.

## Optional read-only adapter (compiled, not exercised live)

`ReadOnlyWindowMetadata` exposes `ReadOnlyWindowObserver.read(pid:)`. Construction
does nothing. An explicitly invoked read:

1. Requires a live LaunchServices application with `launchDate`; missing process
   lifecycle data remains unknown. It never substitutes PID alone.
2. Calls `AXIsProcessTrusted()` with **no prompt**. If false, it returns a diagnostic
   without requesting permission or opening System Settings.
3. Reads public CG metadata, retaining only the selected PID, and public AX window
   attributes. Titles/identifiers stay in memory; there is no logging/export API.
4. Uses per-object AX messaging timeout 0.1 s, a 64-window bound and a 2 s budget
   between synchronous calls. The timeout changes client IPC behavior, not window
   state. Missing optional attributes remain nil; unexpected AX errors and missing
   required metadata are preserved as diagnostics.
5. Compares two CG and two AX observations and rechecks process lifecycle. It
   returns `repeatedMetadataAgrees`, never claims atomicity or creates a target.

The observation budget is longer than the target sampling threshold on purpose:
metadata can be diagnostically useful while too old/slow for target issuance.
CG calls have no timeout facility; a future live integration should run in an
isolated helper. The adapter does not sample topology or Spaces, so the caller
must independently establish snapshot consistency. An AX permission result from
the older P1 baseline is not reused as current permission evidence.

The adapter has no pixel capture, AX action, application activation, window
mutation, Mission Control, permission request, or private Spaces calls. Source
boundary checks are a supplemental textual guard, not a semantic security proof.

## Sources and remaining work

- Installed macOS SDK: `CGWindow.h` describes window bounds as top-left-main-display
  screen coordinates; `AXAttributeConstants.h` specifies AX position/size in points.
- Apple [CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:))
  and [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen).
- Apple [NSRunningApplication.launchDate](https://developer.apple.com/documentation/appkit/nsrunningapplication/launchdate)
  is only available for applications launched by LaunchServices. Its absence is
  why this adapter cannot identify arbitrary processes by lifecycle.
- Installed `AXUIElement.h`: `AXIsProcessTrusted`, copy-attribute functions and
  per-element messaging timeouts. No focus/raise/set-attribute function is used.

See [CALIBRATION.md](CALIBRATION.md) for the unexecuted real-device procedure and
[the preparation report](../../engineering/P1-C-WINDOW-GEOMETRY-PREPARATION-20261109.md)
for receipts and gate status. This experiment does not close P1-C or P1-Core.
