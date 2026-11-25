# Three real group cycles pass; yellow-button adoption and engine cleanup remain failed

[Run 45706743845, diagnostics job 139530560439](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/job/139530560439) executed revision `bbc08a09aef3fa1387a76f1e30f97e437e0f42e9`. These are original receipt/log bytes from [diagnostics artifact 15066330602](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/artifacts/15066330602), plus the source summary from [context artifact 15066076943](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/artifacts/15066076943). `provenance.json` records hashes.

## Confirmed execution

The hosted Apple Silicon machine ran macOS 27 build **26A434 with SIP disabled**. This does not qualify the user's 26A428/SIP-enabled machine. The real Mission Control bootstrap created ordinary Desktop 12 with its system UUID. The actual candidate Rust/C engine, not only its platform atoms, then passed:

- The controller-owned launch panel canary. Its initial home membership was read twice at 15 ms and 39 ms; forward/reverse membership, hidden round trip and panel/Space cleanup were confirmed.
- A foreign-window round trip with a same-app sibling and another-app bystander.
- Independent control of two windows from the same foreign app.
- A group containing windows from two foreign apps.
- Three A → B → C → A cycles with independently checked original identity, geometry, onscreen state and bidirectional Space membership.

There were **22 PASS hide/show receipts** (12 hide and 10 show), followed by one rejected yellow-button adoption request. The controller reports 23 engine hide/restore request attempts; this counter is not a count of confirmed Space writes. Fixture focus preparation separately records two AX writes and one owner focus command. The successful SHOW receipts can correctly retain an aggregate `OWNED` bit for other hidden members.

The source job separately passed **151 Rust tests**, **156 Swift tests with one live-fixture skip**, the Spaces worker build and protocol self-test, evidence tests, native diagnostic tests and the read-only context probe. These source results do not prove the failed runtime check or R4 integration.

## Exact first failure and unresolved physical state

After the cycles, the fixture performed its real AppKit yellow-button action on A0. `NP_HIDE_MINIMIZED` returned UNKNOWN / detail **218 (RestoreFirst)**, flags 128 and owned count 2. The engine was already latched into restore-only state before that request; this receipt does not show an attempted minimized-window bridge call. The original log does not retain the earlier health fault, so it cannot establish whether that fault was an AX timeout, invalid AX object, or changed physical membership.

`NP_RELEASE_SPACES` then returned UNKNOWN / detail **209 (MinimizedOrAX)** with owned count 1, and `np_engine_destroy` returned BUSY (4). The final independent readbacks found:

| Controlled window | PID | Original home | Final Space | Onscreen | Original geometry |
| --- | --- | --- | --- | --- | --- |
| A0 / 53 | 3526 | 12 | 12 | yes | preserved |
| A1 / 55 | 3526 | 12 | **24** | **no** | preserved |
| B0 / 56 | 3542 | 12 | 12 | yes | preserved |

Space 24 remained in the actual inventory. Therefore the original yellow-button check is **FAIL**, engine cleanup is **false**, and overall runtime is **UNKNOWN / cleanupUnconfirmed**. The receipt preserves `operationReason=yellowButtonFailed` separately. A later fixture process quit is not evidence that the engine returned A1 beforehand. The separate Mission Control bootstrap cleanup did complete and restored original Desktop 1; that result also cannot override the engine cleanup failure.

This diagnostics scope did not run the R4 product path, helper Host-crash recovery, full-screen/Split View, or physical desktop gestures. No product or target-machine qualification is granted.

## Follow-up limited to evidence needed for the observed failure

The next source change logs the first health failure and its original lease, the per-member release failure, and the exact retained `AXMinimized` read error/type/PID/window result under the existing opt-in trace. It leaves time budgets, physical predicates, retained-object identity, restore-only behavior and qualification unchanged. This avoids interpreting the generic 209 detail as a proven timeout or rebuilding a writer from an unverified replacement AX object.
