# Nearpane current implementation — 2026-11-26

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed foreign mechanism: `bdedf131` moved two real external-process windows into hidden Space 13 and back, with independent physical readback and complete hidden-Space cleanup. This was 26A434/SIP disabled; the target 26A428/SIP-enabled engine and R4 remain unqualified. [Exact scope and original evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
- Latest normal-engine evidence: `dd665ed2` fast and full VMs each independently pass the whole foreign engine sequence and cleanup. Its separate diagnostic stops on an unsettled own-panel close read before any foreign action; first-release cleanup passes. The old immediate Readback217 return is corrected inside the original120ms loop, without new close/move writes. Earlier `2f3eddda` fast records actual735ms recovery after AXCannotComplete, proving use of the bounded extra interval. These VM verdicts remain distinct. [Original evidence](../verification/independent-stage/README.md).
- Product boundary: latest complete `dd665ed2` source/workspace/strict signature pass (162 Rust /172 Swift, one skip). Two actual freshness regressions pass, but native product reads now genuinely arrive after750ms. Fast sends no input; full sends one action but stops before the group job. External read-only Host sampling is added to locate the real main-thread delay. The separate first-departure image gap is fixed in the existing gallery with original identity, one bounded capture attempt and cancellation checks; native held-first-frame proof is pending. [Current product observations and complete candidate](../verification/independent-stage/README.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
