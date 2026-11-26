# 350e fast: real R4 input, stale delivery before the group job

Source `350e848cc30106c32156ddba2c222ab639ab141f`;
[run 45883578306](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306),
fast job 140128627980,
[artifact 15148907796](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306/artifacts/15148907796).
Hosted macOS 27.0.1 / 26A434 / arm64 / SIP disabled. This is the foundation/debug
build of the production R4 Host, not a complete companion-workspace candidate.

## Actual result

- The foreign-window engine's ten checks and physical cleanup pass in this VM.
- The external helper positively confirms the button's retained AX panel and
  issues one AXPress, with error 0. The actual product handler submits the group
  choice to the production navigation lane.
- Its Dock confirmation reads from uptime 438.783172667 to 438.793752250:
  **10.579583 ms** of native reading. Acceptance runs at 439.695729458, when the
  read has already aged another **901.886375 ms**. The unchanged 750 ms boundary
  correctly withdraws ownership. This is not time spent waiting for sampling to
  begin.
- No group job, initial retained-window witness or NP_LAUNCH follows that input.
  **Product FAIL / R4SwitchReadbackFailed / cleanup PASS** is the actual result.
  Cold hidden preview, group editing, crash/restart and lifecycle cases remain
  NOT_RUN. No held-preview or completed switch is established by the saved image.
  The failure screenshot itself contains an empty R4 panel, not visible window
  previews.

## Observed UI work and bounded correction

The entire Host sample is retained: 73 main-thread observations, sampled for
three seconds at 10 ms intervals from the exact controlled Host PID. It includes
SwiftUI rendering through `rawOverview`, `panelAvailable`, `canNavigate` and
`picturesAllowed`, repeatedly querying the console session, plus gallery
snapshot/visibility closures and pixel admission. The sample was initiated
before this later input; its observation counts do not quantitatively assign the
901.886375 ms delay to individual functions. The supervisor's final reap time is
not a longer sampling duration.

The next UI correction uses existing observed state for drawing buttons and
requesting gallery work, while preserving fresh checks for actual actions and
every image admission. An empty historical pixel cache can return nil before any
native read. This does not widen 750 ms, grant access from presentation state,
relax unknown native state, or establish that all remaining UI stalls are fixed.

The original engine and product receipts, stderr, complete sample and failure
image are copied byte-for-byte; `provenance.json` records their hashes. Source
results come from the separate full lane of this same revision: 166 Rust and
174 Swift checks pass, with one Swift skip. The fast lane does not independently
rerun those tests or qualify a complete package.
