# Hosted ordinary-desktop identity diagnosis

The early [context artifact 15053873438](https://github.com/haohongfei2001-png/nearpane/actions/runs/45682515823/artifacts/15053873438) from revision `85762ae0acca965528dcdddcc1177698927abea0` identifies the preceding preflight failure without moving any window. A real AppKit run loop, positive WindowServer connection, one active display, Dock, and WindowManager were observed. The raw managed catalog contains ordinary Space **1**, type **0**, but both its current entry and matching roster entry contain **an empty UUID string**. The production adapter rejected `current-record-identity`; its checked inventory consequently rejected the incomplete managed identity.

This evidence supports neither “no GUI exists” nor “foreign hidden-Space migration failed.” It identifies a specific ordinary-desktop identity precondition before any movement. No substitute UUID is manufactured. The next hosted experiment may establish an ordinary desktop through an actual system operation and rerun the same unchanged physical checks.

Source checks passed: 147 Rust, 140 Swift, 8 Python tests; one signed live fixture was skipped. Worker compilation/protocol self-test and the read-only context executable also passed. `windowWrites` remains zero.

The original context here used C constant names for two CGSession dictionary keys. Their omission is not evidence of missing console access; a subsequent diagnostic patch uses the constants’ actual values. The raw files here remain unchanged and their SHA-256 hashes are recorded in `summary.json`.

## Final candidate and runtime receipts

The same run completed with a successful workflow conclusion and produced a strictly verified complete candidate in [artifact 15055383988](https://github.com/haohongfei2001-png/nearpane/actions/runs/45682515823/artifacts/15055383988). Its candidate ZIP SHA-256 is `3c0affb49a1d1e285a26a08f90c54c9f006f3ed5571d1d868581282ef4ea0de9`. `candidate.json` and `candidate.sha256` are the unmodified packaging receipts.

A green job is not a foreign-engine pass: the controller reported `BLOCKED ordinaryCurrentDesktopCountNotOne`, with zero foreign writes and no canary dispatch. The product reported `BLOCKED fixtureGroupsNotReady`, zero R4 inputs, and independently confirmed cleanup. The read-only ABI/mask-15 correction removed the previous cleanup misdiagnosis; it did not manufacture a valid native UUID or a window-migration result. Raw terminal receipts are preserved here.
