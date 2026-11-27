# 3d2c6c81: R4 latency baseline after rendering-query optimization

This folder records the **already completed** cloud run for exact commit
`3d2c6c81a81c2e0ccf2be114a6bc07ac4321e8df`. These original receipts were downloaded
and independently hashed on 2026-11-27. They are a baseline for the next latency
fix, **not evidence that a later fix has passed**.

## Result and remaining blocker

Both the full release and foundation/debug lanes pass the foreign-window engine,
but **fail the formal production R4 path** after one real external accessibility
press (`AXPress` error 0). Physical window hide/restore/focus does not complete.
Product, fixture and CI-owned desktop cleanup are confirmed. The overall result
remains `INCOMPLETE`; no release qualification is granted.

The actual Dock read is quick, but its delivery back to the Host is delayed.
The fast lane records a 2.274 ms physical read whose result is 1,384.763 ms old
when processed; the full request takes 1,555.700 ms. The unchanged 750 ms freshness
check correctly rejects it. In the full lane, the group job begins at uptime
1109.997918708 and new bindings arrive at 1116.316426208 (about 6.32 seconds later).
The opening-roster witness subsequently rejects expired system ownership.

The original main-thread samples identify remaining synchronous work in
`DesktopWindowGallery.consume` / `awaitFrameAdmission` / `admissionReason`,
including session, TCC, application-owner, WindowServer window-list and surface
queries. That stack accounts for 15 of 53 fast-lane main-thread samples and 26
of 79 full-lane samples. `CurrentDesktopWindows.updateObservation` also samples
in its `windowNumbersFingerprint` query (6 of 53 fast-lane samples). These counts
are sampled call-stack observations, not precise wall-clock attribution.
The previous rendering-query optimization did not remove these per-frame
admission and periodic inventory queries.

## Exact provenance

- [Workflow run 45886758872](https://github.com/haohongfei2001-png/nearpane/actions/runs/45886758872), event `push`.
- Branch: `pro/independent-stage-engine-20261126`; PR #16.
- Cloud OS: macOS 27.0.1 / build 26A434 / Apple Silicon / SIP disabled.
- This is separate from the earlier macOS 27.0 / 26A428 / SIP-enabled target-Mac engine evidence.
- `full` job: 140139258198; `r4-fast` job: 140139258606; `diagnostics` job: 140139258594.
- Files in this folder are byte-for-byte original artifact entries, with the entry-to-file mapping and per-file hashes in [provenance.json](provenance.json).

| Artifact | Bytes | Independently checked SHA-256 |
| --- | ---: | --- |
| [Full 15150880864](https://github.com/haohongfei2001-png/nearpane/actions/runs/45886758872/artifacts/15150880864) | 52,676,209 | `c53896f9ce5744a2d83cb8c7207d4fb36d3a1746a1a752825a7b233308dd5c0c` |
| [Fast 15150581438](https://github.com/haohongfei2001-png/nearpane/actions/runs/45886758872/artifacts/15150581438) | 24,406,335 | `1f73a58508ad97ee3dec51b7450234dda376d3f4852d81d8311eedf377a14888` |
| Inner full `Nearpane-independent-candidate.zip` | 25,405,575 | `04c9525d9852d3bc6ef2504235e92ef5a556c2ff34d60fbb7f3d4162dd720070` |

Archives and application binaries are not duplicated in this evidence folder.

## Source, build and runtime are distinct

| Check | Full lane | Fast lane |
| --- | --- | --- |
| Rust tests | 166 PASS | Not run in this lane |
| Swift tests | 176 PASS, 1 skip | Not run in this lane |
| Worker build/protocol, evidence classifiers, read-only context | PASS | Not a separate source-test lane |
| Complete companion-workspace release build and strict/deep signature | PASS | Not run; foundation/debug Host built instead |
| Foreign-window engine | PASS, 26 hide/restore request attempts | PASS, 26 hide/restore request attempts |
| Real R4 external input | 1 issued, AX error 0 | 1 issued, AX error 0 |
| Formal R4 physical result | FAIL, `R4SwitchReadbackFailed` | FAIL, `R4SwitchReadbackFailed` |
| Product, fixture and CI-owned workspace cleanup | PASS | PASS |
| Overall product acceptance | INCOMPLETE | INCOMPLETE |

The separate diagnostics job is green; this does not qualify the R4 path.
The complete build remains a development-signature candidate, not a notarized
release or a successful end-to-end product.

## Evidence navigation

- [Full source summary](full/source-summary.json) and [candidate build receipt](full/candidate.json).
- [Full runtime summary](full/runtime-summary.json), [product receipt](full/product-result.json), [R4 press receipt](full/r4-press-result.json), [product phase log](full/product.stderr.log), [original Host sample](full/host-main-thread.sample.txt).
- [Fast runtime summary](fast/runtime-summary.json), [product receipt](fast/product-result.json), [R4 press receipt](fast/r4-press-result.json), [product phase log](fast/product.stderr.log), [original Host sample](fast/host-main-thread.sample.txt).
- Each lane also retains its original engine result, fixture exits and CI-owned workspace cleanup receipt.

## Required continuation

1. Remove the observed main-actor blocking from preview admission and periodic
   catalogue work while preserving fresh identity, ownership and permission checks.
2. Rerun the same production R4 acceptance on the exact changed commit. Inspect
   physical hide/restore/focus receipts and cleanup, not only a successful AXPress,
   source-test count or overall workflow color.
3. After the first R4 chain succeeds, complete the existing merge/split, yellow
   routing, cold hidden preview, system handback/resume, crash/restart and lifecycle
   cases. These remain `NOT_RUN` in this baseline.
4. Retain separate cloud versus target OS/SIP results and complete candidate
   validation before interaction polish and release qualification.

The existing branch push workflow already runs `r4-fast`, `full` and `diagnostics`.
The runtime invocation must supply the matching product bundle:

```sh
python3 -B scripts/acceptance/independent-stage/run.py NEW_OUTPUT \
  --scope runtime --iterations 3 --product-host /exact/matching/Nearpane.app
```

A runtime run without `--product-host` can only establish engine evidence.
