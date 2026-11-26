# 3437abd5 full: real Finder desktop identity passes; synchronous production rebinding blocks UI

Run [45738564830](https://github.com/haohongfei2001-png/nearpane/actions/runs/45738564830),
full job `139637658403`, source `3437abd5b545cfd25f6eda2ee943c242908ac956`.
This is a separate VM from the fast receipt. Source **164 Rust / 174 Swift
passed, 1 skipped**; complete bundle build and signature checks passed.
The candidate ZIP is **25,337,823 bytes**, SHA-256
`dfedb4a4377fa250bca3a46358b4e763625878602947fcf7e628066b24f49d0c`.
The raw controller returned **FOREIGN_ENGINE_PASS**, including both yellow
button checks, same-app independence, cross-app grouping, repeated switches,
focus and cleanup. This does not qualify the production UI.

## Actual product result

Product **FAIL**, `reason=R4SwitchReadbackFailed`, `actualR4Inputs=1`, cleanup
**true**. The real external AXPress returned **0** and reached the actual card
handler, group choice and navigation queue. All final button fields and all
four context checks passed on this VM. The confirmation Dock observation lasted
2.608 ms with approximately 0.227 ms delivery age, and navigation proceeded.

The original Swift Finder focus checks then **actually passed**: the focused
object was the system Finder's desktop AXScrollArea, its parent was the original
application, its AXWindow was positively `CFEqual` to itself, and the complete
AXWindows list contained it **exactly once**. All twelve recorded checks have
`confirmedDesktop=true`. This proves that specific Swift branch on this VM;
the equivalent C launch check was not reached.

The current-card path established all **three** new bindings, created its
worker and configured the session. It then rejected the initial witness's
opening roster after the last Dock observation had genuinely expired: read
1131.829992–1131.831745, acceptance at 1136.125181, total age **4294.97 ms**.
The unchanged 750 ms rule revoked dispatch. The product did **not** issue
NP_LAUNCH or physically switch the three fixture windows. The worker log and
post-cleanup empty visibility record are preserved; an empty record cannot
prove a successful initial witness.

The failure screenshot visibly contains three real red, blue and green fixture
previews. It is evidence of current-window preview rendering, not hidden-window
preview or successful group scheduling.

## Complete original production stack

The independent sample targeted the exact acceptance Host, PID **39950**,
configured for three seconds at 10 ms intervals, and returned **0**. The complete
**235,407-byte** original stack report and all sampler receipts are included.
The supervisor's final reap timestamp is not the exact sampler end time.

Of **114 Main Thread sample observations**, **104** (97 plus 7) are in
`CurrentDesktopWindows.prepareGroupSelection`'s two physical roster reads:
`StageHostAccess.directoryReader` → `currentSurface` → original AX resolution,
`StageWindowPhysicalReader`, Finder focus checks, AX/CG/Space IPC. Two more are
in that function's current-navigation check. These are production reads on the
UI actor; the acceptance physical sampler already runs off that actor. Counts
are observations, not a wall-time percentage or an unprofiled latency estimate.

This identifies a further ordinary source fix: keep the same complete physical
checks and two-read atomic binding contract, while executing the pure physical
reads outside the UI actor and revalidating navigation and group ownership on
return. The next source implements this per-window read through a Sendable
read-only closure, leaving authorization and all writer objects on the UI actor.
Its existing rebinding regression also rejects new input received during the
last awaited read without committing any group. Native compilation and behavior
of that change await the next run. No freshness threshold is widened and this
archive retains the original failed result.
