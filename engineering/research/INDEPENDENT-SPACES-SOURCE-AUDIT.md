# Independent Spaces: source audit

Audited 2026-11-26 (Asia/Shanghai). Product authority: [independent-stage decision](NEARPANE-INDEPENDENT-STAGE-DECISION.md).

This audit distinguishes executable source, upstream author observations, and Nearpane's own system receipts. An upstream claim or own-window probe is not third-party-window acceptance on the user's Mac.

## Pinned sources and permitted reuse

| Project | Audited revision | Licence at that revision | Use here |
| --- | --- | --- | --- |
| [stage-manager](https://github.com/eugene-tea/stage-manager/tree/19e6e490bc91e65cef6a782075b5450e3159fd2d) | `19e6e490bc91e65cef6a782075b5450e3159fd2d`, latest HEAD and v1.9.2 at audit | [MIT](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/LICENSE) | Continue the existing attributed mechanism extraction; retain its notice. |
| [stage-manager v1.9.1](https://github.com/eugene-tea/stage-manager/tree/69a73665488243bf78982c6d523ac4e0850c1ddb) | `69a73665488243bf78982c6d523ac4e0850c1ddb` | MIT | Historical extraction baseline. |
| [DockDoor](https://github.com/ejbills/DockDoor/tree/c5be55e9fca3d2bf5ed89b886f6967062c137295) | `c5be55e9fca3d2bf5ed89b886f6967062c137295` | [GPL-3.0-or-later](https://github.com/ejbills/DockDoor/blob/c5be55e9fca3d2bf5ed89b886f6967062c137295/LICENSE) | Corroborate the runtime selector/ABI mechanism. No source copied in this change. |
| [yabai](https://github.com/asmvik/yabai/tree/477e859d26dd4489095c55057692abfe809e7502) | `477e859d26dd4489095c55057692abfe809e7502` | [MIT](https://github.com/asmvik/yabai/blob/477e859d26dd4489095c55057692abfe809e7502/LICENSE.txt) | Corroborate managed-desktop moves and their asynchronous nature. |
| [Spacetile](https://github.com/Spacetile/Spacetile.app/tree/903cd4bc38ac4f5ef5430ba73967abbb6a08727f) | `903cd4bc38ac4f5ef5430ba73967abbb6a08727f` | [Spacetile Source Licence 1.1](https://github.com/Spacetile/Spacetile.app/blob/903cd4bc38ac4f5ef5430ba73967abbb6a08727f/LICENSE), source available | Research only; no source copied. Its ordinary-desktop result does not prove hidden-Space compatibility. |

## The actual hidden-Space mechanism

[Upstream `ffi.rs`](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/spaces/ffi.rs) and [the engine](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/spaces/engine.rs) implement:

1. `SLSSpaceCreate(connection, 1, 0)` creates a classic, connection-owned Space. The engine never makes this Space visible and never registers it as a user Desktop.
2. `SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation`, initialized with `initWithSpaceID:windows:options:`, is performed using `performWithWMBridgeDelegate`.
3. Hiding uses mask `7` to remove the window from managed Desktops while adding it to the hidden Space. Showing uses mask `0xf` to remove every Space category, including the hidden one, and add the window to its recorded home Desktop.
4. `SLSCopySpacesForWindows` uses `0xf`, not `7`, when reading membership. The latter can omit the private Space and produce a false empty result.
5. Return values alone do not prove success. Nearpane also reads the target Space's occupants and the public on-screen window list, and retains the window's AX identity and process birth.
6. Only empty, session-created Spaces are destroyed by Nearpane. The upstream author describes connection-owned Spaces disappearing at process exit; that observation does not establish exact home-Desktop restoration after a crash on the target device.

The upstream header explicitly attributes its foreign-window experiment to macOS **27.2**. It is source evidence for a plausible implementation, not a macOS **27.0 / 26A428 / SIP enabled** acceptance receipt.

## What must not be imported

- [`engine_choice.rs`](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/engine/engine_choice.rs) chooses Corner after a failed or missing launch probe and also after runtime health loss. Nearpane's candidate has no such fallback.
- [`probe.rs`](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/spaces/probe.rs) tests only the process's own transparent NSPanel. Its `WORKS` verdict explicitly says this. A successful launch does not grant third-party qualification.
- [Upstream architecture](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/docs/ARCHITECTURE.md) and [`rounds.rs`](https://github.com/eugene-tea/stage-manager/blob/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/spaces/rounds.rs) temporarily lend windows to a Desktop after moving them to a corner for Mission Control, App Expose, and some app-switcher interactions. Nearpane restores real windows at their actual layouts for native takeover instead.
- The same architecture document says macOS can pull a window back onto a Desktop when its native minimized state is cleared. Upstream uses a Dock-edge placement for that path. Nearpane does not copy it. Its post-minimize transaction clears AXMinimized only after hidden membership is proven, then verifies membership and invisibility again. A window pulled back by macOS fails this experiment; it must never be labelled a successful hidden-window result.

## Changes since the old fixed version

For `src/platform/spaces/`, `src/engine/model/spaces.rs`, `src/engine/spaces.rs`, and `src/engine/engine_choice.rs`, v1.9.1 to v1.9.2 changes **9 files, 1,963 additions and 162 deletions**. The important areas are display/Desktop rehoming, WindowServer notices, app-switcher timing, batched Mission Control lends, and stale app-activation suppression. These fixes justify reading the latest source; they do not justify copying the Corner-dependent portions wholesale.

## Independent ordinary-Desktop corroboration

[DockDoor's `PrivateApis.swift`](https://github.com/ejbills/DockDoor/blob/c5be55e9fca3d2bf5ed89b886f6967062c137295/DockDoor/Utilities/PrivateApis.swift) uses `SLSBridgedMoveWindowsToManagedSpaceOperation` with `initWithWindows:spaceID:` and the operation's `performWithWMBridgeDelegate` method.

[yabai's `space_manager.c`](https://github.com/asmvik/yabai/blob/477e859d26dd4489095c55057692abfe809e7502/src/space_manager.c) uses that managed-move class with a resolved asynchronous bridge function. The maintainers' [issue #2788](https://github.com/asmvik/yabai/issues/2788) records SIP-enabled ordinary-Desktop moves on Tahoe 26.4/26.4.1.

[Spacetile's `WindowSpaceMove.c`](https://github.com/Spacetile/Spacetile.app/blob/903cd4bc38ac4f5ef5430ba73967abbb6a08727f/Sources/CSkyLight/WindowSpaceMove.c) uses the managed-move class and resolves the asynchronous bridge entry. Its [build documentation](https://spacetile.app/docs/build/) reports checks on macOS 27.0 with SIP enabled. These mechanisms move windows between ordinary managed Spaces; none is evidence that the add/remove operation can place a foreign window into Nearpane's private hidden Space on the target machine.

## Nearpane evidence classification

The old `9509bd04dbf0178f452a06b690d51896432b05f3` canary mechanism and the own-panel success recorded in the main decision remain valid as **own-process** evidence. The later [first-window report](../verification/window-engine/first-window-26A428/verification.json) records `firstMutationDispatched: false`, `writtenThirdPartyWindows: 0`, and `thirdPartyMembershipRoundTrip: NOT_RUN`. Its single-instance and Host admission problems are engineering blockers, not evidence of a refused WindowServer foreign-window move.

The new candidate therefore exposes an explicit independent-Spaces transport, keeps launch evidence separate from third-party and R4 product results, and supplies a unified external-fixture experiment. Production claims depend on those results, not on symbols, compilation, synthetic tests, or the own-panel probe.
