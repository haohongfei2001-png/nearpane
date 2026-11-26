# Independent Stage — implementation and evidence

Branch: `pro/independent-stage-engine-20261126` · [Draft PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
Base: PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8` (rechecked; unchanged).
The [single product/technical decision](../../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md) governs this work.

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
The latest completed `9cec081f` source run passed **161 Rust and 169 Swift cases, with one explicit skip**;
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

The target connector subsequently stopped responding. The unstarted calls returned timeouts without a
process ID; they are not additional WindowServer experiments. The daily application and its checkout
were not replaced. All target experiment fixture cleanup that completed is preserved in its receipts.

## Complete candidate checkpoints

[9cec081f full receipts](cloud-9cec081f-full/README.md) identify the latest source-checked complete
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
