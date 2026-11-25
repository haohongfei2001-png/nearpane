# Real CI desktop initialization and complete cleanup

These are byte-for-byte originals from the **full** lane of [run 45695479739, attempt 1](https://github.com/haohongfei2001-png/nearpane/actions/runs/45695479739), revision `e630b6bc891cde3002592b7fb8a45e7ec62ec48b`, [artifact 15061877592](https://github.com/haohongfei2001-png/nearpane/actions/runs/45695479739/artifacts/15061877592). The hosted runner used build **26A434 with SIP disabled**. This is separate from the shorter diagnostics lane of the same run and does not qualify the user's 26A428/SIP-enabled environment.

## What the saved originals establish

`ci-workspace-prepare-receipt.json` reports `READY`, phase `readyCreated`, current ordinary desktop **12**, with the actual system UUID `73C998CE-0CC6-FD8C-B71D-E539680F5723`. The helper used native system controls to create and select this desktop. It did not synthesize a UUID or write a window's Space membership.

`ci-workspace-cleanup-receipt.json` reports `READY`, `cleanup: true`, phase `cleaned`, and current desktop **1**. In `ci-workspace-state.json`, both the complete original and final managed-desktop inventories contain only `{id: 1, type: 0, uuid: ""}` on the same display. Created desktop **12 is absent** from the final inventory, and `pendingAdd` is false. The retained `created` record is historical ownership evidence, not a claim that the deleted desktop remains. Both helper processes exited zero. The final empty UUID on original desktop 1 is the runner's original state; cleanup did not fabricate an identifier.

The bounded stable native selection and empty-desktop confirmation therefore completed in a real GUI session. The receipts record 6 system inputs at preparation and 11 cumulatively at cleanup, `directWindowOperations: 0`, and `physicalGestureClaimed: false`.

## Build success and runtime limits

`source-summary.json` records **150 Rust tests and 153 Swift tests passed, with 1 Swift test skipped**. The evidence checks, native diagnostic checks, read-only context, worker build and worker protocol checks also passed. `candidate.json` records source checks, the complete application build and bundle signature verification as `PASS`. The candidate ZIP digest recorded by the original `candidate.sha256` is:

```text
275d4fd4476ae8360fdcc535fe0382bcf1da35722ac127a21cec9cf183d4383e
```

These build and cleanup results do not establish complete product behavior:

| Runtime path | Result in this artifact | Scope |
| --- | --- | --- |
| Normal engine | `BLOCKED`, `controlledFixtureFocusUnavailable`, zero window writes | The then-current fixture focus preparation prevented the engine sequence from running. |
| Production platform atoms | `PLATFORM_FOREIGN_PASS`, 2 completed foreign cycles, 4 writes, `cleanup: true` | Independent repeat of real third-party hide/return through internal hidden Space 13, with its final cleanup; no R4 or engine-state-machine pass. |
| R4 product acceptance | `BLOCKED`, `fixtureGroupsNotReady`, zero actual R4 inputs | Its terminal `lastReadiness.snapshotAvailable` is false. This is a final sample, not proof that no earlier snapshot existed. The end-to-end product sequence did not pass. |

The original engine, platform and product receipts remain in the artifact at the paths and SHA-256 digests recorded under `referencedOnly` in `provenance.json`. Their full event streams are deliberately not duplicated here. All qualification fields remain **false**.

## Provenance

`provenance.json` is a separately generated index, not a runtime receipt. It maps each of the six copied originals to its exact artifact path, byte length and SHA-256, and records hashes for the three referenced runtime receipts. The original files were copied without JSON reformatting or other changes. The ZIP itself remains in the linked artifact; the absolute runner pathname inside the original `candidate.sha256` is preserved verbatim.
