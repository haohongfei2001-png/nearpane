# cb95d6aa: directory delay in fast; launch-canary focus failure in full

Exact source: `cb95d6aa16ead25f2ac919d84896cf3d29cb9177`, same PR #16 branch.
[Run 46021722114](https://github.com/haohongfei2001-png/nearpane/actions/runs/46021722114).
**Source checks pass. The fast direct engine passes, but formal R4 receives
one actual press and fails its first selection without a confirmed hide or
focus switch. The full release completes one witness but fails its product
launch-canary focus qualification before a confirmed switch. Both formal R4
results are FAIL, with physical cleanup confirmed.** The separate diagnostic job's green conclusion
is a platform-only fallback; its candidate engine is BLOCKED.

## Actual outcomes

| Layer | Actual result |
| --- | --- |
| Rust source tests | PASS, 174 |
| Swift source tests | PASS, 217 passed + 1 skipped; 218 cases reported, 3.971 seconds |
| Other source checks | Worker build/protocol, evidence classifier, read-only context and native diagnostic checks PASS |
| Fast Host build | PASS |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 requests, cleanup confirmed |
| Fast formal R4 | FAIL, `R4SwitchReadbackFailed`; one actual input, zero confirmed selections |
| Fast physical product cleanup | Confirmed by two independent complete window-state reads |
| Separate diagnostic engine | BLOCKED, `candidateCanaryNotConfirmed`, zero writes, cleanup confirmed |
| Separate platform-only fallback | `PLATFORM_FOREIGN_PASS`, four writes, cleanup confirmed; engine state machine and R4 `NOT_RUN` |
| Full release build/signature | PASS |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 requests, cleanup confirmed |
| Full formal R4 | FAIL, `R4SwitchReadbackFailed`; one actual input, zero confirmed selections, cleanup confirmed |

## New after-action diagnostics localize the fast delay

The external helper records a successful AXPress at uptime 635.67970225.
The first group job starts at 635.7005477916667. Group preparation completes
successfully in **2760.315 ms**, on the existing-binding path, with unchanged
epoch and appearance, no cancellation, and no rejection. Its only await is
the first directory read, **2744.298 ms**.

The two recorded after-action directory reads separate waiting for an earlier
inventory from requesting a fresh one:

| Context | Total ms | Prior wait ms | Fresh read ms | Had prior |
| --- | ---: | ---: | ---: | --- |
| First selection preparation | 2744.106 | 472.904 | 2271.195 | true |
| Initial witness opening directory | 1351.210 | 0 | 1351.207 | false |

For the first read, prior wait is 17.23% and fresh read is 82.77% of the measured
duration. This is two observations, not a stable latency distribution. It
shows that simply avoiding the prior-inventory wait would leave the larger
fresh-read delay in this lane. The observations and arithmetic are retained
in [the derived timing analysis](fast/timing-analysis.json), backed by the
SHA-256 of [the original product log](fast/product.stderr.log).

After session configuration, the first expired Dock observation is processed
at uptime 638.898962: its physical read takes approximately 2.006 ms, but the
receipt is approximately 936.516 ms old. Dispatch eligibility is withdrawn.
At uptime 640.284227 the initial witness rejects window 57 at
`initial-window-binding`, with bindings 0, claims 0 and sequence 0. There is no
completed witness to summarize as a successful read or click-to-hide latency.
The ordering is observed; the sample does not assign all fresh-read time to
one native function.

The final physical readback still shows all three fixture windows 54/56/57
visible on home desktop 12. AX focused window is 54, but frontmost PID is 359
rather than target PID 16039, so exact focus is not verified. No formal
selection, product HIDE→SHOW cycle or held-window selection is confirmed.
This lane therefore cannot establish whether the new idle-refresh gate
eliminates the held-selection overlap seen in the earlier full release run.

## Shared sampling now follows actual evidence

The press and selection-preparation logical reports both reference
`host-main-thread.sample.txt`; the selection report explicitly has
`sharedWith=host-main-thread`. Only that single 3-second physical sample is
retained for those triggers. Its complete original text is preserved.

The successful helper receipt records `inputUptime=635.67970225` and
`uptime=635.7009235833334`. The Python receipt observer records monotonic
635.886279041; the physical sampler launch is monotonic 635.886905875.
The logical selection trigger retains its own observed time and the native
group-job uptime. **Native uptime fields and Python monotonic fields remain
separate clock metadata; no cross-domain subtraction is required.**

`reapedMonotonic=644.1154065` records process collection after Host exit, not
the sampling end. Shared metadata does not claim that the sample captures the
instant of AXPress or the entire preparation interval. The separate startup
sampler receipt is retained; its larger raw text remains in the original
workflow archive with its hash recorded in provenance.

The new post-input sample contains `sessionAvailable`/SLS synchronous IPC
stacks at multiple call sites. It does not show one dominant IconServices or
SCStream chain, and it cannot justify attributing all 2.271 seconds of fresh
directory waiting to those session checks.

## Full release: one completed witness, then launch-canary focus rejection

The full external press is at uptime 1088.0644775833334; group preparation
starts at 1088.0853807916667 and succeeds in **244.435 ms**. Its first directory
read is **243.491 ms**, comprising **41.578 ms prior wait** and **201.910 ms
fresh read**. The latter is approximately 11.25 times shorter than the fast
lane's 2271.195 ms observation; these two runs do not establish the cause of
that variance or a general performance guarantee.

The initial witness also obtains fresh opening and closing directory reads:
113.031 ms and 79.611 ms, each with no prior wait. It completes with three
managed windows and the following exact phase timings:

| Total ms | Opening directory ms | Binding ms | Physical windows ms | Closing directory ms |
| ---: | ---: | ---: | ---: | ---: |
| 453.410 | 114.038 | 156.536 | 101.385 | 81.451 |

There is only one completed witness. The Host's preceding non-window-focus
reads positively confirm the original Finder desktop, represented by nil
window focus; this is not an unknown focus observation.
The next recorded activation fails at uptime 1089.2831429583334 with
`unavailable`; no second witness or formal R4 selection is confirmed. See
[the full product log](full/product.stderr.log),
[derived phase analysis](full/timing-analysis.json), and
[original result](full/product-result.json).

The product worker supplies the distinct failure point. Prepare/Open have
already succeeded, and five earlier Finder-desktop structure reads have
`confirmedDesktop=true`. The next `PanelOp.Read` takes 185.238 ms in the panel
call (main-queue wait 0.089 ms). Its **AXRole read alone becomes unavailable,
returning `-25204` / AXCannotComplete**; parent/application identity, containing
window/self identity, and the complete one-element AXWindows list remain
positive. The derived `desktopScrollArea` and `confirmedDesktop` flags become
false, so `panel_home` refuses `focus_same=0` and reports status 2/detail 229
(`ProbeFocus`) for controller-owned panel 81, before home/lease/parking are
assigned.

`canonicalError=-25201` and canonical number 0 are also present in all five
successful Finder-desktop reads. They are **not the changed predicate or the
cause of this refusal**. The adjacent `focused-desktop-structure` summary
repeats that canonical error, so reading that one line alone would misattribute
the failure. This is missing certainty from one AXRole transport read, not a
confirmed focus change. The Host and worker use matching Finder-desktop
semantics; the Host's first twelve structure reads in this interval are positive.

The canary then closes and records `finish-canary`, status 0/detail 200; the
worker closes with zero owned Spaces and its engine destroyed. Worker events
have no event uptime, so their exact timestamp is not inferred from Host logs.

This full failure is not the fast lane's stale-Dock path or the earlier
health-217 failure. Owned membership and a route have not been established, so
the modified `observe_health` body is not reached. Preparation and the first witness progress; launch-canary
focus qualification prevents the product activation. The direct-engine PASS
belongs to its separate earlier acceptance run and cannot replace this failed
product qualification.

The final switch readback still shows all original windows 55/57/58 visible on
home 12. AX focus is 55, but frontmost PID 380 differs from target PID 38110.
Full shutdown releases in 1.704 ms and confirms original-home visibility and
frames in two independent reads, so cleanup is confirmed. No held selection
is reached in either product lane, and the new idle-refresh gate remains
unverified by these native product results.

Full sampler reports also share the single canonical
`host-main-thread.sample.txt` between press and selection. Their original
sample texts remain in the workflow artifact, with hashes and explicit
omission entries in provenance; no duplicate sample file is invented.

## Cleanup and remaining qualification

Shutdown returns `released=true` in 2.048 ms. Two independent physical reads
then confirm all original windows visible on home 12 with preserved frames;
`shutdownReturnReadback.confirmed=true` and product `cleanup=true`. Fixture and
CI-owned desktop cleanup are separately confirmed. Because product hiding
was not first confirmed, this does not demonstrate a completed HIDE→SHOW cycle.

Merge/split, yellow routing, hidden previews, system handback and broader
stability remain unqualified. The 750 ms ownership freshness limit and the
original identity requirements remain unchanged. These are cloud Apple
Silicon macOS 27.0.1 / 26A434, SIP-disabled results; no new physical-target run
is claimed.

## Provenance

[provenance.json](provenance.json) records original artifact entries, sizes and
SHA-256 values. Copied results, logs, sample text and cleanup receipts are
byte-for-byte originals. The timing analysis is explicitly derived. Binaries
and archives are omitted.

| Artifact | ID | ZIP bytes | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| Source context | 15210300997 | 23575 | `ad1afade32cd778bf3c5cf4491b12a5f53d258545f3c5f075c3b0dc9aaf03cdd` |
| Fast | 15207764799 | 24653820 | `79a495cdc78d8c3ee81bd2bb4a772b69c822eae732077f7de13b593b32fde00e` |
| Diagnostics | 15208965970 | 1458911 | `4237a21cf17d61ae4162dc3b54ed31e4ebc61803411cd09833b787fee1c0d190` |
| Full release | 15212145606 | 53284149 | `8aa0f8c56d1b8c6109a36dc9fda0faf40caaaad052c211cc8c0f7f0a4a307cb7` |

The original full candidate ZIP is 25,678,225 bytes, SHA-256
`34a954ebccd725201ae1f037fd5eb84972bbf8494b1c4ed7fd7d66d96e651063`.
