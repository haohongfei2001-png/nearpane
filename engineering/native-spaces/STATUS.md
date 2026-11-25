# Nearpane current implementation — 2026-11-26

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed foreign mechanism: `bdedf131` moved two real external-process windows into hidden Space 13 and back, with independent physical readback and complete hidden-Space cleanup. This was 26A434/SIP disabled; the target 26A428/SIP-enabled engine and R4 remain unqualified. [Exact scope and original evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
- Later normal-engine evidence: repeated hosted runs through `33d65484` passed the actual Rust canary, foreign round trip, same-app separation, cross-app groups and all three group-switch cycles. The specific transient AX health error now recovers on the original witness. Yellow minimization still failed its original-window binding; cleanup passed in the latest run. R4 received actual presses in earlier runs but did not confirm a switch; the latest run stopped in AX discovery before input. [Current results and complete candidate](../verification/independent-stage/README.md). These are distinct outcomes, not an aggregate product PASS.
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
