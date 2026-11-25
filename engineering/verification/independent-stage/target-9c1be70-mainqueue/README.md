# Real application loop: blocked main queue before dispatch

This controlled run used the `9c1be70d0ebdec27018ecbe94f91f75106e9c976` controller
and the production engine with `NP_SPACES_LAUNCH_TRACE` enabled for diagnosis.
macOS `26A428`, SIP enabled, existing AX access, two disposable foreign processes
and three original-desktop fixture windows were independently confirmed.

The real `NSApplication.run` loop corrected the previous `isRunning == false`
precondition. The trace in `engine.stderr.log` then exposed the next runner defect:
the scenario itself occupied a main dispatch-queue callback while polling a Rust
worker. Its nested `NSRunLoop` pump could not reenter that dispatch queue, so the
worker's canary preparation callback timed out. The trace records `appRunning: 1`,
`phase: main-queue-timeout`, and no opened canary window. Foreign writes remained
**zero** and every migration check remained `NOT_RUN`; no bridge result is implied.

The controller now runs its scenario on a worker queue, leaves the real AppKit main
loop free, and marshals only the NSWorkspace read and final foreground restoration
to that main queue. The fixture quit correction is already verified in this run:
both direct children consumed their normal quit command and exited with status 0.
Final window membership, visibility, geometry and engine cleanup passed. These
raw receipts and their hashes are retained without upgrading the blocked run to a
foreign-window qualification.
