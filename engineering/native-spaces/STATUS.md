# Nearpane current implementation — 2026-11-26

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed foreign mechanism: `bdedf131` moved two real external-process windows into hidden Space 13 and back, with independent physical readback and complete hidden-Space cleanup. This was 26A434/SIP disabled; the target 26A428/SIP-enabled engine and R4 remain unqualified. [Exact scope and original evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
- Latest normal-engine evidence: `9cec081f` passes all required checks on one hosted VM, including initial registration, first yellow button, foreign round trip, same-app separation, cross-app combination, all three group cycles, later yellow and focus. All 34 engine receipts are verified; 26 hide/restore requests actually executed. The first release restores all windows and the complete original Space inventory in two independent reads. This is FOREIGN_ENGINE_PASS on 26A434/SIP disabled; R4 product scheduling and the target SIP-enabled environment remain separately unqualified. [Original complete engine evidence](../verification/independent-stage/cloud-9cec081f-diagnostics/README.md).
- Product boundary: earlier real R4 input reached the worker but rejected Finder's positively identifiable desktop AX object; the source correction awaits a run reaching that guard. More recent real inputs were revoked during system confirmation, while another fast run declined before input after the final AX attribute read returned CannotComplete. That read error does not prove a replaced object. Precise native ownership and pre-input evidence are collected without promoting input, rendering, or cleanup to product success. [Current product observations and complete candidate](../verification/independent-stage/README.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
