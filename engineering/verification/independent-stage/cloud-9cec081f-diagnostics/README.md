# Both native yellow-button paths and repeated foreign-window switching pass

Original receipts from the **same diagnostics VM** in
[run 45728613871, job 139604696866](https://github.com/haohongfei2001-png/nearpane/actions/runs/45728613871/job/139604696866),
revision `9cec081fe8d125c3106adead51b6662dee811a6d`,
[artifact 15074994332](https://github.com/haohongfei2001-png/nearpane/actions/runs/45728613871/artifacts/15074994332).
The archive SHA-256 was checked against GitHub's digest; `provenance.json` hashes
the three byte-for-byte original receipts copied here.

The actual environment is **26A434, SIP disabled**. Three real windows belong to
two independently running foreign fixture applications; the engine is a third
process. The final original receipt is **FOREIGN_ENGINE_PASS / verified**, with
**cleanup=true**, rather than merely a successful CI job or own-panel probe.

| Actual check in this one VM | Result and scope |
| --- | --- |
| Initial visible bindings | PASS: two existing readback calls for each of the three original standard AX windows, before a foreign-window move |
| First yellow-button action | PASS before any ordinary hide/show; hidden Space 15, same original AX object, complete final double observation at 700 ms |
| Foreign round trip | PASS with exact original desktop, frame and independent bystanders |
| Same-application independence | PASS: only the selected one of two windows exits the ordinary desktop |
| Cross-application grouping | PASS: two applications' selected windows are visible while the other same-app window is hidden |
| Repeated switching | PASS: all three A→B→C→A cycles actually execute through the candidate ABI, with independent readback |
| Later yellow-button action | PASS after all cycles; hidden Space 30, complete final double observation at 654 ms |
| Focus restoration | PASS for the fixture-owned focus witness after exact restoration |
| Final cleanup | PASS: first engine release, all three windows back at original home/frame, zero remaining ownership, full original Space inventory restored in two independent reads |

The two yellow actions activate the fixture's real standard miniaturize button.
The engine migrates the actually minimized original window into its own hidden
Space, verifies that membership, and issues one AX deminiaturization request.
The first completion logs `completeObservations:2`, `expired:false`,
`elapsedMS:700`, `budgetMS:1000`; the later one logs 654 ms with the same complete
double-observation result. Their full operation receipts take about **735 ms**
and **708 ms**, respectively. Neither path reissues the migration or AX request.

During deminiaturization, a temporary extra membership (16 or 31, raw private
type 3) is absent from the fresh complete managed catalogue `[[1,0],[12,0]]`.
The original hidden membership remains present in both directions, and both
managed Spaces exclude the target. Some intermediate CG observations are truly
onscreen with changing geometry. They are unfinished system transitions, never
passing hidden samples. Final success requires the original hidden Space alone,
CG offscreen, original geometry and minimized=false, followed by two complete
reads using the retained original witness. The private numeric type is not a
source of authority.

The later native minimize action also temporarily stops AX responses from a
different already-hidden window in the same app. The original health reader
records AXCannotComplete and then two complete recovered observations, without
moving that window again. Its existing 650 ms health budget remains unchanged;
active deminiaturization has its own 1000 ms budget and ordinary Space move
acknowledgement remains 120 ms.

There are **26 verified engine hide/restore request attempts** across these
scenarios. This is a controlled three-window mechanism and lifecycle result,
not a general workload benchmark. The original receipt explicitly reports
**R4ProductPath=NOT_RUN** and **qualificationGranted=false**. Formal sidebar
clicks, the product AX notification path, other system interactions and the
user's 26A428 / SIP-on Mac require their separate receipts. Results from the full
or R4-fast jobs must not be attributed to this diagnostics VM.
