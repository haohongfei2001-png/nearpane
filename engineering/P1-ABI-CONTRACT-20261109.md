# P1-A ABI / CF contract receipt — 2026-11-09

Current static/offline scope: **12 PASS, 0 FAIL, 6 NOT TESTED**. Live SkyLight contract verification remains open. This report does not close issue #1, P1-Core, or production Spaces readiness.

Branch: `spike/p1-abi-20261109`. Base and current local HEAD: `beb6471fe360004425760a024636e5a63dbe87d1`. Local staging/commit is blocked by the current filesystem sandbox: `git add -- experiments/macos-spaces-abi` exited 128 because it could not create the linked worktree's `index.lock` in the common Git directory. No sandbox exception, alternate Git directory, push, or branch change was attempted. The completed files remain in this worktree, ready for a local commit when that Git metadata path is writable.

Environment: macOS **27.0 (26A428), arm64**; Apple Clang **21.0.0 (clang-2100.3.34.2)**; Swift **6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)**. SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`. UTC receipt directory dates correspond to 2026-11-09 in Asia/Shanghai.

## Safety correction and complete execution history

The current code permits only membership selector `0x7`. The C wrapper has no selector argument, the Swift direct-function-pointer call hard-codes `0x7`, and no alternate-selector negative test remains. Default builds contain no `dlopen`, `dlsym`, `dlclose`, SLS, or window-list imports. The CLI has only the synthetic backend and refuses builds with live loading enabled. The dormant C live code is syntax-checked without execution.

The initial sandbox failure was **not the only earlier execution**. Before the user's safety correction, two higher-privilege runs were started and completed, including a selector 0–7 matrix. Those runs were a mistake relative to the corrected boundary; they are disclosed, preserved and excluded from the corrected acceptance gate. It would be inaccurate to describe all historical membership work as unexecuted.

| Private run under `experiments/macos-spaces-abi/.local/` | Actual outcome | Treatment |
|---|---|---|
| `20261108T170404.024735Z` | Initial sandbox helper exit 2: managed query NULL, fewer than two usable window metadata records; **0 membership calls** | Preserved failed live prerequisite; exact blocker for current permitted live work |
| `20261108T170525.078263Z` | Pre-correction privileged matrix, leaks and ASan runs; selectors 0–7 in matrix; `out_of_range` input guard failed and allowed one extra selector-7 query | Historical **FAIL** preserved; not a current live PASS |
| `20261108T170715.959982Z` | Pre-correction privileged runs after guard fix; matrix selectors 0–7, fixture checks passed; final child ended at 17:07:38 UTC | Preserved, excluded from corrected gate; never rerun after correction |
| `20261108T171419.473624Z` | Post-correction offline matrix/ASan passed; `leaks` exit 255, unable to obtain helper task port | Preserved; no permission escalation or retry of `leaks` |
| `20261108T171713.345866Z` | Final offline build, faults, 45-row matrix, allocation observer and ASan passed | Current static/offline evidence |

All five run manifests were checked against every archived file. Each directory retains commands, stdout, stderr, exact tested source snapshots and binaries. Only rebuildable compiler module caches are excluded from manifests. Real identifiers and raw historical results remain ignored and private. Public evidence contains only synthetic data, sanitized historical counts and hashes. No initial read-only baseline was reexecuted, and no switching, focus-changing, window mutation, setting change, permission-request or pixel-capture API was used by this workstream.

## Verification matrix

| Item | Status | Evidence / limit |
|---|---|---|
| CLI isolation, no Host integration | PASS | Default binary import audit; only new experiment/report files |
| Pinned yabai declarations and C widths | PASS | Exact declaration-line comparison; Clang static type assertions; int/Int32/CGWindowID = 4 bytes, UInt64/pointer/CFIndex = 8 |
| C/Swift function-pointer and encoding comparison | PASS | **Synthetic only:** 45 rows × four paths, zero differences |
| Empty, single, multiple, duplicate, invalid inputs | PASS | 15 synthetic cases × three rounds; original NSNumber bridge and explicit SInt32 construction |
| Selector restriction | PASS | Only literal `0x7` at either call site; no sweep or alternate-selector calls |
| CFArray/NSDictionary/NSNumber, NULL/empty, exact IDs | PASS | 15 parser fixtures, wrong top/element types, missing id64, booleans, strings, fractional/negative values, high integer values |
| Safe input guards | PASS | Nine invalid inputs rejected before backend; zero backend-call deltas; UInt64.max regression fixed |
| Fault injection | PASS | Six local faults: missing library/symbol, NULL/malformed inventory, NULL/wrong-type membership; managed failures stop before membership |
| Controlled CF ownership / release | PASS | 50,391 observed allocations = 50,391 deallocations; 0 outstanding blocks/bytes; C/Swift ownership accounting balanced |
| Repeated fixture calls | PASS | 100 warmup + 1000 measured iterations; no membership/inventory drift or parse errors |
| AddressSanitizer | PASS | 200 measured iterations, exit 0, empty stderr; 13,581 observed CF allocations all released |
| Whole-process leak scan | NOT TESTED | `leaks` exit 255: `Couldn't get task port ... immediately after launch`; sandbox unchanged, no retry |
| Live selector-7 bridge and input differential | NOT TESTED | Initial sandbox NULL inventory / missing sample; no current permitted live membership run |
| Live return schema, high IDs, private Copy +1 contract | NOT TESTED | Static/fixture evidence cannot establish private runtime guarantees; prior privileged runs excluded |
| Live selector semantics, deduplication and ordering | NOT TESTED | No current permitted live comparison; no semantics inferred from synthetic multi-ID rules |
| Connection threads, session invalidation, sleep/wake | NOT TESTED | No thread/session disruption, logout, display reconfiguration, sleep/wake or WindowServer restart |
| Cross-build private API stability | NOT TESTED | Current OS/toolchain recorded only; no compatibility promise |
| Evidence preservation | PASS | Five verified private manifests, sanitized receipts, baseline provenance and public SHA-256 manifest |

The fixture's main connection is an invented integer. Repeated equality verifies the C/Swift plumbing, not a process-wide or thread-safe SkyLight connection contract. The program never releases a main connection. Function pointers leave Swift scope before shutdown; pointers are cleared and calls after shutdown are rejected. The dormant loader keeps the handle until pointer use ends, but its real runtime lifecycle is not verified in the corrected scope.

## Concrete type and ownership findings

The three declarations match yabai revision `dd845723416f5fe92af49fad5ebab00369e07edd` (`extern.h` lines 9, 22, 60); `window.c` uses SInt32 window numbers, selector `0x7`, and releases Copy results. This establishes a fixed third-party reference, not an Apple ABI contract.

The offline test compares C/explicit SInt32, C/Swift NSNumber bridge, Swift/explicit SInt32 and Swift/NSNumber bridge. CF types are checked before collection access; missing or nonnumeric IDs never become zero by default. Fixtures include `2^32 + 17`, `2^53 + 1`, `Int64.max` and `UInt64.max`. These are fabricated values, not observed live Space IDs. The historical range-guard failure demonstrated why successful `CFNumberGetValue(...SInt64...)` alone is insufficient to reject an unsigned value above the 32-bit window domain.

Final C accounting: 1,153 input arrays created/released; 1,186 explicit window numbers created/released; 3,390 non-NULL Copy results released. Swift consumed 3,385 non-NULL retained fixture returns once. After the autorelease pool drained, the custom fixture allocator reported **50,391 / 50,391 allocations/deallocations and zero outstanding blocks/bytes**. Malformed-response fault paths also ended balanced. The allocator uses only local malloc/free callbacks, with no process attachment or allocator interposition.

The whole-process allocation sample rose from 665,680 to 900,032 malloc bytes during the measured loop (resident bytes 9,469,952 to 9,748,480). It was not flat. No cause is assigned to that difference, and a full-process leak-free claim is not made: the observer covers controlled CF allocations only, while `leaks` was sandbox-blocked. ASan checked memory access errors in instrumented test code with `detect_leaks=0`; it is not a substitute for a global leak scan or private-framework instrumentation.

CF Create/Copy ownership rules justify how local CF fixtures are consumed; they do not independently prove that these private functions obey an undocumented +1 contract. CF numeric storage may differ from the requested construction type, so the result records construction intent, actual storage, ObjC encoding, conversion status and exact decimal value separately.

## Commands and receipts

Executed final verification command, in the original workspace sandbox:

```sh
python3 experiments/macos-spaces-abi/run-verification.py
```

Its exact expanded compiler/tool/helper argv, UTC start/end times, expected/actual exits, environment overrides and stdout/stderr hashes are in [command-receipts.json](../experiments/macos-spaces-abi/evidence/20261109/command-receipts.json). In that file `$EXPERIMENT` means the workspace's `experiments/macos-spaces-abi` directory; `$RUN` means its `.local/<run>` directory. The private `commands.json` files retain the full absolute paths.

Key compiler/test forms:

```sh
xcrun clang -std=c11 -Wall -Wextra -Werror -g -O1 -c "$EXPERIMENT/skylight-shim.c" -o "$RUN/shim.o"
xcrun swiftc -g -Onone -warnings-as-errors -module-cache-path "$RUN/module-cache" \
  -import-objc-header "$EXPERIMENT/skylight-shim.h" "$EXPERIMENT/abi-probe.swift" "$RUN/shim.o" -o "$RUN/abi-probe"
xcrun clang -std=c11 -Wall -Wextra -Werror -DNEARPANE_ENABLE_LIVE=1 -fsyntax-only "$EXPERIMENT/skylight-shim.c"
"$RUN/abi-probe" --iterations 1000
ASAN_OPTIONS=halt_on_error=1:detect_leaks=0 "$RUN/abi-probe-asan" --stress-only --iterations 200
python3 experiments/macos-spaces-abi/summarize-evidence.py \
  experiments/macos-spaces-abi/.local/20261108T171713.345866Z \
  experiments/macos-spaces-abi/evidence/20261109
```

Expected injected-fault exits are 0 for synthetic loader/symbol failures and 2 for managed/membership failures; each is validated from its structured output. No live helper command is provided for this scope. The expanded legacy commands remain in the historical receipt section solely for audit.

The requested baseline inputs are recorded in [baseline-provenance.json](../experiments/macos-spaces-abi/evidence/20261109/baseline-provenance.json). At the specified base HEAD, two documents had moved to root-level `engineering/` and `architecture/`, and the old read-only experiment had been removed. Its three inputs were read from commit `159dc5b6f1c4d5d511ddf4e4fcac35be2a535f0e` with `git show`; no checkout, reset or baseline execution occurred.

## SHA-256 and handoff

Full public file list and SHA-256: [SHA256SUMS.txt](../experiments/macos-spaces-abi/SHA256SUMS.txt). Full private file hashes: [raw-evidence-index.json](../experiments/macos-spaces-abi/evidence/20261109/raw-evidence-index.json). No raw live JSON or binary is included in the commit candidate.

| Receipt | SHA-256 |
|---|---|
| Initial failed live `matrix.stdout` | `63dbab03a6e81319dcb0afb1111f1103c215a03c279c48559610464e4e3a9ed3` |
| Initial private run manifest | `1e85a6a5adf6c59ae64e234bfb70530fd7ad43c82f47b40aab20970ecf8325a4` |
| Final offline `offline-matrix.stdout` | `9a9acc8fb04e059f505cced89cf52eca352f2b5224bdaabdcfe84fcbcd550ebc` |
| Final offline private run manifest | `ed2cad171d5132c34ff68fe24ebb86e584c6f71f9ededf06d744ea50a5750fa3` |

The initial attempt to stage from the isolated Codex execution sandbox was blocked by its worktree index-lock policy. The sanitized source, report, receipts and hash manifest are now being consolidated from the trusted repository workspace. Private raw evidence and compiled binaries remain excluded. Nearpane main/design, Saytile main and Riftlet main were not modified by this workstream.

References: [pinned yabai declarations](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h), [pinned window calls](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c), [Apple CF ownership policy](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFMemoryMgmt/Concepts/Ownership.html), and the installed SDK's `CoreFoundation.framework/Headers/CFNumber.h` (construction type, storage type and conversion caveats). Private API stability beyond build 26A428 is not claimed; even that live contract remains unverified under the corrected boundary.
