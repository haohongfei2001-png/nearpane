# P1-B preparation receipt — 2026-11-09

**PREPARATION IMPLEMENTED AND SYNTHETICALLY VERIFIED. Behavioral testing: NOT TESTED.**

Issue: Nearpane #2, “P1-B: Determine separate-Spaces off/on behavior with controlled observations”.
Branch: `spike/p1-spaces-behavior-20261109`.
Base: `beb6471fe360004425760a024636e5a63dbe87d1`.
The preparation source revision is the commit containing this receipt; use `git rev-parse HEAD`
or the final local `git-receipt.json` for the exact delivered HEAD.

Read inputs: [P1 technical gate review](../docs/reviews/P1-TECHNICAL-GATE-REVIEW.md) and
[P1 read-only baseline](P1-READONLY-BASELINE-20261109.md). Baseline inventory research was not
repeated. The probe file referenced by the baseline is absent from this worktree and tracked
tree; this standalone helper implements the three getter signatures documented by the review.

## Delivered preparation

All implementation is under [`experiments/p1-spaces-behavior`](../experiments/p1-spaces-behavior/README.md):

| Path | Purpose |
|---|---|
| `Sources/SpacesObserver/MacSampler.swift` | Public topology, effective separateSpaces, private managed/current-Space inventory, window metadata/membership; read-only bracketing |
| `Sources/SpacesObserver/main.swift` | Explicit bounded observe mode, desktop-free fixture mode, operator stdin markers, safe session lifecycle |
| `Sources/ObservationCore/Model.swift`, `Parsing.swift` | Typed state, raw return statuses, strict integer parsing, unresolved scope/current/window data |
| `Sources/ObservationCore/Stability.swift` | Repeated-state detection, transient periods, topology epochs, stale revision invalidation |
| `Sources/ObservationCore/SessionLog.swift` | Versioned JSONL, bounded markers, 0700/0600 exclusive output, session-only identity aliases and keyed fingerprints |
| `Sources/ObservationCore/SyntheticFixture.swift`, `Tests/ObservationCoreTests/ObservationTests.swift` | Synthetic data and 19 tests |
| `scripts/verify-fixture.py` | CLI/privacy/log-format integration verification; never invokes `observe` |
| `PREFLIGHT-RESTORE.md`, `COMPARISON-TEMPLATE.md`, `SESSION-FORMAT.md` | Future authorization, operation/restore checklist, false/true trial matrix and format contract |
| `evidence/unit-tests.txt`, `evidence/fixture.sanitized.jsonl`, `evidence/fixture-verification.json` | Reviewed synthetic-only verification evidence |
| `SHA256SUMS.txt` | SHA-256 manifest of source/docs/synthetic evidence; paths relative to repository root |

Root `.gitignore` excludes build products, private evidence names and Python cache files.
No production Spaces implementation was added. Raw output is never written to a repository
by the observer. Window titles and application names are not collected at all.

## Verification actually performed

Host compiler environment (not a live display inventory): macOS 27.0, build 26A428, ARM64;
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`). Package minimum build target:
macOS 14, Swift 5 language mode with Swift 6 toolchain/Swift Testing. This is no cross-OS claim.

Final-source compile + tests:

```sh
swift test --package-path experiments/p1-spaces-behavior \
  --scratch-path /private/tmp/nearpane-p1b-build-20261109 \
  --cache-path /private/tmp/nearpane-p1b-cache-20261109 \
  --disable-sandbox --disable-xctest
```

**Exit 0. Build complete in 6.87 seconds; 19 tests passed, 0 failed, in 0.071 seconds.**
The final command compiled the executable, including the CFArray type guards in the live
provider. A standalone `swift build ... --product spaces-observer` also succeeded earlier;
the final binary/fixture hashes below refer to the final-source test build.

Final-binary integration:

```sh
python3 experiments/p1-spaces-behavior/scripts/verify-fixture.py \
  --binary /private/tmp/nearpane-p1b-build-20261109/debug/spaces-observer \
  --output /private/tmp/nearpane-p1b-preparation-20261109-eMsyxg/final-fixture
git diff --check
```

**Exit 0.** 15 ordered events / 12 synthetic samples: 8 transient, 3 stable, 1
stableIncomplete. Verified marker invalidation, topology invalidation, unknown preservation,
identifier/name/note redaction, session-keyed fingerprints, 0700/0600 modes, complete footer,
CLI option validation and refusal to overwrite existing evidence. Help/no-argument paths
also succeeded. A prior synthetic fixture run is retained separately under `fixture/`.

| Required case | Result and scope |
|---|---|
| Stable / unstable repeated states | PASS — synthetic |
| Changed topology, arrangements/scale/mirror, intra-sample changes | PASS — synthetic |
| Unknown scope, missing/outside current Space | PASS — synthetic; remains incomplete |
| Empty/NULL/unavailable/malformed/unknown window membership | PASS — synthetic; no default assignment |
| Marker handling, sampling gaps, slow/out-of-order reads | PASS — synthetic |
| Anonymization, bounded output, private file modes, no overwrite | PASS — synthetic |
| Final executable compilation | PASS |
| Live observer runtime smoke test | NOT RUN — preparation uses fixtures only |
| separateSpaces=false switching behavior | **NOT TESTED — pending explicit authorization** |
| separateSpaces=true switching behavior | **NOT TESTED — pending explicit authorization** |
| Setting changes, logout/restart, window actions, pixels, permission prompts | **NOT PERFORMED** |
| P1-A private ABI/selector/ownership/lifetime validation | NOT VALIDATED HERE |
| Restoration of a changed desktop/session | NOT TESTED; no desktop/session change performed |

Initial build failures were retained, not concealed: missing XCTest in Command Line Tools;
an incorrect manifest argument order during migration to Swift Testing; and two Swift
CGFloat/CFDictionary conversion errors. These were fixed before the passing final command.
Nonfatal toolchain warnings concern inaccessible user SwiftPM cache directories and unused
Command Line Tools framework search paths. No tool installation or permission request was needed.

## Private local artifacts and hashes

Private root: `/private/tmp/nearpane-p1b-preparation-20261109-eMsyxg/` (`0700`).
Logs/receipts are `0600`; the preserved executable is `0700`. This is temporary local storage,
not remote archival storage. Both raw session files in this run contain **synthetic data only**.

| Artifact (relative to private root) | SHA-256 |
|---|---|
| `spaces-observer` (preserved final executable) | `a870201703691b5b2d9480e047b54ebe2d7218afd4d5033d5ff6366609adaced` |
| `final-fixture/raw.jsonl` | `85f5df8af030fd7f5b55c160672c83d75150505c49ff0a02a0d36ff6181da59f` |
| `final-fixture/sanitized.jsonl` | `4cdbd9cdfc37a8f8bb3b72ba8132c9e4649d74bb0f8b7323ef1c319dff16ec93` |

Additional local files: `final-test.log`, `build.log`, four retained initial compile/test
logs, `fixture/`, `final-fixture/verification.json`. `LOCAL-SHA256SUMS.txt` and `git-receipt.json`
record their hashes and the final committed HEAD. The repository contains only synthetic
sanitized output and the small fixture verification receipt; no raw JSONL or executable is committed.

## Remaining gate

The observer cannot establish visible behavior, and repeated matching asynchronous reads
cannot prove atomicity or animation completion. All unknowns and partial sessions remain
explicit. Runtime display/window/Space aliases and fingerprints are session-local; roles
A/B must be re-established privately across setting/login sessions. The private getter ABI
remains experimental and may fail or hang; the helper is isolated from production.

**P1-B behavior, P1-Core and production Spaces support remain unvalidated.** The next behavior
step requires explicit user authorization for the specified native actions/settings/session
changes, followed by the checklist and at least three trials per mode/direction. This session
authorizes none of those actions. This preparation is committed locally only; no push.
