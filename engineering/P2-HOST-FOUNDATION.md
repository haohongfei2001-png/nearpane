# P2 Host Foundation implementation

Scope: issue #4, branch `implementation/host-foundation-20261109`, base `beb6471fe360004425760a024636e5a63dbe87d1`. The latest task instruction limits this run to build/test and a local commit: no visible app launch and no push. It supersedes issue #4's visible acceptance and push steps for this run.

## Architecture decision

Use **Swift + AppKit for application/window ownership, SwiftUI for presentation, and a small Swift core target**. SwiftPM builds the executable; a short packaging script adds a native development application bundle and verifies the compiler-generated executable signature. This works with the installed Command Line Tools without adding generated Xcode project files, package dependencies or a project generator.

- `NearpaneCore`: pure geometry, versioned configuration, trusted built-in module registry, explicit lifecycle and action routing, simulated permissions, snapshots/events and bounded diagnostics.
- `NearpaneUI`: one borderless `NSPanel`, native material, SwiftUI surface and a separate settings view. Window creation and presentation are separate operations so tests can inspect a hidden window without ordering it onscreen.
- `NearpaneHost`: `NSApplicationDelegate` owns startup, shutdown, the surface, screen-change observation and a menu-bar control. There is one primary surface. Settings is created only after the user requests it.

AppKit exposes the panel behavior needed here directly; [Apple's `becomesKeyOnlyIfNeeded` contract](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded) lets a nonactivating panel defer keyboard focus to views that need it. P2's read-only surface does not request key focus. SwiftUI keeps the layout and settings implementation compact. [SwiftPM executable targets](https://developer.apple.com/documentation/packagedescription/target) keep the core independently testable. Neither SwiftUI window scenes nor a web host are needed for this stage.

This is an internal built-in registry, not a plugin SDK or marketplace. No external code loading, subprocess adapter, data-sharing database or production provider is introduced.

## Contracts and behavior

**Layout and placement.** `SurfacePlacement` takes explicit AppKit-coordinate screen frames and visible areas. The selected screen contributes approximately 1/8 width; the entire visible height is used. Only public display APIs are used by the app's own placement adapter. A missing preferred display falls back to the menu-bar display without rewriting the preference. Screen changes recompute placement; zero available screens hides the surface. Host display placement is independent of the synthetic desktop provider.

`LayoutComposer` keeps the upper 3/8 and lower 5/8 invariant across module counts. Saytile and Riftlet retain stable slots even when disabled. Core ordering cannot be changed. Optional modules occupy a bounded horizontal scrolling control layer over the lower edge; expansion overlays only part of the desktop region. It neither replaces the underlying scroll view nor changes its frame. Close, outside click and toggling the selected entry collapse the overlay. Only one module can expand. There is no unsaved editor in P2; switching overlays retains the sample runtime's state.

**Modules and failures.** The registry checks unique IDs, minimum Host version and action/permission declarations. Lifecycle includes available, enabling, resident, expanded, suspended, permission-required, degraded and disabled. Enable starts a runtime once; disable stops it and invalidates its publication epoch. Resume and restart allocate a new instance ID. A throwing start, snapshot, action or resume failure stops only the affected module, leaves its preference enabled and exposes explicit restart in Settings. No automatic restart loop runs.

Isolation here means **recoverable Swift errors and failing event subscribers**, not containment of a process crash, `fatalError`, memory corruption or a noncooperative blocking module. All bundled P2 modules are small synchronous samples. A production adapter with crash/hang risk needs a helper/XPC boundary before integration. This limitation is not a verified module-crash isolation claim.

**Actions and permissions.** The router requires explicit user intent, checks enabled runtime and declared action, and requests only its declared simulated permission. Enabling a module never requests permission. Grants are scoped to a module/capability pair and remain in memory. Revocation stops the affected runtime. The Calendar sample exercises this interface without accessing a calendar. Both desktop action protocol methods have only an unsupported adapter; the router never dispatches real switching or activation, regardless of fixture identity.

**Snapshots and events.** Desktop snapshots carry provider/build provenance, session identity, monotonic revision, sampling interval, topology fingerprint and consistency, effective freshness, identity confidence and capability status. Internal display scopes and Space records are separate from user-facing semantics. All fixtures explicitly retain unknown user-facing semantics. Window membership preserves empty, single, multiple and unknown results; nothing assigns unknown windows to a current Space.

The bus rejects malformed, duplicate, older-revision and wrong-session desktop snapshots. Stale/transient updates never replace the last stable sample. Age is evaluated at consumption; a once-fresh snapshot can become stale. Refresh generation guards prevent an older asynchronous result or one completing after stop from publishing. Module events carry module/instance/revision/timestamp; disabled or replaced instances cannot publish. Subscriptions are explicitly scoped, throwing subscribers are removed, and full snapshots remain available for resynchronization. Events are not an unbounded log.

Fixture window bounds are **synthetic display-local, top-left logical points**. There is no production CG/AX coordinate conversion, hit testing, real Space identity mapping, pixel capture or window preview renderer in P2. The UI displays read-only synthetic display metadata, never one row per unverified internal Space record.

**Persistence and diagnostics.** Version-1 JSON stores module enable/pin/order, edge/preferred display and fixture selection. Atomic writes avoid partial JSON. Invalid, duplicate-ID, oversized or future-version inputs are rejected. Failed reads preserve the original file and disable writes for that session; failed saves remain visible while the Host stays running. Runtime identities and permission grants are excluded. Diagnostic records contain a timestamp, enumerated code and allowlisted catalog module ID only. The local ring buffer is capped at 200; no payload, free-form error, desktop ID, transcript, image, path or credential is exported. There is no telemetry transport.

## Status matrix

| Feature | Designed | Implemented in P2 | Validated in this run |
|---|---|---|---|
| Native app target / bundle | Yes | SwiftPM executable + AppKit lifecycle + `.app` packaging | Build, bundle structure, executable signature and copy integrity; visible launch/quit **NOT RUN** |
| Edge window / screen placement | Yes | One nonactivating panel; fallback and screen notifications | Pure geometry + hidden AppKit construction/placement; real visible placement/hotplug **NOT RUN** |
| Frozen layout / overflow / overlay | Yes | Pure composer + native UI control layer | Ratio, geometry invariance and overflow tests; visual/scroll/focus acceptance **NOT RUN** |
| Module registry / lifecycle | Yes | Bundled core placeholders and optional lifecycle samples | Enable/disable/order/pin, suspend/resume, restart and restoration tests |
| Failure isolation | Yes | Recoverable error and subscriber isolation | Injected-error tests; process crash/hang containment **NOT IMPLEMENTED** |
| Action routing / permission broker | Yes | Explicit actions + simulated per-module grants | Allowlist, denied intent, grant/revocation and fail-closed desktop tests; real permissions **NOT IMPLEMENTED** |
| Snapshot/event bus / diagnostics | Yes | Revision/session/freshness guards; bounded redacted records | Stale/transient/late-event, concurrency and diagnostic tests |
| Configuration persistence | Yes | Versioned atomic JSON; original-file protection | Round trip, restart, corruption, schema and write-failure tests |
| Desktop fixtures | Yes | 1–3 displays, 3+1 internal scopes, rotation, unknown membership, stale/transient | Fixture contracts and encoding tests; no system desktop observations |
| Saytile / Riftlet domains | Yes | Surface placeholders only | Integration **NOT IMPLEMENTED / NOT VALIDATED** |
| Spaces Preview / real actions | Yes | **NOT IMPLEMENTED** | **NOT VALIDATED**; P1-Core / P4 gate remains open |
| Optional production modules | Yes | Synthetic lifecycle samples only | P5 functionality **NOT IMPLEMENTED** |
| Distribution / resource baseline | Yes | Local development bundle only | Build process resource usage and test elapsed time recorded; resident app usage, distribution signing/notarization, compatibility **NOT RUN** |

No original design, prototype, P1 review or baseline status was rewritten. No Saytile/Riftlet repository was inspected or modified. No remote branch is updated by this stage.

## Local build constraints resolved or retained

- The installed CLT toolchain has Swift Testing but no usable XCTest module. Tests use Swift Testing; no Xcode installation or toolchain modification was required.
- Swift 6.4's default `swiftbuild` engine reached test signing but failed on File Provider Finder metadata. An incremental attempt also lost its Testing macro plugin discovery. The test script uses the supported (deprecated) `native` engine, explicitly discovering CLT's Testing framework and macro plugin. App builds use the default engine. All 46 tests pass through the script; the native-engine deprecation warning remains a future toolchain maintenance item.
- Signing an ordinary staging directory initially passed, but after the `.app` rename the local File Provider added `com.apple.FinderInfo` and later strict bundle verification failed. That is not treated as a durable signing fix. The final script produces an **unsigned development bundle containing the unchanged, compiler-signed executable**. It verifies the standalone executable signature and byte-for-byte packaged copy. It does not strip quarantine, change File Provider settings or modify installed apps. Distribution bundle signing and notarization remain P6 work; [Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html) documents the rejected metadata.
- The CLT default engine emits linker search-path warnings for absent `Developer/usr/lib` and `Developer/Library/Frameworks`. The executable links to system frameworks/libraries only. Those environment warnings are preserved in receipts; no compiler warning in the final source is suppressed.

## Remaining acceptance (requires a later visible run)

1. User-launch the built app, inspect the no-header surface on the actual display and confirm startup/quit does not disrupt the user's work.
2. Exercise Settings enable/disable/pin/order and overlay close/outside click, overflow scrolling and restoration after relaunch.
3. Verify material, small-screen density, actual focus behavior, display removal/reconnection and full-screen behavior. Hidden tests do not establish those outcomes.
4. Measure resident CPU, memory and wakeups over an idle interval. Build/test process timing is not an idle Host baseline.
5. Progress P3 through versioned Saytile/Riftlet adapters and P4 only after the outstanding P1-Core gates. Do not infer real Spaces readiness from P2.

Build/test receipts, exact environment and SHA-256 are recorded in [the receipt directory](receipts/P2-20261109/README.md). The delivered commit is identified by `git rev-parse HEAD` and the final handoff; a commit cannot embed its own final hash without changing that hash.
