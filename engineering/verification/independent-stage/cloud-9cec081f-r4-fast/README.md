# 9cec081f fast: engine passed; no R4 action issued after incomplete AX reads

Run [45728613871](https://github.com/haohongfei2001-png/nearpane/actions/runs/45728613871),
source `9cec081fe8d125c3106adead51b6662dee811a6d`.

The full job's early source receipt records **161 Rust passed**, **169 Swift
passed and 1 skipped**. The fast job compiled and packaged the existing
foundation debug Host, using the same R4 and Spaces production sources. This
remains separate from a complete companion-workspace release qualification.

This fast VM's controller returned **FOREIGN_ENGINE_PASS** with cleanup true:
initial yellow minimize, three switch cycles, same-app independent windows,
cross-app group, focus restoration and later yellow minimize all passed their
actual physical readbacks. This is a second raw-engine VM receipt alongside the
separately archived diagnostics job; it does not imply a working R4 input path.

## Actual R4 result

Product status **BLOCKED**, `actualR4Inputs=0`, cleanup **true**. The external
controller discovered a unique, enabled AXButton with the requested identifier,
exact parent panel and matching geometry. Its final pre-press reads of the
button's role and identifier then returned **AXCannotComplete (-25204)**.
The raw press receipt has `issued=false`, `reason=prePressEvidenceChanged`.
`AXUIElementPerformAction` was not called; the receipt's initial `axError=-25200`
is not the return value of an attempted press.

This does **not** prove the AX object was replaced or invalidated: -25204 is
CannotComplete, not InvalidUIElement. Nor does it establish missing focus or a
missing button. The next helper uses one batch for the same six attributes and
can rediscover only before any action, within its existing six-second budget.
Its parent, signature, panel, identifier, enabled and geometry constraints remain
mandatory; no attempted AXPress can be retried.

## Dock trace

The opening confirmation was ordinary, with an actual Dock read from
1082.969870 to 1082.971501 seconds (1.63 ms), and 2.47 ms total request time.
There was no dispatch-epoch withdrawal before the failed pre-press read.
The only transition to ineligible was `stopped=true` at cleanup, while the Dock
still read ordinary. This run therefore does not reproduce the preceding
b43d5a93 ownership-revocation failure and cannot identify its cause.

No R4 handler, group-choice worker or Finder desktop-focus reader ran on this
VM. Group/lifecycle/system product checks remained NOT_RUN. All receipts here
are byte-for-byte originals with artifact paths and SHA-256 provenance.
