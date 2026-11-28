# 3d79921c full: complete package built; duplicate action query blocks R4 input

Run [45731326197](https://github.com/haohongfei2001-png/nearpane/actions/runs/45731326197),
job `139613766890`, source
`3d79921c5a9479a92173b4bfec837a08d14b227b`.

Source checks passed: **161 Rust**, **170 Swift and 1 skipped**, plus the native
helpers, worker protocol and evidence checks. The complete companion-workspace
candidate built and passed bundle-signature checks. The original metadata
still has `qualificationGranted=false`.

The candidate ZIP is **25,321,984 bytes**, SHA-256
`a9c668757b9f3be3c23763bea03893c4ae072778f62ee8cf135f39c1009af239`.
It is in artifact `15077029046`, not in this source archive. A build and signature
pass do not establish physical R4 behavior or qualification on the user's
build 26A428 / SIP-on Mac.

## Actual runtime result

This full VM's independent raw controller returned **FOREIGN_ENGINE_PASS**:
initial and later yellow-button integration, three repeated switch cycles,
same-app independent windows, cross-app grouping, focus restoration and cleanup
all passed. This remains distinct from the same revision's fast VM, whose
passive health failure is preserved in `cloud-3d79921c-r4-fast`.

The actual R4 result is **BLOCKED**, `actualR4Inputs=0`, cleanup **true**.
The external client discovered a unique enabled AXButton and positively read
AXPress support. Its final six-field batch again confirmed role, identifier,
enabled state, panel identity and geometry. Only the repeated action-name read
failed with **AXCannotComplete (-25204)**. The original receipt records
`issued=false`, `prePressRediscoveries=0`, `reason=prePressEvidenceChanged`.
Its initial `axError=-25200` is not the result of an attempted action.

This is the same first rejection observed independently in the fast lane. The
next helper keeps the exact discovered AX element, rechecks all mutable
conditions and omits the redundant action-name query. Its first action-support
read remains mandatory; the one actual AXPress still has no retry.

No R4 handler, group-choice worker, Finder self-reference check or product
NP_LAUNCH ran here. Lifecycle, system-interaction and dispatch readback tests
therefore remain NOT_RUN. The requested product path did not pass, so this
workflow correctly concluded failure despite successful source and build steps.

## Timing boundary

The opening Dock confirmation passed: read 1116.247271–1116.249685 seconds
(2.41 ms), request 27.29 ms. The pre-press failure was recorded at
1119.436189. A later ordinary Dock read ended at 1119.822869 and was delivered
with an age of 1353.75 ms during teardown, causing the existing freshness guard
to revoke ownership. That later observation did not precede or cause the failed
action-name query. It also does not exercise the newly detached post-dispatch
acceptance reader, because no R4 action was issued.

The receipts are byte-for-byte originals. `provenance.json` records source
artifact paths, byte counts, and hashes for this archive and the candidate.
