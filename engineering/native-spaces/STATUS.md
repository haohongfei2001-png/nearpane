# Nearpane current implementation — 2026-11-26

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed foreign mechanism: `bdedf131` moved two real external-process windows into hidden Space 13 and back, with independent physical readback and complete hidden-Space cleanup. This was 26A434/SIP disabled; the target 26A428/SIP-enabled engine and R4 remain unqualified. [Exact scope and original evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
- Latest normal-engine evidence: `2f3eddda` diagnostics, fast and full VMs each independently pass initial registration, both yellow-button cases, foreign round trip, same-app separation, cross-app combination, three group cycles, focus and first-release cleanup. The earlier `3d79921c` fast health failure remains separately archived. FOREIGN_ENGINE_PASS is established on 26A434/SIP disabled; R4 and the target SIP-enabled environment remain unqualified. [Current original evidence](../verification/independent-stage/README.md).
- Product boundary: `2f3eddda` source, complete workspace and strict/deep signature pass (162 Rust / 170 Swift, one skip). Fast R4 issues its real action and reaches the group job, then an incorrect pre-reader clock expires an actual fresh Dock observation; its current-window images render but no switch is verified. The separate full VM stops before input at a compound context check whose specific failed field was not logged. The next source corrects actual-observation freshness without relaxing 750 ms and records precise pre-press context. [Current product observations and complete candidate](../verification/independent-stage/README.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
