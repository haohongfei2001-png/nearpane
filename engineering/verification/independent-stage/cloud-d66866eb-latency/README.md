# d66866eb: source passes; formal R4 remains incomplete

Exact source: `d66866eb2ac1ab939a03a0911aa9dd96c787a930`, on the existing
PR #16 branch. [Run 46013866681](https://github.com/haohongfei2001-png/nearpane/actions/runs/46013866681)
has completed all lanes. **Source checks pass. The full release Host receives one
real R4 press but fails the physical switch readback; its cleanup is confirmed.
The fast Host is blocked before input by an unsuitable ordinary-desktop state
and also has a sampled main-thread icon-rasterization stall.** These original
results do not qualify any subsequent changes.

## Outcomes and scope

| Layer | Actual result |
| --- | --- |
| Source checks | PASS: 166 Rust; 208 Swift passed and 1 skipped (209 cases reported by Swift Testing); worker/protocol, evidence classifiers, read-only context and native diagnostic checks pass |
| Full release build and signature | PASS |
| Full direct engine | FAIL, `yellowButtonFailed`, 25 hide/restore request attempts; cleanup confirmed |
| Full formal R4 | FAIL, `R4SwitchReadbackFailed`, 1 actual external R4 input; cleanup confirmed |
| Fast ordinary-desktop preparation | BLOCKED, `systemObservationTimedOut`; no created desktop, current desktop 1 has no system UUID |
| Fast direct engine | BLOCKED, `ordinaryCurrentDesktopCountNotOne`, zero hide/restore attempts; cleanup confirmed |
| Fast formal R4 | BLOCKED, `fixtureGroupsNotReady`, zero actual R4 inputs; cleanup confirmed |
| Fast platform-only fallback | `PLATFORM_FOREIGN_PASS`, four writes; engine state machine and R4 explicitly `NOT_RUN` |
| Separate diagnostic engine | BLOCKED, `candidateCanaryNotConfirmed`, zero hide/restore attempts; cleanup confirmed |
| Separate diagnostic platform-only fallback | `PLATFORM_FOREIGN_PASS`, four writes; engine state machine and R4 explicitly `NOT_RUN` |

The diagnostic job's green workflow conclusion comes from the platform-only
fallback. It is not a candidate-engine or product PASS. Likewise, successful
source tests do not establish native-window behavior. Product merge/split,
yellow-button routing, cold hidden previews, system handback, crash/restart and
lifecycle cases remain `NOT_RUN`.

## Fast startup: two distinct observations

[The preparation receipt](fast/ci-workspace-prepare-receipt.json) records
`systemObservationTimedOut` while adding a desktop. Its process exited zero,
but the receipt itself is `BLOCKED`, with no created ordinary desktop and no
UUID on current desktop 1. The before-fixture cleanup receipt confirms cleanup.
The engine then correctly refuses that environment. This lane cannot measure
R4 click-to-hide latency because no R4 button press occurs.

Independently, [the startup sample](fast/host-startup-main-thread.sample.txt)
captures 30 main-thread samples through `DesktopWindowCard.preview`, line 76,
and synchronous `NSImage`/IconServices rasterization of the placeholder app icon.
Twenty-eight samples wait in the synchronous XPC request's `mach_msg2_trap`.
This is direct evidence for a rendering stall at startup, not attribution to
SCStream construction. The failure snapshot has four counted capture starts,
four active streams and one delivered frame. The later first-R4 sampler is
`NOT_RUN` because no request was observed.

Both the ordinary-desktop admission failure and the sampled rendering stall
must remain visible in the interpretation; fixing icon decoding alone does not
prove that this fast runner has a valid ordinary desktop.

## Full release: real input, slow witness, no verified hide

The external AX press receipt reports one real R4 action. The button press is
at uptime 1251.898987458 and the group job begins at 1251.933685458. Worker
configuration completes at 1254.065755958. The first witness completes at
1257.668989917, approximately 5.770 seconds after the press.

The newly instrumented witness phases are preserved in
[product.stderr.log](full/product.stderr.log) and the mechanically derived
[latency summary](latency-summary.json):

| Witness | Total ms | Opening directory ms | Binding ms | Physical windows ms | Closing directory ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 3551.227 | 1136.096 | 1755.039 | 290.653 | 369.440 |
| 2 | 474.502 | 252.994 | 2.446 | 71.910 | 147.151 |
| 3 | 531.009 | 321.374 | 4.358 | 76.630 | 128.647 |
| 4 | 327.233 | 110.715 | 1.651 | 65.489 | 149.377 |
| 5 | 385.214 | 117.684 | 1.728 | 46.541 | 219.262 |

The first witness spends 1.755 seconds in binding and 1.136 seconds in opening
directory work. Later bindings take only 1.651–4.358 ms, while directory reads
continue to dominate repeated witnesses. These timings identify expensive
phases; they do not by themselves identify every blocking call inside a phase.

The final independent physical readback still shows both sibling windows 56
and 57 on screen on home desktop 12. Target window 54 is on screen, frontmost
and the reported AX focused window. However, the independent focus/readback
receipt has `verified=false`; the fifth worker witness later reports
`focusLocal=true`. Neither observation makes the complete switch PASS.
The `interrupted` result appears at the end of the acceptance window, so it
must not be treated as an independently established cause of the earlier delay.

The formal product's final status is FAIL, with `cleanup=true`. Fixture exits
and CI-owned desktop cleanup are also confirmed in their separate receipts.
This differs from a3ab1e67's full product, whose cleanup was unconfirmed; the
different original results must not be merged or overwritten.

The short full first-request sample is also retained. It has 16 main-thread
samples, including 10 servicing accessibility source callbacks, and does not
establish that the entire 3.551-second witness ran on the main thread.

## Attestation is measured separately

Six installed-environment attestation reads take **13.152–21.736 ms**, median
**18.867 ms**, total **109.158 ms**. Self-signing has median 1.687 ms and the
screen-capture permission read median 4.004 ms. These receipts do not support
attributing this run's seconds-long witness delay to attestation.

## Provenance and retained originals

All copied JSON, JSONL, logs and samples are byte-for-byte artifact entries.
[provenance.json](provenance.json) records their original paths, sizes and
SHA-256 values. `latency-summary.json` is explicitly derived, not a native
receipt. Large archives, binaries and the candidate ZIP are omitted.

| Artifact | ID | ZIP bytes | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| Source context | 15205721929 | 23162 | `a10efb4a34e882b7b3aac86ca1129d8d385cb182482debbfa53108c507ab549b` |
| Fast | 15204582902 | 24419468 | `fcd2a622b160d6191c9f4a5184824852511a47676be739bcdfd799a52e9f1fdb` |
| Diagnostics | 15205790913 | 1454947 | `d9c1dde2973dd07c99595027b87f3c17b6583e2d04d921878d044226c6bb4df8` |
| Full release | 15205179072 | 52923667 | `534a2fa2691291d3f4e29a39ed934f515aa726c82f0da5218525593ca00d3540` |

The original full candidate ZIP is 25,506,802 bytes, SHA-256
`68d89090c466124952ae5ee1d86578be17d2201efabd9795ae36fac2250adfc8`.
The candidate metadata is retained. The full startup sample is omitted from
this compact set; the fast startup sample and full first-request sample are
retained in full. Complete original archives remain in the workflow artifacts.

## Remaining acceptance

These runs use cloud Apple Silicon macOS 27.0.1 / 26A434 with SIP disabled.
They are separate from earlier physical-target evidence on macOS 27.0 /
26A428 with SIP enabled. No new physical-target run is claimed.

The next same-PR candidate must be tested with valid ordinary-desktop admission
and produce actual thumbnail input followed by independently verified sibling
hiding, target restoration and focus. Preserve the 750 ms freshness limit,
exact ownership checks, and physical cleanup receipts. Only after that chain
passes should broader interaction, stability and release acceptance proceed.
