# Independent Stage — implementation and evidence

Branch: `pro/independent-stage-engine-20261126` · [Draft PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
Implementation started from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
PR #16 currently targets `main`; the product constitution on `main` was rechecked
and matches this branch.
The [single product/technical decision](../../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md) governs this work.

## Current source/runtime checkpoint: ac252b5a

Exact source passes **180 Rust, 273 Swift (one existing skip), and 25 native
AX decoder checks**; the complete candidate and strict signature pass. The
three new original-member handoff test functions execute all 28 cases.

Fast records **three actual inputs and two external physical confirmations**.
The first transaction safely yields to the next input. The second queued exact
member completes SHOW, READBACK, both full post observations, exact focus, HIDE
and final commit in **1735.452 ms**; its external confirmation is **1470.543 ms**.
The third SHOW fails after one complete positive native view takes **167.657 ms**,
past the original combined 120 ms move-confirmation budget. Its membership was
read after the slow AX observation, so this run does not prove timely landing.
A separate **670.610 ms** interval before a metadata producer is created remains
unattributed; the next source adds precise timing around the existing checks.

Full records **ten actual inputs and ten external physical confirmations**,
with all 115 worker requests successful. The first nine selections safely hand
off confirmed prefixes; they are not nine committed transactions. The harness
checks the hidden group for its next scenario before the final transaction
finishes and stops with `crossAppSourceNotHeld`. Later witness cancellation
occurs after cleanup has started. The next source waits for the original
selection's real completion only at the two dependent join/split phase boundaries.

The native correction explicitly separates timely membership acknowledgement
from complete positive confirmation: **120 ms** for the former, **650 ms total**
for two complete positive views, both measured from the original single move's
return. Transient error retries retain the original 120 ms limit; every positive
result must pass authority and deadline checks. This is a confirmation-budget
change and still needs exact-source native verification.

[Exact ac252 source/runtime evidence, successful member handoff and distinct remaining failures](cloud-ac252b5a-latency/README.md).
Both original-owner releases and independent double home checks pass. Continuous
R4 acceptance, later interaction/lifecycle gates and exact-target GUI acceptance
remain incomplete. Release qualification remains false.

## Earlier source/runtime checkpoint: d86660db

Exact source passes **180 Rust, 270 Swift (one existing skip), and 25 native
AX decoder checks**; the complete candidate and strict signature pass. All
thirteen new metadata scheduling cases execute successfully. Both unsampled
R4 lanes complete the first real switch, with two HIDE primitives, exact focus,
READBACK and both complete Host confirmations.

Fast/full each record **two actual inputs, one external physical confirmation
and one completed internal transaction**. First external confirmation takes
**1337.591 / 1550.422 ms**; transaction completion takes **1670.221 / 1850.259 ms**.
The next press reaches an old current card during final verification, after its
ordinary appearance correctly expires but before the held-card handoff. It is
rejected before navigation submission. No product SHOW is issued.

All thirteen metadata scopes in each lane reserve, drain and end; real prior
producer/publisher drains are observed. There is no incomplete-directory or
worker failure in these runs. The next repair is the explicit original-member
selection handoff into the existing stage queue, with fresh held-group checks.
It must not preserve expired ordinary appearances or turn pictures into permits.

[Exact d866 source/runtime evidence, scope ordering and second-click handoff](cloud-d86660db-latency/README.md).
Both real-hide recoveries and independent two-read home checks pass. Continuous
R4, exact-target GUI acceptance and release qualification remain incomplete.

## Earlier source/runtime checkpoint: 7aea52c5

Exact source passes **180 Rust, 263 Swift (one existing skip), and 25 native
AX decoder checks**; the complete candidate and strict signature pass. All ten
new deterministic shared-publication cases execute successfully. Both unsampled
R4 lanes receive one actual input and confirm no complete switch; neither
exercises the new initial staging branch in this run.

Fast verifies the exact selected focus and two HIDE primitives, then loses the
transport epoch after a background read observes the second target's membership
transition. Full stops during initial binding after a different background read
adds two role-unknown small surfaces. The observed revocations and source path
identify a wider metadata scheduling problem; they do not justify ignoring
incomplete snapshots or widening retry rules.

[Exact 7aea source/runtime evidence, event ordering and recovery](cloud-7aea52c5-latency/README.md).
Both original-owner cleanups and independent two-read home checks pass. Continuous
R4, exact-target GUI acceptance and release qualification remain incomplete.

## Earlier source/runtime checkpoint: 987215dc

Exact source passes **180 Rust, 258 Swift (one existing skip), and 25 native
AX decoder checks**; the complete release build/signature pass. Unsampled full
receives two real inputs and records external physical confirmations at
**2183.082 / 4398.461 ms**. Three HIDE, one SHOW and focus confirmation pass,
but the second transaction subsequently fails in its final roster confirmation.
Two physical confirmations are not two committed transactions. Unsampled fast
exercises the existing initial retry, then loses its original intent before
the complete retry result can finish validation.

[Original 9872 evidence, initial publication race and late role-access failure](cloud-987215dc-latency/README.md).
[Previous 2d7d source/runtime evidence and distinct prewrite failures](cloud-2d7d1beb-latency/README.md).
The next product change stages only the qualifying first incomplete prebinding
result before shared mutations/publication; it preserves the existing fresh
retry, all subsequent failure rules and the original hidden-Space backend.
Both recoveries pass, but continuous R4 and exact-target GUI acceptance remain
incomplete. Release qualification remains false.

## Earlier source/runtime checkpoint: caa2e0aa

Exact source passes **180 Rust, 255 Swift (one existing skip), and 25 native
AX decoder checks**; the complete release build/signature pass. Unsampled full
confirms one real R4 switch in **1890.56 ms**. Its next SHOW succeeds, but the
first full confirmation after focus rejects an unbound directory item's
changing membership. Unsampled fast stops earlier at live-window binding, before
a worker exists. Both Host releases and independent two-read home checks pass.
Continuous R4 operation and release qualification remain incomplete.

[Original caa2 source/runtime evidence, precise post-focus failure and click cost partition](cloud-caa2e0aa-latency/README.md).
The initial-directory retry passes 43 parameter cases but is not exercised by
either runtime lane. The next diagnostic change adds first-failed binding
conditions and bounded existing facts about rejected catalog rows; it does not
ignore those failures or expand the retry to already-bound windows.

## Earlier initial-read checkpoint: 1e5d357a

Exact-source validation passes **180 Rust, 248 Swift (one existing skip), and
25 native AX decoder checks**; the complete application and strict signature
pass. Both R4 lanes receive one real input and confirm zero switches: full
rejects an inconsistent opening roster before binding, while sampled fast loses
dispatch after delayed Dock callbacks. Neither reaches managed-window HIDE/SHOW.
Both cleanups and independent two-home reads pass; release remains unqualified.

[Original 1e5d source/runtime evidence and the distinct initial-read failures](cloud-1e5d357a-latency/README.md).

## Earlier R4 latency checkpoint: 5e3a7ea4

The complete, unsampled release candidate confirms its first actual R4 selection in
**1906.94 ms**, versus **4798.33 ms** for the corresponding d614f58d step. Its second
SHOW lacks a complete acknowledgement; sampled fast confirms two of three inputs
before a separate passive-health timeout. Both current Hosts release successfully
and receive independent two-read home confirmation. The exact target source gate
passes 180 Rust and 248 Swift cases (one skip); cloud source has eight failed reader
fixture functions. The complete release build/signature pass, but source and R4
acceptance remain failed. These results do not grant release qualification.

[Exact source/runtime evidence, non-overlapping click timelines and remaining failures](cloud-5e3a7ea4-latency/README.md)
are preserved with original hashes. The subsequent AX attribute batch and native
test-fixture changes require their own native verification.

## Implemented product path

The complete Swift Host keeps the R4 surface and embedded voice/screenshot/file modules. R4 thumbnail
selection reaches the independent group coordinator and the Rust Spaces engine. The candidate neither
selects Corner nor mirrors Apple's strip. A separately signed, sealed worker retains the same Rust engine
and original AX leases across Host exit; losing the anonymous pipe enters release-only cleanup. The
worker still uses the existing static library and C ABI, not a second window-management implementation.

| Behavior | Main implementation |
| --- | --- |
| Real hidden retirement and return | `Engine/nearpane-window-engine/src/spaces`, `LinkedSpacesEngineTransport` |
| Group switching, member focus, last minimized group, z order | `StageGroupCoordinator`, `StageWindowEngine` |
| Physical identity, ordinary home and visibility readback | `StageWindowEngineWitness`, `StageHostWindow`, `StageWindowPhysicalReader` |
| Actual R4 card, merge/detach and yellow minimize | `DesktopSurface`, `StageGroupPictures`, `IndependentStageGroupEditing`, `IndependentStageMinimizeObserver` |
| Native system handback and focused-group resume | `StageWindowEngineHost`, `DisplayPanels` |
| Isolated full workbench and packaging | `NearpaneApp`, `CandidateProfile`, `IndependentStagePolicy`, `package.py` |
| Controlled foreign windows, real product presses and cleanup | `scripts/acceptance/independent-stage/run.py`, `controller.m`, `IndependentStageAcceptance.swift` |

These are code-completion claims. The evidence below determines which native effects have actually passed.

## Executed evidence

| Source/environment | Observation | Meaning |
| --- | --- | --- |
| Historical `9509bd0`, target 27.0 / 26A428, arm64, SIP enabled | Own panel entered hidden Space 5643, returned to ordinary home 4, empty Space destroyed | Own-window mechanism established; foreign writes were zero |
| `da51f75`, same target | Two independent fixture apps/three windows read twice with AX and identity; launch rejected with detail 217; cleanup passed | Foreign writes zero; own-panel preparation blocked |
| `9c1be70`, target diagnostic | Actual `NSApplication.run` succeeds where manual run-loop pumping did not; main-queue callback reentry then timed out | Harness defect, not failed foreign migration |
| Target focus contrast | Global AX focused-application call failed; direct front-app AX focused-window and CG ID succeeded | Production and canary now verify front process birth/owner and exact focused AX window directly |
| Corrected own-panel focus/run-loop diagnostic, target | Prepare/open/read/close succeeded and original focus matched | No Space creation or foreign migration performed in this diagnostic |
| `2a0cfbe9b16675905237ab1917fe48b9a61d8789`, hosted macOS 27.0.1 / 26A434, SIP disabled | Source step and full release/resource checks passed; later standalone-executable signature check used the wrong bundle context | Fixed at `283831ef` by sealing and verifying the complete bundle |
| `283831ef8fdd452a50dd8a637d8a501ba9efb0ae`, same hosted environment | Source, complete workspace build, bundled worker C/protocol, strict/deep bundle signature and ZIP passed | Actual downloadable development candidate; no release qualification |
| Same `283831ef` runtime | AX trusted; ordinary-desktop preflight blocked before enrollment/canary; foreign writes zero; both fixtures exited normally | `NOT_RUN` for foreign migration; product cleanup also exposed a read-adapter defect, not migration failure |
| `3493f968`, same hosted environment | 150 Rust, 151 Swift and 8 Python passed; 1 signed live-fixture case skipped; complete candidate and strict signature passed | Latest fully source-checked candidate checkpoint at that run; [original evidence](cloud-3493f968/README.md) |
| `a73454a1`, native renderer controls | AutoHide left-edge reveal and zero-row baseline both show actual native tilted thumbnails; 13 samples each; complete restoration | Both configurations rejected; [original AX/CG, pixels and restoration](cloud-a73454a1/README.md) |
| `a73454a1`, desktop initialization | System created ordinary Space 12 with a real UUID; selection became current after the helper's early deadline; cleanup restored original Space 1 | No foreign writes; helper timing failure is not a failed migration |
| `6558c2d5`, diagnostics | New raw platform diagnostic compiled; temporary native-desktop cleanup failed its first animation-time read, then completed | No fixture/platform move executed; [original preparation and cleanup](cloud-6558c2d5-diagnostics/README.md) |
| `bdedf131`, hosted platform experiment | Two external processes' windows completed four real hidden/return moves; same-app sibling unchanged; two full observations per stage; owned hidden Space emptied and destroyed | `PLATFORM_FOREIGN_PASS` on 26A434/SIP disabled; [original evidence](cloud-bdedf131-platform/README.md). Engine/R4 not run, target not qualified, separate ordinary-desktop cleanup unconfirmed |
| `6558c2d5`, full lane | 150 Rust, 153 Swift and 17 Python passed; one signed live fixture skipped; complete candidate and strict signature passed; platform foreign result repeated | R4 sees all three correct fixtures but `catalogComplete=false`; no R4 input yet. [Candidate and product receipt](cloud-6558c2d5-full/README.md) |
| `e630b6bc`, diagnostics | Two foreign hidden/return cycles on original home 1, four writes, hidden Space 12 emptied/destroyed; no ordinary desktop created | Independent platform replication with cleanup; engine/R4 remain separate. [Original result references](cloud-e630b6bc-diagnostics/README.md) |
| `e630b6bc`, full lane | Real ordinary Desktop 12 initialized and later removed; final original inventory restored exactly; full candidate passed | CI-only desktop cleanup fixed and independently verified; [original receipts](cloud-e630b6bc-full/README.md) |
| `5e458d1d`, full lane | 150 Rust and 154 Swift passed, one explicit skip; complete candidate/signature passed; three real R4 windows correctly identified | Activation request declined before canary; 15 unknown-membership CG surfaces blocked catalogue completeness, no R4 input. [Exact observations](cloud-5e458d1d-full/README.md) |
| `81669d13`, normal-engine diagnostics | Main/Frontmost writes and final true focus succeeded; an additional preparation requirement still stopped canary | Zero engine hide/restore requests; [original focus and cleanup evidence](cloud-81669d13-engine/README.md) |
| `5607d3b3`, full lane | 150 Rust, 156 Swift and 17 Python passed, one explicit skip; complete candidate/signature passed; normal engine canary, foreign round trip, same-app separation and cross-app combination passed | Repeated switching exposed aggregate ownership being misread as target ownership; nine hide/restore attempts include a rejected cleanup request. R4 not run. [Original engine and candidate evidence](cloud-5607d3b3-full/README.md) |
| `81669d13`, full R4 readiness | Complete catalogue, three distinct fixture groups, Spaces capability, ordinary system context, real previews and visible formal panel all confirmed | The strict button search found no input; zero presses. This proves the earlier reader fix worked, not a completed R4 switch. [Original product receipt](cloud-81669d13-r4/README.md) |
| `bbc08a09`, diagnostics and source | 151 Rust and 156 Swift passed, one explicit skip; normal engine canary and three A→B→C→A cycles passed, with 22 confirmed hide/show requests | The yellow request was rejected after an earlier health failure; final physical readback still found A1 in hidden Space 24. Cleanup genuinely failed. [Original engine, traces and source result](cloud-bbc08a09-diagnostics/README.md) |
| `bbc08a09`, separate full VM | Source checks, complete candidate and strict signature passed; own canary reached hidden Space but return did not confirm, leaving Space 13 | Zero foreign requests and R4 not run; this VM does not inherit the diagnostics VM's group-cycle success. [Original package and runtime evidence](cloud-bbc08a09-full/README.md) |
| `3bcb0640`, diagnostics | Own panel acquired home in 4/24 ms and passed hidden-view; finish-canary returned Identity; bounded release on the original engine then completed physical cleanup | Zero foreign requests, BLOCKED rather than a failed foreign move; yellow behavior was not re-exercised. [Original canary and cleanup records](cloud-3bcb0640-diagnostics/README.md) |
| `1d7402d4`, diagnostics | Launch, foreign/same-app/cross-app and three complete cycles passed; yellow adoption returned MinimizedOrAX; original hidden A1 briefly returned AX CannotComplete | A second release on the same engine restored all three windows and exact original inventory. Cleanup passed; yellow remains FAIL. [Original AX and cleanup evidence](cloud-1d7402d4-diagnostics/README.md) |
| `3bcb0640`, full product | Source and complete candidate/signature passed; real exported R4 AX button pressed once, AXPress=0, followed by R4SwitchReadbackFailed | Actual input is proven; successful product scheduling is not. No visibility WAL or worker log was created. Cleanup passed. [Original product, input and screenshots](cloud-3bcb0640-full/README.md) |
| `32f22cd4`, diagnostics | Launch and three group cycles passed; an actually inconsistent CG visibility pair was re-read successfully; hidden A1's original AX object then returned CannotComplete during yellow minimization | Earliest health latch is now directly identified. Same-engine retry restored all windows and inventory; original yellow FAIL remains. [Original earliest-fault trace](cloud-32f22cd4-diagnostics/README.md) |
| `33d65484`, diagnostics | The specific AX CannotComplete recovered with two complete health observations; launch and three cycles passed; yellow reached binding and failed on a nonstandard subrole | Observation retry is physically confirmed. Yellow remains FAIL and same-engine cleanup passed. [Original trace](cloud-33d65484-diagnostics/README.md) |
| `33d65484`, full candidate | 155 Rust and 162 Swift passed, one explicit skip; complete app and strict signature passed; normal engine cycles passed; yellow failed; actual external R4 reads timed out before input | Zero real button presses, no handler claim, cleanup passed, cold restart NOT_RUN. [Original candidate and AX receipt](cloud-33d65484-full/README.md) |
| `3e197761`, diagnostics | All six initial readbacks passed with zero hidden ownership; the first never-hidden window retained its original AX identity through real minimization and reported AXDialog | Initial registration is physically proven. The earlier AXUnknown-only transition check refused this actual state before any foreign mini move; cleanup passed. The narrow follow-up admits the observed state only on that original registered window. [Original receipts](cloud-3e197761-diagnostics/README.md) |
| `44bc3759`, diagnostics | Original minimized AXDialog accepted; engine reached hidden Space 15 membership, then the single AX demini request did not finish within the old Space deadline | Initial yellow remains FAIL; cleanup passed. The next source change separately bounds completion observations and rejects any observed escape. [Original boundary](cloud-44bc3759-diagnostics/README.md) |
| `44bc3759`, full R4 | Actual AXPress reached current-card handling, fresh complete/bound groups and a real configured worker; all three window previews rendered; activation rejected before NP_LAUNCH | Product switch FAIL with cleanup PASS. New read-only phases distinguish the initial witness and coordinator guards. Its source fixture had two failed cases, so this binary is not promoted. [Original product trace and image](cloud-44bc3759-full/README.md) |
| `a60c0a3b`, full | 157 Rust and 166 Swift passed, one explicit skip; complete app and strict signature passed; real R4 press reached the worker but activation remained incomplete | Source fixture correction verified; R4 FAIL and cleanup PASS. [Original candidate and product receipt](cloud-a60c0a3b-full/README.md) |
| `48c2ab44`, diagnostics | Initial visible registrations passed; original minimized window reached hidden 15, then forward membership became `[15,16]` with original home 12 empty | Initial yellow FAIL, cleanup PASS. The original rule stopped before proving extra Space type or later completion. [Original observation and bounded correction](cloud-48c2ab44-diagnostics/README.md) |
| `48c2ab44`, full | 159 Rust and 166 Swift passed, one explicit skip; complete app/signature passed; actual R4 input reached configuration but initial physical read rejected Finder's AXScrollArea with no ordinary window number | R4 FAIL before NP_LAUNCH, cleanup PASS. Positive desktop structure must be established by the next run; a zero number alone grants no authority. [Original phase and candidate](cloud-48c2ab44-full/README.md) |
| `b309067f`, compile | Two installed-fixture callers omitted the new internal readFocus argument; worker/archive build stopped before Swift language compilation or GUI work | Compile failure corrected in b43d; no native conclusion. [Original source receipt](cloud-b309067f-build/README.md) |
| `b43d5a93`, diagnostics | Extra Space 16 is excluded from complete managed roster; actual animation is temporarily onscreen. Fields settle by 621 ms and repeat at 653 ms | Initial yellow FAIL at old 650 ms boundary, cleanup PASS. Dedicated 1000 ms active-completion source follows with final checks unchanged. [Original actual timings](cloud-b43d5a93-diagnostics/README.md) |
| `b43d5a93`, source and R4-fast | 160 Rust and 169 Swift passed, one explicit skip; actual debug Host built and actual card press entered the queue, then dispatch/epoch were withdrawn during system confirmation | Product FAIL, cleanup PASS, no worker or new Finder structure sample. Fast debug is separate from full workspace release. [Original source and product receipts](cloud-b43d5a93-r4-fast/README.md) |
| `b43d5a93`, full release | Complete workspace build and strict signature passed; real input independently lost dispatch during a 1.400-second system confirmation, before the group-choice Host or worker | Product FAIL, cleanup PASS. Three real previews appeared later; their rendering does not prove dispatch or recover the rejected click. [Complete candidate and original release phases](cloud-b43d5a93-full/README.md) |
| `9cec081f`, diagnostics | Same VM actually passes initial registration, first yellow, foreign round trip, same-app separation, cross-app combination, all three cycles, later yellow and focus; 34 verified receipts include 26 hide/restore requests | FOREIGN_ENGINE_PASS and first-release cleanup PASS; full original inventory restored twice. Product R4 NOT_RUN and target-SIP-enabled qualification remain separate. [Original complete engine evidence](cloud-9cec081f-diagnostics/README.md) |
| `9cec081f`, R4-fast | This VM also passes the normal engine; final button role/identifier return AXCannotComplete (-25204), before any action is issued | R4 BLOCKED, input zero, cleanup PASS. The original green job is not a product result; product-supplied lanes now require a real R4 PASS to exit zero. [Original no-input receipt](cloud-9cec081f-r4-fast/README.md) |
| `9cec081f`, full release | 161 Rust and 169 Swift passed, one explicit skip; complete app/signature and this VM's normal engine passed; real R4 input passes native confirmation and reaches worker | Initial Swift witness rejects Finder's listed desktop AXScrollArea form; no NP_LAUNCH, product FAIL, cleanup PASS. Self equality/exact list count are required by the next candidate, not assumed proved. [Original structure and complete candidate](cloud-9cec081f-full/README.md) |
| `3d79921c`, diagnostics | Initial and later yellow, foreign round trip, same-app independence, cross-app combination, all three cycles and focus pass with 34 verified receipts; complete original inventory restored twice | Independent FOREIGN_ENGINE_PASS and first-release cleanup PASS; no R4/target qualification. [Original complete engine receipts](cloud-3d79921c-diagnostics/README.md) |
| `3d79921c`, R4-fast | Initial yellow and group cycles pass; passive health exhausts its 650 ms budget after original hidden sibling AXCannotComplete, before later yellow starts. Product button's six attributes and panel checks succeed, repeated action-name query times out | Engine later-yellow FAIL, product BLOCKED/input zero, cleanup PASS. Neither another VM's engine PASS nor this button discovery changes those results. [Original earliest fault and no-input receipts](cloud-3d79921c-r4-fast/README.md) |
| `3d79921c`, full release | 161 Rust and 170 Swift pass, one explicit skip; full app/signature and this VM's whole engine sequence pass. Actual button discovery confirms AXPress, but its redundant final action-name query returns AXCannotComplete | Source-checked complete candidate; R4 BLOCKED/input zero, cleanup PASS. The new Finder predicate and worker activation are not reached. [Original source, candidate and runtime evidence](cloud-3d79921c-full/README.md) |

| `2f3eddda`, diagnostics | All engine checks and first-release cleanup pass again; original hidden sibling has AXCannotComplete at 167/482 ms, then two complete reads by 645 ms | FOREIGN_ENGINE_PASS; this VM does not consume the new extra health interval. First active demini completion needs 874 ms. [Original timed result](cloud-2f3eddda-diagnostics/README.md) |
| `2f3eddda`, R4-fast | Real AXPress input1 reaches group job; actual ordinary Dock read is 1.27 ms, delivery age 483.7 ms, but pre-request clock causes sampleExpired and epoch withdrawal. Three real images render; all windows remain at home | Product FAIL, cleanup PASS; current previews are not held-window proof. This VM's entire normal engine passes independently. [Actual input, read interval and screenshot](cloud-2f3eddda-r4-fast/README.md) |
| `2f3eddda`, full release | 162 Rust / 170 Swift pass, one skip; complete workspace/signature and this VM's normal engine pass. Product compound pre-press context check declines before input | Latest source-checked complete candidate; product BLOCKED/input0, cleanup PASS. Exact failed context field is unobserved, not assigned the fast VM's cause. [Original candidate and product receipt](cloud-2f3eddda-full/README.md) |

| `dd665ed2`, diagnostics | Own-panel hidden and return pass, then first close-time CG description/on-screen disagreement returns Readback217; existing observation loop exits early | BLOCKED, zero foreign actions, first-release and double physical cleanup PASS. Follow-up keeps unknown reads inside the original120ms loop. [Exact canary fault](cloud-dd665ed2-diagnostics/README.md) |
| `dd665ed2`, R4-fast | 162 Rust /172 Swift pass, one skip; both new freshness regressions execute. Actual Dock delivery age1009.32ms after11.14ms read genuinely expires; helper AX tree remains incomplete before input | Normal engine passes independently, product BLOCKED/input0, cleanup PASS. Main-thread cause requires the newly added external sample. [Original actual timings](cloud-dd665ed2-r4-fast/README.md) |
| `dd665ed2`, full release | Complete app/signature and this VM's engine pass; real R4 input1, all four pre-press context fields true, no panel movement. Actual Dock read+delivery773.334ms correctly exceeds750ms before group job | Latest source-checked complete candidate; product FAIL/cleanup PASS, no Finder/worker-launch result. [Original full candidate and trace](cloud-dd665ed2-full/README.md) |

| `3437abd5`, normal engines | Diagnostics, fast and full each independently pass the complete foreign engine sequence and cleanup; diagnostics own-close succeeds without the new retry branch firing | FOREIGN_ENGINE_PASS on hosted26A434/SIPoff; no inferred target/R4 qualification. Diagnostics [artifact15080511104](https://github.com/haohongfei2001-png/nearpane/actions/runs/45738564830/artifacts/15080511104), SHA256 `a5cc39da39c8a1112b6eda4ae689c912e47dd3aa7a81b2a3ac216547738a9446`; full/fast originals below |
| `3437abd5`, R4-fast and profile | Source164 Rust/174 Swift pass, one skip. First-frame AX history creation occupies14/83 main-thread leaf samples; button's final canonical mapping is unconfirmed before input | Product BLOCKED/input0, cleanup PASS. The entire sample is retained, not only chosen stacks. [Actual original sample and receipts](cloud-3437abd5-r4-fast/README.md) |
| `3437abd5`, full release and profile | Full package/signature pass; actual input1, exact Finder self/listed-once structure, fresh3-window bindings and ready worker. Two synchronous physical rebinding passes occupy104/114 sampled main-thread paths; opening-roster then rejects stale system ownership | Product FAIL before NP_LAUNCH, cleanup PASS, worker owns zero. C Finder predicate remains unexecuted. [Complete candidate, entire sample, Finder/worker and physical receipts](cloud-3437abd5-full/README.md) |

| `8805a3db`, source/full package and normal engines |164 Rust/174 Swift pass, one skip; complete workspace/signatures pass. All three VMs independently pass the complete normal foreign engine and cleanup | Earlier source-checked full candidate; diagnostics34/34 receipts,10checks, first/later yellow595/613ms, firstrelease74.134ms/owned0. [Full original](cloud-8805-full/README.md); diagnostics [artifact15081238976](https://github.com/haohongfei2001-png/nearpane/actions/runs/45742189742/artifacts/15081238976), SHA256 `e9796baf049b34205d52089dcf0d572cf3d3f44a4359721469cba74280986664` |
| `8805a3db`, fast actual R4 | Same retained panel confirmed, input1/AXPress0, first witness completes3 windows/3 managed. Actual Dock sample age1133.81ms revokes ownership before NP_LAUNCH;10/86 sampled main-thread paths identify witness reads | Product FAIL/cleanup PASS. Initial binding existed; this run does not physically cover cold rebinding. [Full sample and receipts](cloud-8805-r4-fast/README.md) |
| `8805a3db`, full actual R4 | Discovery same-panel succeeds, final retainedAXPanelIdentity unconfirmed before button validation/input; its inner call's specific error was not recorded | BLOCKED/input0/cleanup PASS; neither wrong-window nor timeout inferred. [Full original](cloud-8805-full/README.md) |
| `8805a3db`, target26A428/SIPon | Own panel obtains matching complete home4 at3/208ms; second exceeds120ms discovery budget. No hidden Space created, foreign requests0; original inventory/windows and both fixture exits confirmed | Executed engineering blocker, not bridge failure. [Original target trace and hashes](target-8805-panel-home/README.md) |

| **350e848c, actual target26A428/SIP enabled** | **34/34 engine receipts,10/10 checks,26 hide/restore requests,68 two-observation foreign readbacks PASS**; same-app/cross-app/three cycles/first and later yellow/focus. Firstrelease537.5ms/owned0; original3 windows and16-entry inventory restored twice | **Target foreign engine established**, cleanupPASS, both fixture exits0. Actual own-close217 recovery exercised. R4NOT_RUN/overallINCOMPLETE remains explicit. [Raw target evidence and166 Rust PASS](target-350e-engine/README.md) |
|350e848c, separate hosted diagnostics/source |166 Rust/174 Swift pass, one skip. Diagnostics34/34receipts and10checks PASS, first/later yellow759/670ms, firstrelease151.5ms/owned0, fullcleanupPASS; own-close217 retry actually executes | Independent hosted result, not merged with target/product evidence. [artifact15148512070](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306/artifacts/15148512070), SHA256 `0700985ae5399aeecccd19205fa6ba022ecf50b5c2bfed99a630ff10fe710cd0` |
|350e848c, full workspace and R4 |Complete candidate/resources/strict-deep signature PASS. Normal engine independently passes. Product AX discovery ends at windowListRead=-25204 before input or witness | Product BLOCKED/input0, cleanup PASS. Full main-thread sample retained. [Original and candidate metadata](cloud-350e-full/README.md) |
|350e848c, fast R4 |One actual AXPress/error0/same retained panel; real context total age901.886ms withdraws dispatch before group job/witness | Product FAIL, cleanup PASS, cold/lifecycle/crash NOT_RUN. Presentation-state reads identified in complete sample. [Original](cloud-350e-r4-fast/README.md) |

The specific AXCannotComplete health correction has now executed successfully, inside its original
650 ms budget and on the same retained witness. The next yellow correction registers every initially
visible standard AX window through the existing readback operation, retains that exact identity across
return, and requires it when adopting a later real minimization. Tests separately exercise the first
active window's yellow button before any previous hide/show and the later repeated-switch case.
Worker-to-owner correlation and read-only cold-start reconciliation passed source tests; the same-profile
restart scenario still needs to prove actual worker return, old-ledger retirement and resumed R4 operation.
The normal card path also now refreshes and atomically rebinds a complete live scope when an explicit
current click encounters new session lifetimes, without requiring an extra menu action or silently
substituting ordinary focus. These later source changes are not yet a product acceptance result.
The latest completed `350e848c` source run passed **166 Rust and174 Swift cases, with one explicit skip**;
the new binding, desktop-focus and original minimized-window tests actually executed. The latest
completed full candidate is separately recorded below. Source changes also retain the new-window resume intent after recording the new
singleton clears the old active marker, and add real creation/closure/application-exit acceptance.
Those lifecycle cases run only after the main R4 and same-profile crash/restart cleanup pass; missing
prerequisites remain NOT_RUN. A later card success cannot erase a failed automatic arrival.
The existing closed-window proof/return/retirement path now also handles a closure discovered by
health before the regular snapshot read. This reuses the same original-worker release and independent
AX/CG closure confirmation; it does not invent a replacement-window writer.
System-interaction receipts now preserve their already sampled entry states. The generic signed-Dock
overview alone cannot qualify App Exposé; that subtype stays UNKNOWN until the bounded raw Dock
metadata proves a distinction. Its controlled comparison continues in cloud. Split View receipts
separately name the fixture owner's explicit focus command and do not infer native automatic focus.
The existing foundation/debug configuration now supplies an earlier native R4 feedback lane with
the same Host, engine and sealed acceptance packaging. Its result is separate from the complete
workspace/release lane and never replaces that build or its native acceptance.
Repeated native AutoHide/zero-row controls are now an explicit
workflow input: their already committed negative renderer evidence is not rerun on every unrelated
engine fix, and the diagnostic tools and full cleanup conditions remain available.

Full original source receipts: [cloud-2a0cfbe9](cloud-2a0cfbe9/README.md): 147 Rust, 136 Swift and 8 Python cases passed; one signed live-fixture Swift case was explicitly skipped.

Source CI: [run 45675486685](https://github.com/haohongfei2001-png/nearpane/actions/runs/45675486685).
Subsequent committed corrections and final candidate receipts are added below after execution; a running
or failed build is never advertised as a complete candidate.

Original target receipts:

- [Initial candidate run and cleanup](target-da51f75/README.md)
- [Main-queue timeout and cleanup](target-9c1be70-mainqueue/README.md)
- [Run-loop A/B receipt](target-own-panel-runloop-20261126.json)
- [Direct-focus own-panel diagnostic](target-direct-focus-20261126.json)
- [Read-only native-engine/strip inventory](../../../tools/native-stage-decoupling/evidence/macos-27.0-26A428-inventory.json)
- [Read-only front-focus contrast](../../../tools/native-stage-decoupling/evidence/macos-27.0-26A428-focus-readback.json)

The target connector previously stopped responding; those unstarted calls have no WindowServer result.
It returned online on2026-11-26 at19:13UTC. The clean isolated clone was fast-forwarded to8805 and
the blocked8805 trial and complete successful350e foreign-engine trial above executed. The daily application and its checkout were not replaced.
The initial missing-Cargo PATH attempt stopped before creating any fixture; the recorded trial reused
the existing portable compiler. Target cleanup is preserved separately from hosted results.

## Complete candidate checkpoints

[350e848c full receipts](cloud-350e-full/README.md) identify the latest source-checked complete
candidate in [artifact15148989122](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306/artifacts/15148989122).
The independently rehashed inner ZIP is25,361,971 bytes, SHA256
`ef3ea48565d3ce551e1cb64432b00e83af9cd147e67808e3f13fcb57e58ea513`.
166 Rust/174 Swift pass, one skip; complete workspace/resources/strict-deep signature pass.
The VM's normal foreign engine and cleanup pass, while formal R4 discovery is incomplete
before input. This source separately passed the actual target-SIP foreign engine above;
neither result grants formal R4 product or Developer ID notarization qualification.

[8805a3db full receipts](cloud-8805-full/README.md) identify an earlier source-checked complete
candidate in [artifact15081848172](https://github.com/haohongfei2001-png/nearpane/actions/runs/45742189742/artifacts/15081848172).
The independently rehashed inner ZIP is25,366,035 bytes, SHA256
`9c5c7619b97917a30b6a4a0de846c3bd0890c6b2178e60e1c65a7fe0359ee1f5`.
164 Rust/174 Swift pass, one skip; full workspace/resources/strict deep signature pass.
This VM's ordinary foreign engine passes, but its formal R4 helper stops before input on an
unconfirmed retained-panel identity. Product cleanup passes. This is a development candidate,
not a completed R4 product, Developer ID notarization or target-SIP qualification.

[3437abd5 full receipts](cloud-3437abd5-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15080378771](https://github.com/haohongfei2001-png/nearpane/actions/runs/45738564830/artifacts/15080378771).
Its independently rehashed ZIP is 25,337,823 bytes, SHA-256
`dfedb4a4377fa250bca3a46358b4e763625878602947fcf7e628066b24f49d0c`.
164 Rust and 174 Swift cases passed, one skip; complete workspace and strict/deep signature passed.
The normal engine passes. Real R4 input reaches Finder confirmation, fresh bindings and ready worker,
but initial physical witness rejects stale system ownership before NP_LAUNCH. Cleanup passes with
zero worker ownership. This is a development candidate, not a product or target qualification.

[dd665ed2 full receipts](cloud-dd665ed2-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15079243584](https://github.com/haohongfei2001-png/nearpane/actions/runs/45736296714/artifacts/15079243584).
Its independently rehashed ZIP is 25,324,809 bytes, SHA-256
`2a492dd74ef3149aea970ba628c454b24980036b4788ea7bc44be7297955038f`.
162 Rust and 172 Swift cases passed, with one explicit skip; both freshness regressions actually ran.
Complete workspace and strict/deep bundle verification passed. This VM's entire engine sequence
passed, but real R4 input failed admission on a genuinely old Dock observation. Cleanup passed;
this remains a development candidate without product qualification.

[2f3eddda full receipts](cloud-2f3eddda-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15077963583](https://github.com/haohongfei2001-png/nearpane/actions/runs/45734124458/artifacts/15077963583).
Its independently rehashed ZIP is 25,323,844 bytes, SHA-256
`d0c00ccb9da79502c0c44e0037a969bd6b094e8886228b6d612a920cd838af9c`.
162 Rust and 170 Swift cases passed, with one explicit skip. Complete workspace and strict/deep
bundle verification passed. The full VM's entire engine sequence passed, but its R4 path stopped
before input at a compound context check. Cleanup passed; product qualification remains false.

[3d79921c full receipts](cloud-3d79921c-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15077029046](https://github.com/haohongfei2001-png/nearpane/actions/runs/45731326197/artifacts/15077029046).
Its independently rehashed ZIP is 25,321,984 bytes, SHA-256
`a9c668757b9f3be3c23763bea03893c4ae072778f62ee8cf135f39c1009af239`.
161 Rust and 170 Swift cases passed, with one explicit skip. Complete workspace and strict/deep
bundle verification passed. This VM's entire engine sequence also passed; its R4 path stopped
before input at the repeated AX action-name query. Cleanup passed; product qualification remains false.

[9cec081f full receipts](cloud-9cec081f-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15076681435](https://github.com/haohongfei2001-png/nearpane/actions/runs/45728613871/artifacts/15076681435).
Its independently rehashed ZIP is 25,317,102 bytes, SHA-256
`cf2f87d7c5bb112947917dedf00ee96098ad965e254720b4cc4679b30752fec8`.
161 Rust and 169 Swift cases passed, with one explicit skip. Complete workspace and strict/deep
bundle verification passed. This VM's normal engine also passed all checks; its real R4 input still
failed at the first Finder desktop witness, with confirmed cleanup. It is not product qualification.

[b43d5a93 full receipts](cloud-b43d5a93-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15075900553](https://github.com/haohongfei2001-png/nearpane/actions/runs/45726209534/artifacts/15075900553).
Its independently rehashed ZIP is 25,296,704 bytes, SHA-256
`0b2736ed4b8f6164a4b606025314cd6bb531d0127c7ac38ea8fd17bca17a388d`.
160 Rust and 169 Swift cases passed, with one explicit skip; complete workspace build and strict/deep
bundle verification passed. Yellow and real R4 both remain failed with confirmed cleanup. Its full
release and faster foundation/debug runs are separate observations, not combined qualification.

[48c2ab44 full receipts](cloud-48c2ab44-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15074000114](https://github.com/haohongfei2001-png/nearpane/actions/runs/45722428165/artifacts/15074000114).
Its independently rehashed ZIP is 25,205,980 bytes, SHA-256
`25f8f2fa06e2ecb3134a4518db93a5a1e2d391897c617a493b2bd7a117c03947`.
159 Rust and 166 Swift cases passed, with one explicit skip; complete build and strict/deep bundle
verification passed. Yellow and R4 both remain failed with confirmed cleanup. This is a development
candidate, not a target qualification or a complete product acceptance.

[33d65484 full receipts](cloud-33d65484-full/README.md) identify an earlier source-checked complete
candidate in [artifact 15070133110](https://github.com/haohongfei2001-png/nearpane/actions/runs/45715629275/artifacts/15070133110).
Its independently rehashed ZIP is 25,105,091 bytes, SHA-256
`5a5fbeda6d9356c12486987a72a0031d5946c342f2c5a0b9e10774d3f83dd64f`.
155 Rust and 162 Swift cases passed, with one explicit skip, and strict bundle verification passed.
Runtime is separately incomplete: yellow failed, and R4 discovery stopped before any input.
Both reported cleanup results passed. This is a development candidate, not a target qualification.

[3bcb0640 full receipts](cloud-3bcb0640-full/README.md) identify the source-checked complete candidate in
[artifact 15069160488](https://github.com/haohongfei2001-png/nearpane/actions/runs/45710634990/artifacts/15069160488).
Its independently recorded ZIP SHA-256 is
`413b25f592c1d7c3840fedc1a119e5c95a9c796670d66f5e379accd6f28b6140`.
151 Rust and 156 Swift checks passed, with one explicit skip. The real R4 button received one AXPress;
subsequent physical state did not confirm a group switch. That is a failed product operation, not a
successful integration inferred from the input's zero error code.

[bbc08a09 full receipts](cloud-bbc08a09-full/README.md) identify the source-checked complete candidate in
[artifact 15066931486](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/artifacts/15066931486).
Its independently checked ZIP SHA-256 is
`6998bfeeb7a702c3aa5cd3b9d5eca80457aed4f2245bc9bc08dcc703316eb091`.
151 Rust and 156 Swift checks passed, with one explicit live-fixture skip. The complete app passed
strict bundle verification. This full VM's canary cleanup remained unconfirmed, so its R4 path was
not run; the successful three-cycle diagnostic is a separate VM and a separate behavioral result.

[5607d3b3 full receipts](cloud-5607d3b3-full/README.md) identify the source-checked complete candidate in
[artifact 15063654234](https://github.com/haohongfei2001-png/nearpane/actions/runs/45702787052/artifacts/15063654234).
Its independently checked ZIP SHA-256 is
`55bee0acc03160712f7f1035d21a16f794891282a151f006f13b289de7ad9949`.
The normal-engine result is an actual partial behavioral success followed by a failed repeated switch,
not an overall product pass. The runtime receipt preserves the cleanup classification failure and
the independently observed final home/geometry of all three windows; later source fixes do not
rewrite that historical result.

[5e458d1d full receipts](cloud-5e458d1d-full/README.md) identify the source-checked candidate in
[artifact 15062876476](https://github.com/haohongfei2001-png/nearpane/actions/runs/45697978438/artifacts/15062876476),
with independently checked ZIP SHA-256
`0fabd6c1ede4640e3fbc59edf61fa23c07b4029008884cd094a61fb86f483fa2`.
Its runtime blockers are retained in the same evidence folder; a later implementation fix does not
change the status of this recorded run.

[6558c2d5 complete receipts](cloud-6558c2d5-full/README.md) identify the later source-checked full
workspace candidate in [artifact 15061066778](https://github.com/haohongfei2001-png/nearpane/actions/runs/45693715803/artifacts/15061066778).
The independently checked ZIP SHA-256 is
`96d4d3a71a662b629a4080f5835abc360404cc4d3ad59d94e87fb8d256d44856`.
Its whole runtime remains incomplete: R4 directory readiness blocked before a card press, and the
older CI-only ordinary-desktop cleanup did not confirm deletion. Neither changes the verified build.

[3493f968 complete receipts](cloud-3493f968/README.md) identify the source-checked full workspace
candidate in [artifact 15057695932](https://github.com/haohongfei2001-png/nearpane/actions/runs/45686497133/artifacts/15057695932).
Its downloaded ZIP was independently hashed and matches
`3fb1bd799ba2928c061c756b73238dbfce0dfd07b137d1d8d39490a1fdf33d9f`.
The later `a73454a1` complete package built and passed its signature, but three expectations in two
new parent-path tests failed. That package is not promoted to a passing source checkpoint. Canonical
path comparisons corrected the directory URL representation error in subsequent source.

[Full receipts for 283831ef](cloud-283831ef/README.md) include the original candidate/source/engine/product
JSON and the archive checksum. [Actions artifact 15053163726](https://github.com/haohongfei2001-png/nearpane/actions/runs/45678251498/artifacts/15053163726)
contains the complete workspace application, not just a diagnostic program. Inner candidate ZIP SHA-256:
`c0c60dbb014b0d0b135f52605c2bb694ec3d60b0b8a1996876c8224b7d234e5f`.
It is a development signature, not a notarization receipt. Later source fixes supersede this checkpoint;
the final PR records the final fixed source and matching artifact separately.

The runtime investigation found two concrete integration errors. The read-only C shim's exact
`26A428` gate withheld AX IDs/bounds/reverse membership on `26A434`; positive read-only symbol and
shape checks now cover the current arm64 Darwin 26 ABI family without granting write qualification.
The physical witness also used managed-only membership mask 7, which can omit a classic hidden Space.
It now uses `NPReadWindowSpacesIncludingHidden` (mask 15) for both hidden and returned-home proofs;
the ordinary display catalogue retains managed-desktop semantics and separately excludes only twice
confirmed, offscreen non-managed members. The Rust backend already used mask 15. These fixes do not
convert earlier zero-write runs into success. Raw topology/console diagnostics upload before the full
build completes. A separate hosted diagnostic lane reuses the production platform atoms on fresh
foreign fixtures without inventing a persistent ordinary UUID; its result cannot qualify the engine
state machine or the R4 product. The full product lane retains the genuine native desktop identity.

## Unified execution

```sh
python3 -B scripts/acceptance/independent-stage/run.py /private/tmp/nearpane-independent-01 --scope all --iterations 3
```

The output path must be new. This builds source and the complete application, packages the independent
workspace, creates controlled fixture apps, exercises the isolated product copy, retains raw evidence and
cleans up its own children. [Entry and interpretation](../../../scripts/acceptance/independent-stage/README.md).
A failed source or packaging phase keeps its failure even when independent later diagnostics can run.

Actual third-party migration, full R4 operation, yellow minimize, native handback/resume, desktop reveal,
Host-crash cleanup, full-screen/Split View and physical desktop gestures require their own completed
receipts. `NOT_RUN`, unavailable permissions and a different macOS/SIP environment cannot qualify the target.
