# Nearpane current implementation — 2026-11-27

Authority: [Independent Stage Manager replacement decision](../research/NEARPANE-INDEPENDENT-STAGE-DECISION.md).

- Working branch: `pro/independent-stage-engine-20261126`, forked from PR #15 at `6ac5eb63c97b7597e662770bac485be61f571bb8`.
- Product route: independent hidden Spaces, Apple Stage Manager disabled, Nearpane R4 is the sole stage thumbnail interface.
- Native-strip following and Corner are removed from product selection. Historical code/receipts remain for evidence and recovery, never as automatic fallbacks.
- Source integration: Swift Host / existing R4 and StageGroup coordinator / Rust static library / C ABI, with a separately identified candidate app for decisive experiments.
- Runtime qualification: candidate only. A successful own-window canary is NOT a third-party-window qualification. The unified third-party experiment and R4 product acceptance produce separate results.
- Confirmed target foreign engine: **350e848c on macOS27.0/26A428/arm64/SIP enabled** passes34/34 receipts,10checks,26 hidden/restore requests, same-app independence, cross-app combinations, three cycles, two real yellow actions and focus. Two final reads restore the original3 windows/layouts and16-entry Space inventory; both fixtures exit0. Actual close217 recovery also executes. [Original target evidence](../verification/independent-stage/target-350e-engine/README.md).
- Source verification:350e passes166 Rust/174 Swift with one explicit skip in cloud, and166 Rust on target. The latest completed full workspace/signature candidate is8805; the later full build is recorded only after completion. [Current candidate/evidence index](../verification/independent-stage/README.md).
- Product boundary:8805 fast actually presses R4 and completes its first three-window witness, then stale native-context delivery revokes dispatch before NP_LAUNCH; full stops before input on an unconfirmed retained-panel identity. Both clean up. The next source revision moves initial/retained physical witness reads off MainActor while preserving original AX identity and all post-await checks. Source inspection is not a product PASS.
- Target product preflight:the second350e invocation finds the console locked and performs zero foreign moves. It also exposes an actual/private/tmp alias mismatch for an absent profile; the next source revision resolves both real parents, retaining PID/scope constraints. Its blocked receipt is not overwritten by the earlier engine PASS.
- Cold-hidden first-frame, merge/split, lifecycle, system handback and crash/restart are implemented in the common entry and still require their actual formal R4 prerequisite/results.
- Upstream latest v1.10.0/204d8de1 is incrementally audited. The hidden bridge semantics and own-window-only probe are unchanged; Corner cover optimizations are excluded. [Fixed audit](../research/INDEPENDENT-SPACES-SOURCE-AUDIT.md).
- A-route evidence: the actual 26A428/SIP-enabled runtime inventory did not establish a callable renderer/engine separation. Hosted 26A434/SIP-disabled edge sweeps rejected the two tested settings (`AutoHide=true` and `LeftStripMaximumRowCount=0`) with corroborated native thumbnails and complete restoration. [Original renderer evidence](../verification/independent-stage/cloud-a73454a1/README.md). These results do not prove that every unknown private separation mechanism is impossible. Further diagnostics remain isolated under `tools/native-stage-decoupling/`; A is not a product dependency.
- Remote build and physical results are recorded in the decision's verification section and `engineering/verification/independent-stage/` as they complete.

## Historical records

[All prior experiment and release records](archive/STATUS-pre-independent-20261126.md) are preserved verbatim. They do not define the current product route.
