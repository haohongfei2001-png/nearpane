# 2f3eddda full: complete package and raw engine pass; R4 context unconfirmed

Run [45734124458](https://github.com/haohongfei2001-png/nearpane/actions/runs/45734124458),
job `139623104737`, source
`2f3eddda042e4280d80c3880127422c3819b6ebd`.

The original source receipt records **162 Rust passed**, **170 Swift passed and
1 skipped**, with the worker/protocol/native/evidence checks passing. The full
companion-workspace candidate built and passed bundle-signature checks.
`qualificationGranted` remains **false**.

Candidate ZIP: **25,323,844 bytes**, SHA-256
`d0c00ccb9da79502c0c44e0037a969bd6b094e8886228b6d612a920cd838af9c`,
in artifact `15077963583`. This archive preserves its original metadata/hash;
the ZIP remains a workflow artifact.

## Actual runtime receipts

The raw foreign-window controller returned **FOREIGN_ENGINE_PASS**. Initial
and later yellow-button checks, three repeated switch cycles, same-app
independence, cross-app grouping, focus restoration and cleanup all passed.

The product itself recorded **BLOCKED**,
`reason=realExternalR4ButtonNotAccepted`, `actualR4Inputs=0`, cleanup **true**.
The external helper discovered one matching button and positively read its
AXPress support, then rejected the pre-press context check with
`reason=prePressContextChanged`. No AXPress was attempted. The default
`axError=-25200` is not a failed action's return value.

This source combines configuration bytes, live/disk parent identity/signature,
onscreen CG panel, unchanged frame and retained AX-panel mapping in one guard.
The original receipt does not identify which component failed or whether the
failure was an incomplete read or a positive change. No specific component is
therefore diagnosed from this run. The next helper records each executed
context check in the same order and the first rejecting component; checks not
reached remain NOT_RUN. Configuration, signature, process and panel identity
still must pass, with no context-change retry. A change from the earlier panel
frame becomes diagnostic only: this is a semantic AXPress on the same retained
button, whose latest identity, owner, enabled state and geometry must still
match the fresh onscreen panel. No old pointer coordinates are used. This
adjustment does not claim that panel movement caused this run's failure.

The Dock remained ordinary, including an opening confirmation with a 3.97 ms
actual read and 16.68 ms total request. The only ineligible transition was
`stopped=true` during cleanup. This full VM did not reproduce the fast VM's
confirmed queue-age rejection and did not reach the Finder desktop-focus
reader or product NP_LAUNCH. Its successful raw engine result must not be
reported as a working R4 path.

All files are byte-for-byte originals. `provenance.json` records source artifact
paths, byte counts and SHA-256 hashes. Target build 26A428 / SIP-on qualification
and later product tests remain outstanding.
