# Hosted full candidate, 5e458d1d

[Run 45697978438](https://github.com/haohongfei2001-png/nearpane/actions/runs/45697978438), full job `139500284481`, artifact `15062876476`.

Source checks passed: 150 Rust tests, 154 Swift tests with one explicitly skipped, 9 evidence-classification tests, 8 native diagnostic tests, the actual Spaces worker build/protocol self-test, and the read-only console diagnostic. The complete workspace candidate built and passed strict bundle verification. Its exact archive SHA-256 is `0fabd6c1ede4640e3fbc59edf61fa23c07b4029008884cd094a61fb86f483fa2`; these facts do not qualify production window scheduling.

The normal engine is **BLOCKED before NP_LAUNCH**, with zero foreign writes. `fixtureFocusPreparation` records the self-activation request being consumed, but the fixture remained inactive, its window was not key, and the foreground PID remained 357 rather than the controlled fixture PID 32739. The controller rejected that state. It is neither an executed canary failure nor a failed foreign move.

The separately labelled platform diagnostic again completed two foreign-process round trips (A0 and B0, four bridge writes) and verified cleanup. Its complete raw receipt remains in the artifact; `provenance.json` records its exact SHA-256 instead of duplicating the earlier full positive record in `cloud-bdedf131-platform`. This hosted runner is build 26A434 with SIP disabled, not the user's build 26A428 with SIP enabled.

The real R4 harness is **BLOCKED**, `fixtureGroupsNotReady`, with zero R4 inputs. Its fresh ordinary catalog includes all three controlled windows on actual home 12, but is marked incomplete by 15 `membershipUnavailable` entries. `product-result.json` preserves those exact PID/window reasons and the redacted three-window roster; no catalog requirement was relaxed to call this a pass.

CI workspace creation and removal both completed with original raw `READY` receipts. Both controlled fixture processes consumed the nonce-bound quit command and exited normally. The job's green result means no uncontained failure was recorded; it does not change the engine/R4 `BLOCKED` status.

The eight small files above are byte-for-byte copies of the original artifact files, including the JSON stdout from CIWorkspace. `provenance.json` maps each to its original path, byte count, and SHA-256. It is the only generated metadata file; this README explains the verified scope.
