# 3d79921c fast: batch attributes pass; final action-name read is incomplete

Run [45731326197](https://github.com/haohongfei2001-png/nearpane/actions/runs/45731326197),
source `3d79921c5a9479a92173b4bfec837a08d14b227b`.

The full job's early source receipt records **161 Rust passed**, **170 Swift
passed and 1 skipped**. The fast job built the existing foundation debug Host
with the production R4 and Spaces sources. This does not qualify the complete
companion-workspace release package.

## Actual R4 result

Product status **BLOCKED**, `actualR4Inputs=0`, cleanup **true**. Discovery and
final pre-press each read all six button attributes in one successful batch.
The final batch positively confirmed the requested AXButton identifier, enabled
state, exact panel and geometry within that panel. The separate final
`AXUIElementCopyActionNames` call then returned **AXCannotComplete (-25204)**;
the discovery call had succeeded and included AXPress.

`issued=false`, `reason=prePressEvidenceChanged`, and
`prePressRediscoveries=0` are original receipt values. This source only retried
an incomplete pre-press role or identifier read. It did not retry this separate
action-name read. `AXUIElementPerformAction` was never called; the receipt's
initial `axError=-25200` is not an action return value. Its
`pressSupported=false` means the helper could not confirm support after the
failed read; it does not prove that AXPress support disappeared.

The next helper retains the exact AX element whose discovery positively
confirmed AXPress, then rechecks its mutable identity, enabled state, panel,
geometry and owner without repeating the action-name query. It explicitly
records that the action list was not read again, rather than fabricating a
successful read. Discovery still requires actual positive action support;
unknown discovery support is recorded as null. The original six-second budget,
pre-action role/identifier rediscovery and single-action rule remain. An error
from the actual AXPress remains terminal and is never retried. No result here
proves an AX object replacement, a successful Finder self-reference check, or
an actual workgroup switch.

## Actual native controller result in this VM

The independent raw controller recorded **FAIL**, `reason=yellowButtonFailed`,
cleanup **true**. Initial yellow minimize, repeated switches, same-app
independent scheduling and the cross-app group passed. The later yellow-button
check failed, leaving its subsequent focus-restoration check NOT_RUN. The first
recorded backend failure preceded that request: passive health could not read
the already-hidden same-app sibling's AXMinimized state, reporting
`health-ax-unavailable` / `health-owned-readback` detail 230. The later operation
14 returned RestoreFirst detail 218 after about 22 ms; it did not start a second
minimize transition or time out at the one-second minimize deadline.
The separately archived diagnostics VM passed its complete raw-engine suite;
that result must not replace this fast VM's original failure. The raw
`engine.log` and `engine.stderr.log` preserve the exact backend observations.

## Dock and product coverage

The opening confirmation remained ordinary: actual Dock read
441.877352–441.879800 seconds (2.45 ms), total request 19.66 ms. The only
ineligible ownership transition was `stopped=true` during cleanup. No product
handler, group-choice worker or Finder desktop-focus read ran. No NP_LAUNCH
occurred in the product path. The background physical-readback change was
compiled but not exercised after a dispatched R4 action. Remaining product
group/lifecycle/system checks stayed NOT_RUN.

All receipts are byte-for-byte originals. `provenance.json` lists original
artifact paths, byte counts and SHA-256 hashes.
