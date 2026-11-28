# First exported R4 button input, full candidate at 3bcb0640

This directory preserves unmodified receipts from the **full** lane of
[run 45710634990](https://github.com/haohongfei2001-png/nearpane/actions/runs/45710634990),
job `139543822996`, artifact `15069160488`. `provenance.json` records the original
artifact paths and SHA-256 of every copied file. The separate diagnostics VM is
not evidence for this product run.

## Source and candidate

- Source checks passed: **151 Rust tests, 156 Swift tests and one skipped Swift
  case**, native worker compilation and protocol check, evidence classification
  tests and native diagnostic tests.
- Complete product build and strict bundle signature checks passed. The candidate
  ZIP has 24,989,428 bytes and SHA-256
  `413b25f592c1d7c3840fedc1a119e5c95a9c796670d66f5e379accd6f28b6140`.
- This is the hosted Apple Silicon macOS 27.0 / build 26A434 / SIP-disabled
  environment recorded in `engine-result.json`, not the user's SIP-enabled
  build 26A428.

## Actual R4 result

The real catalog was complete and fresh, all three fixture windows had distinct
groups on ordinary Space 12, native Stage Manager was off, and the actual R4
panel was visible. The in-process accessibility tree exposed only `EdgePanel`
and a hosting view with zero children. The external accessibility server exposed
the three actual card buttons.

The existing Controller found exactly one enabled `AXButton` for the enrolled
window `39402:54`, verified its parent panel's CG identity and geometry, and
performed **one actual AXPress**, returning AX error 0. The full pre-input proof
and result are in `r4-press-result.json`. This was an accessibility button action,
not a physical pointer gesture or a direct call to the scheduling handler.

The subsequent two-read window-state check did **not** confirm the requested
group: product status is **FAIL / R4SwitchReadbackFailed**, `actualR4Inputs=1`,
`foreignWindowReadback=false`, `cleanup=true`. No successful R4 group switch is
claimed. The retained profile contains only `Nearpane/stage-groups-v2.json`; no
visibility journal or Spaces worker log was emitted in this product attempt.
That narrows the next investigation to the actual card-to-dispatch path but does
not by itself establish its failing condition.

The two PNGs show the actual isolated product panel. The baseline contains three
capture placeholders; immediately before input, A0 displays a real red fixture
window image while A1 and B0 still show placeholders.

## Separate normal-engine result

The same VM's normal engine passed its own launch canary, foreign round trip,
same-app independent windows, cross-app grouping and all three repeated
A–B–C–A cycles. The real yellow-minimize case failed and remains **FAIL** in the
original receipt. Its `windowWrites=23` counts hide/restore **requests/attempts**,
including unverified requests, not 23 proven migrations.

The original engine's bounded release path subsequently confirmed cleanup: all
three foreign windows were independently read twice at their original home and
geometry, and the original complete Space inventory was restored. That result
permitted the separate product attempt; it did not convert the yellow case to a
pass. Fixture shutdown and CI workspace cleanup also retained their own receipts.
No production qualification is granted by this evidence.
