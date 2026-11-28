# Nearpane current implementation — 2026-11-27

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed target foreign engine: **350e848c on macOS27.0/26A428/arm64/SIP enabled** passes34/34 receipts,10checks,26 hidden/restore requests, same-app independence, cross-app combinations, three cycles, two real yellow actions and focus. Two final reads restore the original3 windows/layouts and16-entry Space inventory; both fixtures exit0. Actual close217 recovery also executes. [Original target evidence](../verification/independent-stage/target-350e-engine/README.md).
- Source verification:350e passes166 Rust/174 Swift with one explicit skip in cloud, and166 Rust on target. Its complete workspace/resources/strict-deep signature candidate is now built and independently rehashed. [Current candidate/evidence index](../verification/independent-stage/README.md).
- Product boundary:350e fast actually presses R4, then native-context total age901.886ms revokes dispatch before the group job; full stops before input with an incomplete AX window list. Both clean up. Whole Host samples identify repeated native session reads in presentation. Committed6e5b205d moves initial/retained physical witness reads off MainActor while preserving original AX identity and all post-await checks; the following patch separates observed presentation state from fresh action and pixel checks. Source inspection is not a product PASS.
- Target product preflight:the second350e invocation finds the console locked and performs zero foreign moves. It also exposes an actual/private/tmp alias mismatch for an absent profile;6e5b205d resolves both real parents, retaining PID/scope constraints. Its blocked receipt is not overwritten by the earlier engine PASS. Only source checks run while the target remains locked.
- Cold-hidden first-frame, merge/split, lifecycle, system handback and crash/restart are implemented in the common entry and still require their actual formal R4 prerequisite/results.
- Upstream latest v1.10.0/204d8de1 is incrementally audited. The hidden bridge semantics and own-window-only probe are unchanged; Corner cover optimizations are excluded. [Fixed audit](../research/INDEPENDENT-SPACES-SOURCE-AUDIT.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](https://github.com/haohongfei2001-png/nearpane/blob/ff33373b16abfa98acc3c01844b5ee0e8cfb5a5f/engineering/native-spaces/archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
