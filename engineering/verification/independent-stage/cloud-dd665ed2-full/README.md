# dd665ed2 full: package built; real R4 press reaches an actually stale confirmation

Run [45736296714](https://github.com/haohongfei2001-png/nearpane/actions/runs/45736296714),
job `139630249673`, source
`dd665ed2b9fe46731d518e811e8f98c948d59227`.

Source checks passed: **162 Rust**, **172 Swift and 1 skipped**, plus the native
helpers, worker protocol and evidence checks. Both new
`IndependentStageDockFreshnessTests` ran and passed in the source log. The full
companion-workspace candidate built and passed bundle-signature checks. Its
original metadata retains `qualificationGranted=false`.

Candidate ZIP: **25,324,809 bytes**, SHA-256
`2a492dd74ef3149aea970ba628c454b24980036b4788ea7bc44be7297955038f`,
in artifact `15079243584`.

## Actual runtime result

This VM's raw foreign-window controller returned **FOREIGN_ENGINE_PASS**,
including both yellow-button checks, repeated switches, same-app independence,
cross-app grouping, focus restoration and cleanup.

The product result is **FAIL**, `reason=R4SwitchReadbackFailed`,
`actualR4Inputs=1`, cleanup **true**. The external client positively checked
the complete context and original AXButton, then issued one AXPress at uptime
1164.231914 and received success. All four pre-press context checks were true;
`panelFrameChanged=0` (unchanged). The real handler submitted and dequeued the group
selection. Its explicit system confirmation then expired:

| Recorded phase | Uptime in seconds |
| --- | ---: |
| Confirmation requested | 1164.369802542 |
| Actual Dock read began | 1164.371123917 |
| Actual Dock read ended | 1164.372801583 |
| Expiry trace emitted | 1165.144601083 |
| Dispatch ownership revoked | 1165.144827250 |

The read lasted **1.68 ms**, but its recorded age at delivery was **771.66 ms**.
The actual sampling-to-acceptance interval therefore exceeded the unchanged
750 ms limit. This was a real stale delivery, not the earlier request-queue
misclassification. The navigation confirmation returned false and the group
job did not start. No Finder self-reference check or product NP_LAUNCH ran.

The next run's bounded external Host stack sampling is intended to locate the
UI work delaying these observations. The first external-press harness itself
awaits asynchronously; no synchronous process wait or blocking pipe read runs
there. The sampling does not change freshness, focus, window identities or
action gates, and its availability cannot promote a product receipt.

The full and fast raw-engine passes remain separate from the diagnostics VM's
canary-close observation failure and from both product failures. Source/build
success does not establish a working R4 switch, held-window preview or target
build 26A428 / SIP-on qualification. All included receipts are original bytes
with artifact paths, byte counts and SHA-256 provenance.
