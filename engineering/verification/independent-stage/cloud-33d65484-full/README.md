# Complete candidate and input-discovery result at 33d65484

These are unmodified receipts from the **full** lane of
[run 45715629275](https://github.com/haohongfei2001-png/nearpane/actions/runs/45715629275),
job `139560823872`, artifact `15070133110`. `provenance.json` lists original
artifact paths, byte lengths and SHA-256 hashes. Large application binaries and
repeated screenshots remain in the Actions artifact.

## Verified build

The actual source run passed **155 Rust tests and 162 Swift tests, with one Swift
case skipped**. The new worker-lifecycle and cold-owner recovery tests executed,
as did the worker build/protocol checks and the existing diagnostic/evidence
tests. Complete application build and strict bundle signature checks passed.

The inner `Nearpane-independent-candidate.zip` has **25,105,091 bytes**, SHA-256
`5a5fbeda6d9356c12486987a72a0031d5946c342f2c5a0b9e10774d3f83dd64f`.
The original candidate manifest and checksum file are included. This is a
buildable candidate, not a product acceptance result.

## Actual runtime limits

The normal engine passed its own launch canary, third-party round trip,
same-application independent windows, cross-application grouping and all three
repeated switch cycles. The yellow-minimize test failed and remains failed in
`engine-result.json`. Cleanup was separately confirmed: the original engine
returned the three controlled windows and restored the complete original Space
inventory. This hosted VM is build **26A434 with SIP disabled**, as recorded in
that receipt; it does not qualify the user's SIP-enabled build 26A428.

The product reached a complete current-desktop catalog with three fixture groups
and a visible R4 panel. Its external accessibility client could not complete
read-only discovery within this version's 100 ms message / 4 s discovery bounds:
AX window/role/identifier reads returned `kAXErrorCannotComplete` (`-25204`). The
raw external receipt explicitly says `issued=false`; **no AXPress occurred and
`actualR4Inputs=0`**. Its initial `axError=-25200` value is not the return value of
an attempted button action. The final product outcome is
**BLOCKED / realExternalR4ButtonNotAccepted**, with cleanup confirmed.

There is no handler-failure claim: the input never reached a product button, and
the product trace is empty. The snapshot reported nonempty appearance/group
lifetimes but no visible group projection at failure; this record did not yet
capture the contemporaneous sample age, so it cannot establish a store-binding
failure. Later bounded discovery and explicit-intent binding changes require
their own actual runs.

The same-profile restart scenario did not run because the normal R4 path did not
pass. Successful source tests do not stand in for a real crash, worker return,
restart and second R4 selection. No production qualification is granted.
