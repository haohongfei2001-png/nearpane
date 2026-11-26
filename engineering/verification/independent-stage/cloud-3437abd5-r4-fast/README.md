# 3437abd5 fast: actual Host stack identifies synchronous first-frame AX work

Run [45738564830](https://github.com/haohongfei2001-png/nearpane/actions/runs/45738564830),
source `3437abd5b545cfd25f6eda2ee943c242908ac956`.

Source checks passed: **164 Rust**, **174 Swift and 1 skipped**, plus native
helpers, worker protocol and evidence checks. The foundation Host compiled with
the new gallery departure handling. This VM's raw foreign-window controller
returned **FOREIGN_ENGINE_PASS**, with both yellow-button checks, repeated
switches, same-app independence, cross-app grouping, focus and cleanup passing.

## Actual R4 result

Product **BLOCKED**, `reason=realExternalR4ButtonNotAccepted`,
`actualR4Inputs=0`, cleanup **true**. The exact external button's final batch
positively read its role, identifier, enabled state, position, size and
AXWindow attribute. Button owner and containment inside the fresh CG panel were
also positive. The subsequent AXWindow-to-CG-panel mapping returned false
(`windowMatches=false`), so no AXPress was issued. The original helper did not
record the mapping's inner error/value and cannot distinguish an incomplete
mapping read from a positively different window. No substitution or retry is
claimed. No Finder self-reference check or product NP_LAUNCH ran.

The Dock trace later records an actual read lasting 13.52 ms whose age at
delivery was 2873.53 ms. It correctly expired under the unchanged 750 ms rule.
This instrumented run cannot by itself quantify unprofiled latency; earlier
unprofiled receipts already document actual stale deliveries.

## Exact Host stack observation

The external `/usr/bin/sample` targeted the directly launched acceptance Host,
PID **16128**, with a configured three-second duration and 10 ms interval. It
returned exit **0**. The complete original stack report, tool logs and supervisor
receipt are included, not just selected frames. The supervisor's final reap
timestamp is not the sample command's exact end time.

The report contains **83 Main Thread sample observations**. In **14** of them,
the stack is:

`DesktopWindowGallery.consume` → `Live.original.getter` →
`StagePictureOriginal.init/exact` → `windows` → native AX attribute/count
requests → Mach message wait.

This directly confirms synchronous AX work in the initial compositor-frame
publication path. Those counts are sample observations, not a claim that this
path explains the entire observed delay. Other main-thread samples include
SwiftUI layout and card rendering with session/surface IPC. The current SCK
image and independent held-image lookup do not consume `Still.original`;
observed groups acquire their own original binding. Cross-appearance/native
history does need an original object acquired before departure, so optimization
must preserve that distinction rather than recreating identity afterward.

The first external-press Host wait remains asynchronous. Stack sampling is
diagnostic only: it changes no action, window identity, membership, freshness or
qualification gate. Product held-preview and later lifecycle/system behavior
remain unverified. All included files are byte-for-byte originals with SHA-256
provenance.

## Narrow changes prompted by these receipts

The next source removes eager acquisition of `Live.original` for ordinary
current frames and independent held frames, which do not consume that history
object. Native-stage history still acquires it; observed groups retain their
own binding, and independent held pictures retain their engine witness. No
freshness interval or identity, owner or sharing check is relaxed.

The external helper now checks that the button's positively returned AXWindow
is `CFEqual` to the exact retained panel already identified by AX and CG. This
removes the duplicate canonical-number request while strengthening the direct
original-object relationship. Unknown or different AXWindow values still
reject the button. These changes await new native receipts; they do not change
the failed outcome above.
