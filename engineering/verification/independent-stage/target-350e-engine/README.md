# Target Mac: foreign hidden-Space engine passes with SIP enabled

Source: `350e848cc30106c32156ddba2c222ab639ab141f`.
Executed through the unified runtime entry on **macOS 27.0 / 26A428,
Apple Silicon, SIP enabled**, on the logged-in console with AX access.
Original output: `/private/tmp/nearpane-independent-350e-runtime-20261127`.
`provenance.json` records the paths, exact byte lengths and SHA-256 hashes of
the seven unmodified originals copied from the target. `entry-summary.json`
is the original top-level summary, not a regenerated result.

## Actual foreign-window result

The raw controller reports **FOREIGN_ENGINE_PASS / verified**. All **34 engine
receipts**, all **10 checks**, and all **68 independent window readbacks** pass;
each independent readback has two complete observations. This exercises the
production candidate ABI against two separate disposable application processes,
not just the controller's own transparent canary:

| Fixture | Process | Window IDs | Initial ordinary home |
| --- | --- | --- | --- |
| A | 44427 | 121043, 121045 | 4 |
| B | 44433 | 121048 | 4 |

The run verifies six initial original-window bindings, a real yellow-button
action before any ordinary hide/show, a foreign round trip, independent
scheduling of two windows from one app, cross-app combination, three complete
A→B→C→A cycles, a later yellow-button action, exact-window focus restoration,
and release. There are **26 hide/restore request attempts**. These are real
foreign-process windows; this run does not establish compatibility with every
third-party application or exercise the R4 buttons.

The first release completes in **537.5 ms with owned=0**. Two final complete
observations confirm all three original window identities, frames and exclusive
home `4`, together with the exact original **16-entry Space inventory**. Engine
release and destruction are both confirmed. Both fixture processes then exit
normally through `ownedWindowQuit`, with exit code 0. **Cleanup PASS**.
The `enrolledWindows` bookkeeping fields retain some pre-release hidden flags;
the independent final readbacks, rather than those bookkeeping flags, establish
the actual restored state.

## New decisive observations

The canary's two original-home observations complete at **3 ms and 145 ms**,
both with forward home `4` and positive reverse membership. The second reports
**waitMS=138, panelReadMS=2, systemReadMS=0**. The requested worker wait was
4 ms. The two corresponding main-queue waits are **0.055 ms / 0.024 ms**, and
the panel/focus calls take **2.645 ms / 2.158 ms**. In this run, the extra time
is therefore in the worker's elapsed wait, not a slow main-thread AX query.
The dedicated 650 ms initial-discovery budget admits both complete observations;
the ordinary Space-operation acknowledgement budget remains 120 ms.

This does not identify the scheduling cause as App Nap, QoS, timer coalescing or
load, and it does not retroactively locate the delay in the earlier 8805 run.
Neither that earlier blocked receipt nor the ordinary acknowledgement budget
has been rewritten.

Own panel `121057` then moves to hidden Space `6979`, returns to home `4`, and
closes. The close observation actually encounters **Readback 217** once and
records `close-cg-readback`, then the existing bounded read-only observation
finishes successfully. This directly exercises the close-recovery branch on
the SIP-enabled target without a repeated close or move.

Both real yellow-button actions retain the originally bound standard AX object
when the system temporarily reports its subrole as `AXDialog` while minimized.
Each issues its hidden migration and active deminiaturization once. Actual
settling evidence is:

| Phase | First yellow action | Later yellow action |
| --- | --- | --- |
| Original private hidden Space | 6981 | 6996 |
| Additional temporary membership | 6982, raw type 3, at 519 ms | 6997, raw type 3, at 557 ms |
| First complete settled hidden observation | 717 ms | 705 ms |
| Second complete settled hidden observation | 918 ms | 918 ms |
| Final two-read completion | **925 ms** | **927 ms** |

During the temporary additional membership, CG genuinely reports the window
on-screen with animated geometry and AX temporarily returns CannotComplete.
That state is not accepted as hidden. Both final observations require the
original hidden Space exclusively, bidirectional membership, absence from every
managed desktop, CG off-screen, original frame and minimized=false. Raw type 3
is recorded diagnostically and does not authorize success.

The already-hidden same-app sibling has one passive AXCannotComplete at
**162 ms**, then two complete positive observations recover health at
**530 ms**, without another move. This run does not consume the health grace
beyond the ordinary 650 ms observation limit.

## Scope and performance limits

Ordinary hide/return receipt durations in this run range from **196.3 to
405.2 ms**, with median **347.8 ms**. These include controller polling and
queued work, so they are not direct WindowServer move latency measurements.
The raw controller retains its 4000 ms request limit. This run does not qualify
the product transport's 3000 ms minimize or 2000 ms ordinary/health request
limits, nor does it demonstrate production interaction latency.

`entry-summary.json` correctly records **exactTargetEngine=PASS** and
**overall=INCOMPLETE**. **R4ProductPath=NOT_RUN** and
**qualificationGranted=false** remain unchanged. Formal R4 interaction,
merge/split, hidden previews, window/app lifecycle, desktop reveal/switch,
Mission Control, App Exposé, fullscreen/split view and crash recovery need
their separate actual product receipts. This engine result grants no release
qualification and makes no claim for those unexecuted paths.

## Source regression run on the same target

The exact existing Cargo suite was subsequently run against350e on this target:
`--locked --offline --no-default-features --features corner,spaces,isolated-fixtures`.
**166 tests passed, zero failed**, including both new home-discovery regressions.
`rust-tests.log` preserves the complete compiler/test output separately from the
physical runtime. No source test is substituted for the native effects above.
