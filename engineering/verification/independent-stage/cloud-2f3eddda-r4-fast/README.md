# 2f3eddda fast: real R4 press, then a fresh Dock read is rejected by queue age

Run [45734124458](https://github.com/haohongfei2001-png/nearpane/actions/runs/45734124458),
source `2f3eddda042e4280d80c3880127422c3819b6ebd`.

The full job's early source receipt records **162 Rust passed**, **170 Swift
passed and 1 skipped**, with the worker/protocol/native/evidence checks passing.
The fast lane compiled the existing foundation debug Host with the actual
production R4/Spaces sources. Its raw controller returned
**FOREIGN_ENGINE_PASS**, with initial and later yellow-button checks,
three switch cycles, same-app independence, cross-app grouping, focus and
cleanup all passing. This does not qualify the complete workspace package or
the user's build 26A428 / SIP-on target.

The raw backend trace also exercises the narrow health-read grace: the original
hidden window 57 in owned Space 27 returned AXCannotComplete at 300 and 649 ms,
then completed both positive health observations at **735 ms**, within the
existing-start 1000 ms recovery bound. This is an actual recovery beyond the
former 650 ms deadline. No extra window move or AX setter was issued by that
health recovery.

## Actual product path

The external client issued one real AXPress at uptime 1483.599970 and received
success. Discovery positively read AXPress support. Pre-press kept the same
original AX element, rechecked all six attributes and owner, and correctly
recorded `actionRead=NOT_REPEATED`. No rediscovery or second action occurred.

The product trace then records `current-card-press`, `choose-group`,
`navigation-submit`, `navigation-dequeue`, a successful system confirmation,
and `group-job-start`. The confirmation's actual Dock read took 2.73 ms; total
request time was 696.69 ms and passed the existing 750 ms gate.

The next polling read was rejected:

| Event | Uptime in seconds |
| --- | ---: |
| Actual Dock sampling began | 1484.918672167 |
| Actual Dock sampling ended | 1484.919942625 |
| Rejection trace was emitted | 1485.403762417 |
| Ownership was revoked | 1485.403994625 |
| Group job reported superseded | 1485.508084167 |

The actual read lasted **1.27 ms**, with **483.69 ms** age at delivery;
sampling start to rejection was **485.09 ms**. Nevertheless the old
`DisplayPanels.accept` used its earlier request timestamp and reported
`sampleExpired`. The raw trace does not include that poll's exact request-start
timestamp, so its precise queue delay is unavailable. The source condition and
the measured read interval show that this rejection counted time before the
physical observation began.

The next source fix keeps the same **750 ms total bound from actual sampling
start through acceptance**, including read time and delivery delay. It requires
finite, ordered `start <= end <= now` timestamps and retains native-state and
generation checks. Pending polling expires the last accepted actual read rather
than an unrelated queued request. Request timing remains diagnostic; it grants
no freshness. The regression uses the real read/rejection-trace timestamps and an
explicitly constructed earlier request time, not a fabricated measured one.

## Physical and visual result

Product result is **FAIL**, `reason=R4SwitchReadbackFailed`,
`actualR4Inputs=1`, cleanup **true**. The final independent read shows all three
fixture windows still onscreen on home Space 12 with their frames preserved.
The expected target is not the global focused window. No product Finder
self-reference check or NP_LAUNCH occurred. Held-window previews and subsequent
group/lifecycle/system checks therefore remain unverified.

The original `r4-readback-failed.png` was visually inspected: it contains three
real red/blue/green fixture-window previews. The recorded preview metrics are
three cache entries, 67 delivered frames and no capture in flight. These are
previews of the still-visible windows, not proof of successful held previews.

The detached acceptance reader did run: its last physical sample took **28.25
ms** and reached the MainActor **280.12 ms** after read end. It did not verify
the requested workgroup switch. No receipt has been normalized into a pass.
All included files are byte-for-byte originals with SHA-256 provenance.
