# Initial target-machine run: blocked before foreign dispatch

Source: `da51f75a7cdb8a06ed80bcda5121509086dfab75`. The target was Apple Silicon,
macOS 27.0 / `26A428`, with SIP enabled and the controller's existing Accessibility
access confirmed. The two disposable fixture applications were separate from the
controller; no daily Nearpane process or user application was stopped or replaced.

`engine.log` contains two independent baseline reads for each of the three fixture
windows. Their ordinary-Space membership, reverse membership, process identity,
on-screen presence and original geometry agreed. `NP_LAUNCH` then returned detail
217 during its **controller-owned canary**, before the first foreign operation.
The original terminal result is `BLOCKED`, with `windowWrites: 0`; all foreign
round-trip, grouping, minimization and R4 checks remained `NOT_RUN`.

The following [controlled own-panel diagnostic](../target-own-panel-runloop-20261126.json)
isolated the engineering cause: manual `NSRunLoop.runUntilDate` kept
`NSApplication.isRunning` false and failed the canary's preparation/focus
precondition. The same platform implementation entered through `NSApplication.run`
created, read and closed its own transparent panel successfully. The controller
has been corrected to enter the real AppKit loop before starting the scenario.
Neither result is evidence that a foreign window can or cannot migrate.

The engine's final independent checks returned all enrolled windows to their
baseline and confirmed that no session-owned Space remained. Both fixture apps
acknowledged their `quit` command (sequence 1) and closed their windows, but the old
timer callback used `NSApp.stop`, which did not wake the application event wait.
The Python owner therefore terminated its direct children after the bounded wait,
as preserved in `fixture-cleanup.json`. The fixture now uses `NSApp.terminate`;
this was an application-loop exit defect, not missing permission or unconsumed IPC.

The raw JSON also preserves the original Objective-C integer `1` fields for
`foreignProcesses`, `sipEnabled` and `exactTarget`. These are not silently rewritten
as Boolean acceptance evidence. New controller receipts explicitly encode those
fields with `NSNumber.numberWithBool`; the evaluator continues to require actual
Boolean values. `summary.json` records the original payload hashes and the limited
claim supported by this run. No release qualification is granted.
