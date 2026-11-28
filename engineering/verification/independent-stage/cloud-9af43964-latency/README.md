# R4 9af43964: source passes; two distinct read failures precede member coverage

**The exact source and complete candidate pass. FAST obtains no decoded desktop
snapshot and issues no R4 input. Full obtains normal snapshots, then rejects its
first selection while reading a target application's complete AX window list.
Neither lane reaches the repaired member button. Formal R4 and release
qualification remain unfinished.**

Tested source: `9af439644f93bf6c77c3234be19093ef92327c1c`, on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46135195913](https://github.com/haohongfei2001-png/nearpane/actions/runs/46135195913)
is terminal: FAST and full fail, diagnostics pass. The previous 3f531 run's
12 physical confirmations and shared join do not qualify this later source.

## Exact-source gates

| Gate | Actual 9af439 result |
| --- | --- |
| Swift XML | 300 functions: 299 passed, one existing skip, zero failures |
| New member geometry | Two functions / seven cases actually execute and pass |
| New optional census wire | Two functions / five cases actually execute and pass |
| Prior Dock / queued edit / preparation | 20 / 11 / 15 cases continue to pass |
| Rust stdout | 188 passed, zero failed or ignored |
| Native AX decoder | 25 passed, zero failed, zero window writes |
| Complete candidate / strict signature | PASS; sourceChecks=PASS; qualificationGranted=false |

The [source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log),
[early context ZIP](cloud-source.zip) and [candidate receipt](candidate-receipt.json)
retain exact evidence. Full/context Swift stdout, stderr and source summary match
byte for byte. Some individual compiler progress lines are absent; the audit
records the actual module emission, linking and exact package membership without
inventing per-file progress messages.

## FAST: no decoded snapshot, no actual R4 input

The [FAST interpretation](fast-interpretation.json) and
[compressed analysis](fast-analysis.json.gz) preserve all 37 request timelines.
Product status is `BLOCKED / fixtureGroupsNotReady`: **zero inputs, zero physical
confirmations, zero witnesses and zero production Host worker requests**.

All 37 observer requests return `receivedReply=false` at `reader-validation`,
and all 37 publications have no snapshot. Each request starts and then reaps a
reader helper. The first child starts at **371.127128**, is reaped at
**371.343224**, and the task exits at **371.344459**. Reader-await time has a
**203.646 ms median / 1058.204 ms maximum**. Dock's 31 paired reads remain ordinary
with no expiry, and system dispatch remains eligible until cleanup.

These records do **not** identify the transport failure. The old reap event lacks
wait status; cleanup itself sends SIGKILL on any exchange or decoding error. Child
stderr is discarded. `receivedReply=false` means no decoded `DesktopSnapshot`,
not necessarily that the pipe returned no bytes. It cannot distinguish natural
exit, crash, service rejection, frame failure, decoding, validation or timeout.

The independent Controller path also fails, at `initialYellowButtonFailed`, before
its later direct-engine qualification. It records two setup AX writes and one
window write. This is separate from the formal Host's zero-input path and is not
used to infer the overview helper's root cause.

Host cleanup reports released in **34.302 ms**, with external double home/frame
checks for the three fixtures. This is recovery evidence, not successful R4
window control. The member-button, observation-timing and census paths remain
unreached or without replies in this lane.

## Full: valid directory replies, then a target AX-list refusal

The [full interpretation](full-interpretation.json),
[compressed analysis](full-analysis.json.gz),
[publication audit](full-publication-audit.json) and
[Dock audit](full-dock-delivery-audit.json) preserve the independent ordering.

Full uses **one helper and receives nine successfully decoded desktop replies**, with no
reader-validation failure. Its first native read runs
**847.893575–847.942170** and is decoded successfully. A later incomplete revision
7 also successfully carries the new census data: first public/expanded/eligible/
accepted counts are **39/43/27/21**, second counts **41/45/29/22**, with a new
second-only window 91. This later partial directory is not the first failure.
These successful replies rule out a constant failure of the new source across
both environments; they do not identify why FAST fails.

Full records **one actual R4 press, zero physical confirmations and zero final
settlements**. Its initial witness has sequence 0, three bindings and no claims.
At PID 31558 / window 56, physical observation reaches
`original-ax-list-membership` and `SystemEvidence.windows` rejects because the
existing `AXWindowList.read(..., limit: 64).windows` is nil. The recorded error is
the complete-window-list refusal. The earlier target AX attributes, CG identity/
geometry, bidirectional membership and onscreen checks have passed; the final
focus, original-number, membership and inventory checks remain NOT_RUN.

This is **not** a Finder desktop-list or launch-canary failure. The preceding
Finder desktop checks succeed. The focus diagnostic's AXScrollArea and -25212
attribute errors are not target-list errors. This version does not record the
target list's count/array status, so a -25204 error, changing count, malformed
array or exceeded limit cannot be asserted.

### The new timing split executes on the failure

| Existing physical-observation segment | Wall time |
| --- | ---: |
| Host access check before read | 1.018 ms |
| Owner check before read | 17.187 ms |
| Submit to reading actor | 0.030 ms |
| Actual physical-reading function | 141.106 ms |
| Reading actor to MainActor | 0.030 ms |
| Entire failed observation | 159.477 ms |
| Entire interrupted initial witness | 1727.360 ms |

This single failure spends its dominant observation time inside the physical
read, rather than waiting for either actor handoff. It does not establish the
latency distribution of successful continuous switching. The native and handoff
intervals are nested inside `physical-await` and must not be added to that parent
interval again.

No launch, HIDE or SHOW is issued. The only production worker request is a later
**21.465 ms RELEASE**, PASS with owned=0. Full's independent direct-engine test
passes with 26 writes, but those writes are not counted as formal R4 actions.
All cleanup and two external home checks pass. There are 27 one-shot Dock
consumptions, including three timer-before-callback cases, and no expiry.
The single metadata scope ends normally; the 5.019-second activity does not
cover a lane longer than the 12-second directory freshness bound.

## Next source: expose the exact refused read, without changing its decision

The next patch records parent transport/exchange stages, whether a complete
payload arrived, and the original kill/wait results. Only the existing trace
switch enables child stderr and forwards that one trace flag; the normal
PATH-only child environment and discarded stderr remain unchanged.

The helper records its existing request, sampling, snapshot-validation and reply
phases on failure, including already-produced census counts. The target-list
wrapper records the same `AXWindowList.read` result's count and array statuses
before the original refusal. These changes add no window query, retry, cached
permission, relaxed identity check or new action. Original errors, exit codes,
timeouts and recovery remain in place. Their compilation and runtime evidence
belong to the following source revision, not this run.

The [runtime archive](runtime-traces-9af439.tar.gz) and
[member manifest](runtime-traces-manifest.json) preserve 84 ZIP-verified files.
[Provenance](provenance.json), [provider metadata](artifact-api-metadata.json),
[workflow](workflow-run.json) and [jobs](workflow-jobs.json) retain the source,
candidate and runtime boundaries. The target Mac is offline; exact-target GUI,
the new member button, join/split, later lifecycle and release acceptance remain
unexecuted for this source.
