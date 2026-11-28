# R4 7aea52c5: later background publication interrupts two different stages

**Exact-source tests and the complete candidate build pass. Each unsampled R4
lane receives one actual input and confirms no complete switch. Fast confirms
the selected focus and receives two successful HIDE receipts; full stops during
initial binding, before any managed window write. Neither lane exercises the new
initial-directory staging branch. Continuous R4 operation remains FAIL.**

Source: `7aea52c55736ae7b0138b884eaa81b9d76db8ae1`, original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46118680741](https://github.com/haohongfei2001-png/nearpane/actions/runs/46118680741)
is terminal. This head stages the eligible first prebinding incomplete result
before shared publication and adds failure-only role diagnostics. It changes no
window-operation budget or query authorization. Later incomplete reads retain
their existing failure behavior.

## Native source and package gates

| Gate | Result |
| --- | --- |
| Rust / native AX decoder | 180 / 25 passed; decoder reports zero window writes |
| Swift XML | 264 entries: 263 passed, one existing gated skip, zero failed |
| New initial-publication staging tests | Five functions / ten executed cases passed |
| Existing retry / after-action / reader / codec cases | 43 / 16 / 10 / 8 passed |
| Complete candidate / strict bundle signature | PASS; qualification remains false |

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log) and [decoder stdout](source/binding-attributes.log)
retain exact-source results. Full source logs and the early context logs are
byte-identical. The sole skip is the existing environment-gated minimize fixture.
Both direct-engine checks pass separately from production R4. Target GUI
acceptance remains NOT_RUN; these cloud gates do not grant release qualification.

Both initial directories are complete. There are **zero**
`initial-directory-staged`, `desktop-read-publication-staged` and
`witness-initial-directory-retry` events in either lane. Source tests cover the
new branch, but this run supplies no live-runtime branch acceptance.

## Fast: focus succeeds; a background read overlaps the second HIDE

Fast reaches three bindings and nine complete witnesses. The exact selected
focus, FixtureA **PID 38176 / window 53**, passes both complete confirmations,
sequences **4 and 5**. HIDE of FixtureA window 55 returns PASS in **51.908 ms**,
with one owned hide. HIDE of FixtureB **PID 38215 / window 56** then returns PASS
in **103.008 ms**, with two owned hides. No product SHOW is issued.

| Event | Uptime |
| --- | --- |
| Focus confirmations, sequences 4 / 5 | 1415.165414 / 1415.313003 |
| First HIDE PASS | 1415.451839 |
| Second HIDE request begins | 1415.822721 |
| Background revision 32 native sample | 1415.831266–1415.910592 |
| Revision 32 task exit | 1415.914696 |
| Second HIDE PASS | 1415.925844 |
| Activation reports `interrupted` | 1415.930897 |

Revision 32's only issue is `membershipChanged:pid=38215,window=56`.
This is the original authorized document being hidden, with the same birth and
frame, and a positively read ordinary role. Membership changes from known home
`12` to unknown; the active flag changes from true to false. The evidence does
not identify the unknown membership as a particular hidden Space.

The worker's final two complete native views take **22.079 ms** and **7.685 ms**
and the HIDE receipt is PASS. These native views are distinct from the missing
Host/coordinator post-write witnesses: after the second HIDE, no READBACK
request or complete post-witness follows. There is no worker fault or
`witness-read-rejected` event. Activation fails **5.053 ms** after the HIDE
receipt. Consequently, two successful primitives and verified focus do not
establish a completed R4 switch or an external double-read confirmation.

The request trace does not serialize `command.window`; window attribution uses
the original fixture identities and native binding/view records within each
request interval. The later revision 34 appearance of window 86 occurs after
failure and release and cannot explain revision 32. [Fast analysis](fast-analysis.json)
preserves the correlation and its limits.

## Full: a later background read revokes the initial binding

Full's opening directory, revision 5, is complete and takes **82.051 ms**
natively. Its roster completes four awaited role queries and advances to initial
binding. Background revision 6 then records `windowRosterChanged` and two
`windowIdentityOrBounds` issues: **PID 32504 / window 85** and
**PID 32349 / window 83**. Each is absent from the first CG roster and present
in the second with a 66 x 20 frame. Neither role was requested, and both
membership observations are unavailable. They belong to the fixture processes
but are not authorized documents; their actual roles and harmlessness are unknown.

Revision 6's native interval is **1066.399124–1066.832925**, or **433.801 ms**;
its task exits at **1066.842423**. At **1066.905041**, the post-await guard for
authorized FixtureB **PID 32504 / window 55** rejects: ordinary Host revision
changed from **0 to 1**, and the restore permit reports
`management/native-catalog`. Sequence, installed bindings and visibility claims
are all zero; no complete witness or managed window write is reached.

This combined post-bind guard throws `ownership` because `unchanged()` fails.
Its later identity-equality terms are short-circuited, so the error does not
prove window 55 changed identity. No `stageHostRoleReadRejected` event occurs.
This is also outside the new one-read staging scope: the first opening sample
was complete and revision 6 is a later background sample. [Full analysis](full-analysis.json)
includes the exact branch, original events and failure-time partition.

## Shared publication path and measured cost

The two lanes stop at different stages after an incomplete background directory.
Source inspection connects ordinary publication to `observeEnvironment`, which
freezes the current session. Full directly records the resulting Host revision
and permission rejection. Fast records a successful epoch-1 HIDE, interruption
before its next readback, and an epoch-2 RELEASE; the transport's post-await epoch
check explains that order. The precise freeze call, timestamp and fast post-await
epoch value are not logged, so this causal connection remains an inference from
source and event order, not a captured freeze stack.

Fast's actual click to activation failure is **2544.075 ms**. Its nine complete
witnesses total **1077.590 ms**, including **70.291 ms** of measured
`unchangedPermit` checks; initial role queries take **35.173 ms**. Full's actual
click to first witness rejection is **908.664 ms**, and to navigation failure
**909.474 ms**. Its failed witness lasts **754.859 ms**, including **306.513 ms**
of role queries and **93.606 ms** of measured permit checks.

These are failure timings and nested elapsed measurements, not successful
switch latencies or CPU samples. Native timings sit within directory/worker
calls; background reads overlap the foreground work and must not be added.
Neither lane has an external physical double-read confirmation or a completed
coordinator switch. No population latency claim follows from these samples.

Fast's 19 recorded producer-exit-to-caller intervals have a maximum of
**1.302 ms**; its pre-failure worker poll queue maximum is **0.0536 ms**.
The cold worker launch takes **677.876 ms**, and no Dock sample expires before
the failure. This run does not reproduce a seconds-long caller or worker queue
gap. The successful native HIDE receipt followed by interruption makes the
ordering of observation and foreground work the immediate issue to resolve.

## Recovery and frozen evidence

| Recovery observation | Fast | Full |
| --- | --- | --- |
| Original worker RELEASE | 385.995 ms, PASS, owned 0 | 18.313 ms, PASS, already empty |
| Later Host shutdown | 2.2385 ms, released | 1.860 ms, released |
| Independent two-read home / frame / visibility check | PASS | PASS |

Fast releases its two actual hides; full cleans up without any managed hide.
Both workers report closed, destroyed and drained. Fixture quits are separately
recorded and do not complete a failed switch. Later group editing, window
lifecycle and crash acceptance remain NOT_RUN after the core R4 failure.

[Provenance](provenance.json), [artifact metadata](artifact-api-metadata.json),
[workflow jobs](workflow-jobs.json), [comparison](comparison.json) and
[click timelines](click-timelines.json) retain exact source and event attribution.
All three downloaded ZIP hashes match provider digests. The original
[51-file trace archive](runtime-traces-7aea.tar.gz) is **172,717 bytes**, SHA-256
`84b470d149e8d2b8f37b42e30049ceff79a9c8345104d2eab65d77ccf072011c`;
its [manifest](runtime-traces-manifest.json) hashes every member.
The [source archive](cloud-source.zip) retains the early source gate logs.
