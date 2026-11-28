# R4 caa2e0aa: one complete switch; the next focus confirmation rejects a changing roster

**Exact-source tests and the complete release build pass. The unsampled release
lane confirms one real R4 switch in 1890.56 ms, then stops during the first full
confirmation after a focus write. Both native HIDE operations and the subsequent
SHOW return PASS. Continuous R4 operation remains incomplete.**

Source: `caa2e0aa4998baa9515dec85ae3c2bdc119639fd`, on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46112069026](https://github.com/haohongfei2001-png/nearpane/actions/runs/46112069026)
is terminal. Both product lanes explicitly disable external Host stack sampling.
No qualification is granted, and the existing hidden-Space backend, main branch
and product constitution are unchanged.

## Source, package and target status

| Gate | Exact result |
| --- | --- |
| Rust | 180 passed, zero failed; original stdout verified |
| Swift XML | 256 entries: 255 passed, one existing gated skip, zero failed |
| New initial-roster suite | Seven functions / 43 executed parameter cases passed |
| Persistent reader suite | Nine functions / ten executed cases passed |
| Native AX batch decoder | 25 checks passed, zero failures, zero window writes |
| Complete release build and strict signature | PASS; candidate qualification remains false |
| Exact-source target Mac execution | NOT_RUN; target connector reports Offline |

The sole Swift skip is the existing environment-gated native minimize fixture.
The new first-witness retry compiles and passes its boundary tests, but neither
runtime lane exercises it: fast stops before a witness exists, while full's
opening witness is complete and its later failure already has retained bindings
and a visibility claim. A tested branch is not described as runtime-proven here.

The early context Swift logs and final full-artifact Swift logs are byte-identical.
[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [native decoder stdout](source/binding-attributes.log)
and [candidate receipt](candidate.json) retain these distinctions.

## Unsampled full: HIDE and SHOW pass; focus confirmation does not

The actual external R4 input produces **one complete confirmation out of two
inputs**. The first completed click takes **1890.56 ms** to obtain two matching
physical visibility, geometry and focus readbacks. The corresponding earlier
5e3a release click took 1906.94 ms; these individual observations on different
runners do not establish a population latency improvement or a p95.

Across the product sequence, the original worker returns PASS for two HIDE
requests and one SHOW. Its passive health requests also return PASS. The SHOW
request takes **210.77 ms** in total; its two move-following complete views take
**69.288 ms** and **35.298 ms**. The request also includes preparation, so its
total must not be compared directly with the 120 ms acknowledgement interval.
No product worker request ends with the earlier 214/217 failure. An expected
canary close-readback 217 diagnostic remains present and is not a product failure.

The second input begins at **1007.164377**. The completed SHOW is independently
observed by witness sequence 19 and then by the coordinator's second confirmation,
sequence 20. The next operation is focus on document **55**:

| Stage | Recorded evidence |
| --- | --- |
| Health before focus | 1010.057331–1010.075414; PASS, 17.964 ms |
| Focus preflight | Sequence 21, 1010.078128–1010.846926; complete, previous focus still document 53 |
| Ordinary focus | Returns before the next full witness begins; this interval is not a new Space move |
| First post-focus witness | 1011.137247–1011.822579; rejected at `closing-roster`, 685.332 ms |
| Navigation failure | 1011.838541; 4674.164 ms after the second input |

The closing directory, revision **65**, is fresh but incomplete. It reports one
issue: `membershipChanged:pid=35942,window=82`. Its native sample runs from
**1011.620202 to 1011.797050**. At rejection the witness retains **three bindings
and one visibility claim**; no initial-directory retry is allowed or attempted.

PID 35942 is FixtureA. Its registered documents are 53 and 55; FixtureB owns 56.
Window 82 is absent from the authorized document set, group directory and final
fixture window list. FixtureA reports no scripted document creation. These facts
do not establish window 82's role, its old/new memberships, or whether it is a
transient surface. The artifact does not retain those rejected-row fields, so
window 82 is not classified as harmless or ignored.

The precise stopping point matters: this is **the first full post-focus
confirmation**, not a rejected SHOW, a following HIDE, or a failed initial
binding. The incomplete closing directory prevents the collected physical
states/focus observations from reaching the coordinator's final validation.
A generic retry could hide a positive intermediate conflict; no such retry is
introduced by this checkpoint. [Full analysis](full-analysis.json) records the
source locations, event lines and complete request sequence.

## Remaining delay in the release click

The unsuccessful second click lasts **4674.164 ms**. This is time to rejection,
not a successful switch latency. Its non-overlapping interval partition is:

| Partition | Duration |
| --- | ---: |
| Seven complete witnesses plus the rejected witness | 3727.786 ms |
| Worker health envelopes | 97.646 ms |
| Worker readback envelopes | 119.277 ms |
| Worker SHOW envelope | 210.873 ms |
| Focus/WAL envelope | 290.321 ms |
| Other input and Host intervals | 228.262 ms |

These request envelopes use their recorded entry/exit timestamps; the internal
SHOW request timer above is slightly shorter. They must not be added to nested
native or witness phase durations. [Click timelines](click-timelines.json) and
[comparison](comparison.json) retain the partition inputs.

Within this failing interval, 24 completed directory tasks record **2269.036 ms**
of native sampling and **24.283 ms** from native sample end to Host return in
aggregate, with a largest individual return gap of **11.601 ms**. This full run
does not reproduce the earlier 0.79/3.3-second callback gaps. The nested directory
totals include background work and are not another additive part of the table.

Focus preflight sequence 21 costs 768.798 ms: opening directory 287.094 ms,
binding phase 148.766 ms, original-window physical observations 169.421 ms and
closing directory 163.517 ms. The binding phase can include a role read for an
unbound candidate even when the final roster contains only retained windows;
it is not automatically permission-check CPU time. Follow-up aggregate timing
must identify that cost before changing the checks.

All 73 full-run directory requests use the same verified reader process, PID
36884. The trace has no reap event before it ends, so this run demonstrates reuse
without claiming to demonstrate that process's eventual reclamation.

## Unsampled fast: the selected live binding is rejected before a worker exists

Fast receives **one real AXPress and confirms zero switches**. Its first failure
is `group-choice-binding-rejected`, with `hasLiveWindow=false`:

| Interval | Duration |
| --- | ---: |
| Actual press → navigation dequeue | 12.857 ms |
| Directory revision 4 task queue | 8.678 ms |
| Native directory sample | 986.783 ms |
| Native sample end → reader return | 9.244 ms |
| Directory task exit → afterAction caller | 3.296 ms |
| Selection preparation | 1106.096 ms; completed |
| Actual press → first binding rejection | 1156.377 ms |

Preparation reports matching appearance and an existing group lifetime, but the
following live-window resolver returns nil. The old trace does not distinguish
source resolution, original-window token, ordinary role, target construction,
membership or lifetime subconditions, and it does not preserve revision 4's full
snapshot. The 986.783 ms sample itself is inside the existing three-second sample
and twelve-second age bounds. Its duration is not evidence of a freshness denial.

No worker, managed binding, HIDE/SHOW, or initial-witness retry is reached. The
first Dock expiry is later, at **600.232053**, so it is not the first failure.
After rejection the run still records a Dock task queue delay of 857.76 ms and
a native-end-to-callback delay of 1162.71 ms. Removing sampling does not prove
that scheduling delays cannot occur; those later delays do not explain the
earlier live-binding rejection.

Both runtime and product receipts say `disabledByRequest`; the four sampling
status files say `NOT_RUN / diagnosticsDisabled`. This verifies the actual
sampling policy rather than assuming it from the workflow source.
[Fast analysis](fast-analysis.json) retains original paths, hashes and lines.

## Recovery and original evidence

After the full failure, original-owner RELEASE operation 13 runs from
**1011.878706 to 1012.142504**, returns PASS with zero owned windows, and takes
**263.686 ms**. The later final shutdown takes only **2.656 ms**; it is not the
complete recovery cost. Independent two-read home/geometry/visibility confirmation
is recorded at **1015.744198**. Host release and external restoration both pass.

Fast also records Host released=true and two independent home confirmations,
but has not issued a managed-window write. Its cleanup is not a product
hide/restore round trip. Later group editing, window lifecycle and crash gates
are not run after the failed core R4 sequence.

[Provenance](provenance.json), [artifact metadata](artifact-api-metadata.json)
and [workflow jobs](workflow-jobs.json) identify the exact source and provider
artifacts. All three downloaded ZIP digests match their provider digests.
The [49-file original trace archive](runtime-traces-caa2.tar.gz) is **186,412 bytes**,
SHA-256 `4ac06e112c93f97a2d54c742db9b7b94528835391d7ebc5473b52d4aaa07188f`.
The [manifest](runtime-traces-manifest.json) records hashes for each member.
The [early source archive](cloud-source.zip) retains the source gate logs.

Full artifact **15250481947** has ZIP SHA-256
`bb1ba7d4033537a4bcf0f75b7c64a21b237750bbaf32be23534025999a96149f`.
Fast artifact **15250495509** has ZIP SHA-256
`e0422b0c0c3bf14bd84f3d9304f3dca78ace70757ab7b3d22d285bea0b11674b`.

The next diagnostic patch records the first live-binding rejection and bounded
already-observed facts about rejected catalog rows. It does not bypass a roster
failure, broaden the initial retry to existing bindings, resend a write, extend a
deadline, or grant release qualification. Those changes require their own native
results, and the target Mac remains unavailable for exact-target GUI acceptance.
