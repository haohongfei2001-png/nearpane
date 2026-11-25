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
