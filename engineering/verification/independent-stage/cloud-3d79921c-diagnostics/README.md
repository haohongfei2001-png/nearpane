# Foreign-window regression passes after the Finder launch adaptation

Original receipts from
[run 45731326197, job 139613767303](https://github.com/haohongfei2001-png/nearpane/actions/runs/45731326197/job/139613767303),
revision `3d79921c5a9479a92173b4bfec837a08d14b227b`,
[artifact 15076742527](https://github.com/haohongfei2001-png/nearpane/actions/runs/45731326197/artifacts/15076742527).
The downloaded ZIP hash matches GitHub's digest; `provenance.json` hashes the
three byte-for-byte original files. This diagnostics VM is **26A434 / SIP off**.

The original result is **FOREIGN_ENGINE_PASS / verified**, with all ten reported
checks passing. Its 34 engine receipts are individually verified and include
the six initial visible registrations, first yellow-button action, ordinary
foreign round trip, same-app independent windows, cross-app grouping, all three
A→B→C→A cycles, later yellow-button action, focus and final cleanup.

| Actual native operation | Complete retained-witness double read | Overall operation |
| --- | --- | --- |
| First yellow action before ordinary hide/show | 646 ms, original hidden Space 15 | 675 ms, PASS |
| Later yellow action after three switching cycles | 636 ms, original hidden Space 30 | 663 ms, PASS |
| First final release | All retained windows returned; owned=0 | 126 ms, PASS |

Both deminiaturization completions have `expired=false` within their separate
1000 ms budget. The final views still require original AX identity, exclusive
original hidden membership, CG offscreen, unchanged frame and minimized=false.
Intermediate extra non-managed membership and visible system animation remain
unfinished observations. The same-app hidden sibling's temporary AXCannotComplete
again recovers through two complete observations without a repeated move.

The run executes 26 engine hide/restore requests. Final cleanup independently
confirms all three fixture windows at their original home/frame and the complete
original Space inventory in two reads. No scheduler change was needed after
the previous passing diagnostics result.

The new C Finder desktop branch **compiled**, but this raw engine controller
first focuses a fixture's ordinary window. It therefore does not establish the
Finder self-containing AX relationship. That predicate must be measured by the
separate formal R4 path. This receipt explicitly retains **R4ProductPath=NOT_RUN**
and **qualificationGranted=false**; neither another job's product behavior nor
the user's 26A428 / SIP-on environment is claimed here.
