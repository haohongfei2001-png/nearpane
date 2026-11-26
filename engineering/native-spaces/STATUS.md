# Nearpane current implementation — 2026-11-26

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed foreign mechanism: `bdedf131` moved two real external-process windows into hidden Space 13 and back, with independent physical readback and complete hidden-Space cleanup. This was 26A434/SIP disabled; the target 26A428/SIP-enabled engine and R4 remain unqualified. [Exact scope and original evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
- Latest normal-engine evidence: `3437abd5` diagnostics, fast and full VMs each independently pass the complete foreign engine sequence and cleanup. Its own-close succeeds without hitting the new Readback retry branch; source regression coverage and direct native branch coverage remain distinct. Earlier VM failures and all target SIP-enabled limits are preserved. [Original evidence](../verification/independent-stage/README.md).
- Product boundary: latest complete `3437abd5` source/workspace/strict signature pass (164 Rust /174 Swift, one skip). Full real R4 input confirms the Finder self/listed-once desktop structure, rebinds all3 windows and starts the worker, but rejects stale system ownership before NP_LAUNCH. Actual full sample identifies two physical rebinding reads on the UI actor; the current source moves only those pure reads to background Sendable observations, retaining post-await authorization and whole-scope atomic rebind. Unused ordinary-image AX history materialization and per-row presentation reads are also reduced. The new cold-hidden-first-image case is implemented in the existing lifecycle run and still awaits real R4 prerequisites. [Current product observations and complete candidate](../verification/independent-stage/README.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
