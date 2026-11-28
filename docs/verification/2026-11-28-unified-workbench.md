# Unified workbench verification

This record separates source-level tests, a packaged native build, actual UI observations, real player integration and release qualification. The product decisions are in [the design record](../design/2026-11-28-unified-workbench.md).

## Validated integration candidate — 8c884573

**Source:** `8c88457332cf55633d071b2992932a1971ded321`. **Native CI:** [run 46058153742](https://github.com/haohongfei2001-png/nearpane/actions/runs/46058153742), completed successfully on macOS 26.7.2 (25G332). Subsequent documentation/evidence commits do not change this tested application source.

The [committed evidence index](unified-workbench/8c884573/README.md) contains all 30 original native UI screenshots, the complete source test log, build/package logs, public accessibility diagnostics, native and runner receipts, the actual Music blocker screenshot, and candidate metadata. The machine-readable [summary](unified-workbench/8c884573/verification-summary.json) records the exact scope and artifact identifiers.

| Evidence level | Final result | Exact scope |
| --- | --- | --- |
| Source regression suite | **PASS — 986 tests / 158 suites** | Complete test suite on the macOS runner; no failing assertions. |
| App build and package verification | **PASS — 50 bundled resources verified** | Full native debug candidate, with its executable hash tied to the UI runner input. |
| Packaged native UI acceptance | **PASS — 53 / 53 checks** | Six actual public accessibility actions, five production menu target/actions, five production module navigation callbacks, retained-window identity/count, close/reopen, content/configuration readbacks and lyric fixture states. |
| Input fallback | **Zero** | No programmatic routing fallback is counted or needed in this run. |
| Native screenshots | **30 / 30 WindowServer captures** | Actual visible AppKit/SwiftUI windows and panels; each saved PNG checksum was verified. |
| Pause presentation | **PASS within the declared fixture scope** | Paused content survives refresh; actual native cursor movement exposes controls. One exact playback control is found and is correctly disabled because the fixture owns no real player lease. |
| Real Apple Music transport | **BLOCKED** | System Automation consent for `hosted-compute-agent` to control Music, with Music's first-run Welcome screen behind it. No permission was accepted and actual playback/pause/resume was not reached. Cleanup confirmed Music exited; that cleanup is not lifecycle acceptance. |
| Release qualification | **Not qualified** | arm64 / macOS 26+ debug candidate; Host executable has an ad-hoc signature, with no complete Developer ID distribution bundle signature or notarization. |

The final native run resolves the preceding control-inspection failure by restricting inspection to the requested window's nested native hosting views. The permissions entry now reaches the same main window from primary and secondary sidebar call paths. The native fixture checks the production permissions callback and visible page on its single available display; the secondary route additionally has a [static ownership audit](unified-workbench/8c884573/management-window-audit.md), not a claimed multi-display run.

Reordering exercises the real persisted command used by drag/drop, and its resulting order/layout is read back. It is not physical pointer-drag qualification. Voice/screenshot retention uses isolated generated content; it is not a migration audit of every historical user database. The native fixture is an explicitly identified, re-signed copy of the candidate, with separate executable hashes recorded; the downloadable candidate is untouched.

Visual inspection covered the current light/dark module pages, compact dark settings, display placement, permissions, screenshot library, all-module sidebar and paused hover. The runner's system **Reduce Transparency was enabled**, visibly reported in Appearance. These captures qualify native layout, contrast and the accessibility material fallback; they do not qualify the ordinary blurred-glass material against a real desktop. Real fullscreen entry/exit, multi-display behavior, QQ Music/NetEase and simultaneous real players, microphone/browser attachments and live Spaces dispatch remain separate operational gates. No unresolved PR 16 dispatch issue is claimed as fixed by this UI work.

The newer constitution's top/bottom horizontal layout, real downloadable/removable module packages and a complete default-avoidance service independent of Spaces remain implementation gaps. They are not disguised as missing release paperwork or inert controls.

### Candidate download and identity

[Download the candidate artifact](https://github.com/haohongfei2001-png/nearpane/actions/runs/46058153742/artifacts/15226944433) · [Download complete CI evidence](https://github.com/haohongfei2001-png/nearpane/actions/runs/46058153742/artifacts/15227981724)

- App version: `0.2.0 (1)`; bundle ID: `com.holdsnow.nearpane.host`.
- Architecture: **arm64**. Minimum OS: **macOS 26.0**, confirmed in both Info.plist and Mach-O; SDK 26.5.
- Inner candidate ZIP: **34,675,081 bytes**; SHA-256 `0d21dd5127cb2855b87a38aca99f82abd52082d52d9e370867fa7aa7480557e1`.
- Host executable SHA-256: `34816cf4c116a1e7f85c09bf48669e25ceed32068a7dec7140ce9ca384415101`; identical in package verification, downloaded ZIP inspection and native runner input.
- The app was not installed over a user's daily installation and no public release was created.

The sections below preserve earlier failures and their version scope; they are historical diagnostics rather than the current candidate's status.

## Source and native checkpoint — 44c2739

[Run 46056256340](https://github.com/haohongfei2001-png/nearpane/actions/runs/46056256340) compiled the integrated app and passed **986 tests in 158 suites**, with no failing assertions. The former visual-contract fixtures now explicitly verify the migrated revision, preservation of retired values, independent display preferences, restart behavior, actual width limits and the designed material radius. Their expected values are not generated by calling the production normalizer.

The actual packaged UI produced **29 WindowServer screenshots** and **51 checks: 50 passed, one failed**. All six native accessibility actions (primary navigation, module detail/return, Library, Settings and module enablement) passed using the actual public accessibility action and observed application state. There were **no programmatic routing fallback records**. Real cursor movement into the paused lyric surface also passed. The remaining failure was locating the disabled fixture playback control: the inspector hit-tested the outer AppKit container and then escaped through its parent into the application's other window, instead of inspecting the inner SwiftUI hosting view. The following revision confines inspection to the requested window and includes its native AX-group views; that fix needs its own run.

The following revision also completes the sidebar permission-guide route into the single main window, including secondary displays without additional domain instances. The older isolated permission-popover observer explicitly reports its superseded scope as unsupported instead of certifying the new route.

The real Apple Music attempt remains **BLOCKED**. Its captured cloud desktop shows the system Automation consent dialog for `hosted-compute-agent` controlling Music, with Music's first-launch Welcome screen behind it. No consent was clicked and no real-player transport result is claimed. The source pause/session policies and real native hover observations are separate evidence.

## Integration baseline

- Integration branch: `pro/r4-integrated-lyrics-20261128`, [PR 18](https://github.com/haohongfei2001-png/nearpane/pull/18).
- Starting integrated lyric commit: `172589a6f5e470e4a4fe1c2a5bb7c2b34c07c08a`.
- Latest PR 16 source included at task start: `60cf3219901c6997db400a1d08e143ddd011d0a0`.
- The two histories were retained by merge `09e4d0e3d5761eeb4762e08696736a0acad265fe` before changing the management UI.
- PR 16 subsequently advanced during this work. Merge `f8d91b50187787af827d7e1a9f8dd9d927a3e95f` retains both the UI checkpoint `83a8f42` and upstream `d614f58d06b4a23cda3ae6d381ff59fb31ca414d`; its ownership/read-queue fixes and existing evidence remain attributed to PR 16.
- No website, independent LyricTile product, or Spaces dispatch algorithm is part of this redesign.
- While publishing the next checkpoint, the branch advanced to `d73d15493c57430f34c5b488724fd0375c065f14` with the owner-approved product constitution. Its 15 documentation files were retained without replacement, and the constitution was verified identical to `main`. The same checkpoint's fixed resident order and detailed visual controls are transitional until the constitution-aligned UI revision is validated.

## First packaged candidate — 5b36ad79

[Native macOS CI run 46046131066](https://github.com/haohongfei2001-png/nearpane/actions/runs/46046131066) used macOS 26.7.2. The integrated Nearpane app compiled and passed package verification. The workflow produced an ad-hoc signed debug candidate; it is not a notarized release.

| Evidence | Observed result | Meaning |
| --- | --- | --- |
| Complete source test run | 964 tests; 5 failing tests with 12 reported issues | Not a green regression run |
| Lyrics session and embedded updater tests | Passed | Their tested policies/callbacks passed; not proof of real player or network update installation |
| App build and bundled-resource verification | Passed | A complete native candidate was produced |
| Native launch | Main window visible; exactly one management window | The app launched on the cloud desktop |
| Native UI actions/capture | Failed at first SwiftUI accessibility action, before screenshots | No completed UI acceptance or screenshot-quality claim for this candidate |
| Real Apple Music setup | Local audio AppleScript timed out after 30 seconds | Blocked; not evidence that pause/resume works or fails |

The native acceptance copy uses generated sample content and an executable-bound, disposable profile. Its bundle identity and signature differ from the untouched candidate. The runner records hashes separately. Synthetic lyric snapshots are labelled; they cannot certify real Apple Music, QQ Music or NetEase Music behavior.

## Failures investigated before the next candidate

1. **Voice archive fixture:** the new passive-history test attempted to open two exclusive Saytile database owners at once. The test now hands its seeded store to the live module, then opens fresh short-lived owners after stop. It still checks saved content while disabled, no capture startup and complete paragraph copying across pages.
2. **Space boundary test macros:** eight negative assertions in two existing tests expanded incorrectly under this runner's Swift Testing toolchain. The same test and production-source blobs existed in both original baselines. Calls now produce local `Bool` values before the same assertions. No production boundary rule changed.
3. **Existing native renderer fixtures:** the glass test compared a system accessibility preference with an offscreen SwiftUI environment; the roster test expected content while its panel was never presented. The fixtures now read the actual rendering environment and present the generated panel before sampling pixels. Pixel/color/geometry assertions remain intact. Unmodified PR 16 worktrees on the same runners reproduced the original 11 SpaceInventory/DesktopRoster issues; these two suites pass in the current candidate. No production Spaces rule was changed to satisfy them.
4. **SwiftUI accessibility lookup:** the next native run saves the real window screenshot before the first action, retains an accessibility tree diagnostic and records failed actions independently. A programmatic fallback route is explicitly labelled and cannot count as a passed accessibility action.

## Acceptance boundaries

- The one-window contract is checked against the production main-window constructor, opener, menu targets and module callbacks. The final fixture also closes and reopens the retained window.
- Module enablement and saved order are read back from the original configuration schema. Physical drag gestures and the reorder command are distinct evidence.
- Existing voice/screenshot counts are compared before and after module combinations and disablement. This is not a migration test against every historical user database.
- The Spaces off switch uses the existing reversible window-return barrier. Unit tests cover pending/success/failure/cancellation behavior. This does not qualify real Spaces window dispatch or fix the remaining PR 16 operational gates.
- Cloud capture methods are recorded per image. WindowServer captures and native `NSView.cacheDisplay` fallback captures of visible windows are identified separately.
- QQ Music, NetEase Music, actual simultaneous players, personal microphone permissions and a real installation/update cycle require their own observed evidence. No source test or screenshot substitutes for those observations.

The final `8c884573` results and complete screenshot set are recorded above. This intermediate history is retained for traceability.

## First complete native image set — b2112280

[Run 46050825219](https://github.com/haohongfei2001-png/nearpane/actions/runs/46050825219)
produced 25 actual WindowServer screenshots. Its product code is the preceding
967f540 checkpoint; b2112280 changes the owner's documentation only. These images
precede the settings convergence, equal module ordering and four-edge work, so
they are diagnostic evidence rather than current-constitution visual acceptance.
The native receipt recorded 54 checks, with 46 passing and 8 failing. Menu
target/actions, production module navigation callbacks, retained-window identity
including close/reopen, saved module order and voice/screenshot count preservation
passed. Six SwiftUI accessibility lookups and two paused-hover/control-inspection
checks failed. The accessibility tree contained native view proxies but no SwiftUI
logical identifiers. These failures remain FAIL despite explicit programmatic
routes allowing screenshots to complete. Music setup remained BLOCKED: its last
observed marker was `launch:start`; the probe timed out and then exited Music.

The next DEBUG CI alpha-fixture run enables the documented, writable SwiftUI
[`accessibilityEnabled` environment](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityenabled)
on its real main-window and sidebar roots. This supplies the assistive-technology
environment for native accessibility inspection without running VoiceOver. The
receipt records it explicitly; normal product defaults, system permissions and
playback leases are unchanged. Native input still requires an actual accessibility
action and observed product state. Programmatic routing never substitutes for a
successful input check. The GUI runner also uses the normal AppKit application
event loop for real pointer dispatch.
