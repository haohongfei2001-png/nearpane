# Spaces cloud 10195c7e: Swift compilation blocks formal R4

**This source revision does not compile the Host or Swift test target. Formal product R4 is NOT_RUN.** The subsequent fast-lane runtime executes the independent engine and passes that narrower check; it must not be read as proof that the R4 Host compiled or ran.

Exact head `10195c7e5e50756816ba25cb49202a5cb7f01ef4`, tree `0f0a0fad83f39f7e3ad1fe6d0055303ff82dcdee`, parent `718d9e65b941b66512ec7dd908b83839e5d70bdb`. [Workflow 46052030220, run 61](https://github.com/haohongfei2001-png/nearpane/actions/runs/46052030220) was created at `2026-11-27T18:47:15Z` on the original PR #16 branch. The intervening owner documentation commits are preserved; this archive does not introduce extra runtime acceptance for those documentation-only heads.

## Product scope and current authority

The repository AGENTS and PRODUCT_CONSTITUTION were read before this work. The constitution fetched from main and the local file were byte-identical: **19,332 bytes**, Git blob **`b7b264bd1390f00aacc04a282c253e0db20ca7d4`**, checked at `2026-11-27T18:48:36Z`.

These receipts concern the **Spaces module's existing hidden-Space R4 path**. They do not certify four-edge layout, the complete companion workspace, other modules or Nearpane-wide release readiness. This source failure and pending Spaces qualification do not create a new global release gate for separately mature module combinations. Historical evidence retains its exact-version scope.

## Original source failure

[The source summary](source/summary.json) records **180 Rust tests passed**, but **Swift exit 1 / FAIL**. C file-identity build/test, worker build/protocol and the remaining source checks record PASS. The early context artifact has no original C stdout or Swift XML; no C case count or Swift function/parameter pass count is invented here.

[The complete original Swift stderr](source/swift.stderr.log) records three related Swift 6 diagnostics for the nested `rejected` helper in `StageWindowEngineHost.swift`:

| Source location | Compiler diagnostic |
| --- | --- |
| Line 705, assigning `permittedRejection` | Capture of non-Sendable `[String: Any]?` in an isolated local function |
| Line 700, reading `phase` | Reference to captured variable in concurrently executing code |
| Line 705, mutating `permittedRejection` | Mutation of captured variable in concurrently executing code |

The compiler repeats these diagnostics across compilation units. Repeated log lines are not separate failing tests. [Swift stdout](source/swift.log) is only 44 bytes and contains no executed test suite. Consequently the earlier revision's 228 passing functions, one skipped function and 16 parameter executions do not apply to this revision.

The fast job independently records **failure** for `Build the same R4 Host for earlier native feedback`. Its later `Foreign-window Spaces and production R4 receipts` step succeeds with engine-only output. A later runtime phase label cannot overturn the failed build step.

## Fast: engine passes; product is absent

[The original runtime summary](fast/runtime-summary.json) records:

| Scope | Actual result |
| --- | --- |
| Direct engine | PASS |
| Formal product R4 | **NOT_RUN** |
| Product receipt | **null** |
| Platform-only fallback | NOT_RUN |
| Overall | INCOMPLETE |

There is no Host `product-result.json`, actual R4 input receipt, worker-request priority trace or group-choice/permitted-rejection runtime trace in this artifact. No product cleanup or physical product return receipt is synthesized for an unstarted Host.

[The engine result](fast/engine-result.json) separately records **`FOREIGN_ENGINE_PASS / verified`**, **26 foreign-window hide/restore request attempts**, and cleanup=true. [The complete engine stderr](fast/engine.stderr.log) preserves the new native `callID`, absolute uptime and Open substep instrumentation exercised by the direct engine. Those C traces do not exercise the uncompiled Swift worker-request path or Host guard diagnostics. [Both fixture quit commands](fast/fixture-cleanup.json) exit 0, and [CI workspace cleanup](fast/ci-workspace-cleanup-receipt.json) reports cleanup=true.

## Provenance and pending receipts

[provenance.json](provenance.json) records verified exact-head artifact ZIP and per-file hashes: source context **15223744848** and fast **15224663389**. All copied files retain their original bytes; the job-step interpretation is explicitly marked as derived API metadata. No binaries or candidate ZIP are committed.

Full and diagnostics originals are **pending at this initial archive** and will be appended separately if available. This directory claims no result for them and no pass for the subsequent actor-isolation correction. The next useful gate is compiling the corrected exact source, then observing actual R4 behavior and confirmed restoration under the unchanged checks and deadlines.
