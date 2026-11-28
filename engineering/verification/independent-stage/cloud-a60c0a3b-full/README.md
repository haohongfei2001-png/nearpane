# Source-checked complete candidate at a60c0a3b

Original receipts from the **full** lane of [run 45719769396](https://github.com/haohongfei2001-png/nearpane/actions/runs/45719769396), job 139574853763, [artifact 15073135122](https://github.com/haohongfei2001-png/nearpane/actions/runs/45719769396/artifacts/15073135122). Source is fixed at `a60c0a3b47b5bc688d6bac9c1c9ecb579d32bdf2`. `provenance.json` records the unchanged artifact paths, sizes and hashes.

The actual source run passed **157 Rust and 166 Swift tests, with one Swift case skipped**. The Swift test runner's displayed total is 167, including that skip; it is not 167 passing cases. The newly added current-card rebinding tests, atomic store checks and initial visible-window registration case all executed successfully. Production Swift, worker and acceptance-tool builds and the worker protocol checks passed.

The complete application built and passed its strict bundle signature verification. The inner `Nearpane-independent-candidate.zip` is **25,181,765 bytes** with independently verified SHA-256:

`892cdc1539594473c6a50e2b0d645d4a1a508cbaa5eff5d6731b7f126b1d3150`

This is a complete development candidate with embedded modules and an ad-hoc signature, not a notarized or product-qualified release.

Runtime remains separate. The external client performed one actual R4 AXPress with return 0. All three live groups were bound in a fresh, complete catalog and the original worker was created, but the first activation again stopped with `incomplete` before any engine launch appeared. The terminal result is **FAIL / R4SwitchReadbackFailed**, `foreignWindowReadback=false`, with cleanup confirmed. The earlier [44bc full evidence](../cloud-44bc3759-full/README.md) shows the same observed boundary and the complete handler trace; subsequent phase diagnostics must determine the exact failing guard.

This VM's normal engine independently failed its first yellow-button completion check and cleaned up. Three-cycle results from older VMs do not replace that uncompleted path. Full R4 cycles, group editing, native system interactions and same-profile crash/restart acceptance remain unexecuted here. The hosted environment is build 26A434 / arm64 / SIP disabled; it does not qualify the target build 26A428 with SIP enabled.
