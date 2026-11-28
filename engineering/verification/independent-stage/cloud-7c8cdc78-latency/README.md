# 7c8cdc78: reader enumeration restored; held preparation still interrupts

Tested commit: `7c8cdc7889334c81d3aa335147035dc41a0a052b`, tree
`645c54c3c8aec78e4bbb9dbb1784ecb3003f66ac`, on the original PR #16 branch.
[Workflow 46138064939](https://github.com/haohongfei2001-png/nearpane/actions/runs/46138064939)
finishes with SOURCE and candidate/signature checks passing, both formal R4
lanes failing, and **release qualification false**.

The tested change reads `result.windows.count` into `acceptedWindowCount`
before mutating `result.census?.acceptedWindows`. Both native lanes now return
real directory replies from one reader helper; neither records the earlier
Swift exclusivity trap. The following held-preparation retry and selected-row
diagnostics were not executed by this run.

## Source gate

[The final audit](source-gate-audit.json) verifies **300 Swift functions = 299
PASS + one existing skip, Rust 188 PASS and native C 25 PASS with zero window
writes**. There are no added tests in this one-file commit. The original reader
transport suite executes nine functions / ten cases. `Reader.swift` has a direct
native compile line; its actual enumeration result is established separately
by the runtime traces below. Context and FULL source originals are byte-equal.

## FAST: five real physical switches and one normally completed selection

The foundation **debug** Host receives six actual AX button presses. Five have
independent double physical confirmations. All 65 worker requests succeed:
six HIDE, four SHOW, 24 READBACK, 29 health, one launch and one RELEASE. All 14
native move confirmations have two complete positive views.

| Selection | Input to first worker | Input to double physical confirmation | Input to job exit | Job outcome |
| --- | ---: | ---: | ---: | --- |
| 1 | 260.862 ms | 1683.448 ms | 2199.550 ms | Superseded by next input |
| 2 | 376.169 ms | 1295.050 ms | 1741.332 ms | Superseded by next input |
| 3 | 347.580 ms | 1181.052 ms | 1571.021 ms | Superseded by next input |
| 4 | 269.502 ms | 1094.594 ms | 1541.909 ms | Superseded by next input |
| 5 | 314.556 ms | 1137.975 ms | 1407.382 ms | Normal completion |

The first four are safely completed physical prefixes, not four final
transactions. For the fifth, the final three complete witnesses agree on exact
focus PID 38492 / window 53; sequence 82 finishes at `1427.391252`, final health
returns at `1427.406747`, and the navigation job ends normally at `1427.417677`.
There is no independent durable-commit timestamp; the analysis bounds it by
the final guards and normal return instead of assigning a fabricated instant.

The first five jobs perform 82 complete witnesses, occupying **4883.944 ms**
in aggregate, versus **1713.632 ms** for their worker operations. Across the
whole lane, 255 retained physical observations succeed; maximum actor-entry
wait is **0.428 ms**, native physical read **16.485 ms**, and return-to-MainActor
wait **3.633 ms**. The nested intervals are not additive CPU measurements.
These same-run phases locate repeated complete witness work as the larger
cost; they do not establish a release-build latency benchmark or a controlled
speedup over a different runner.

The existing protocol already shares its prepared preflight and uses the
engine's post-witness as the Coordinator's first confirmation. Removing another
full confirmation would change the observation contract. The fifth selection's
three final verification reads total 175.646 ms; reducing them to two would be
a semantic change, not deletion of an unused duplicate.

## Sixth input: the foreground opening directory is itself incomplete

The sixth button is the real held-group card, input uptime `1427.515125041667`.
Its metadata scope is reserved and drained with **no pending producer or
publisher**. Revision 191 is created by the current `metadata-owner` at
priority 25; its native sample runs at `1427.555071–1427.701525`.

The first rejection, `product.stderr.log` line 1870 at `1427.729853`, is
`opening-roster`, with three bindings, two claims and sequence 82. The directory
reports `windowRosterChanged` plus `windowIdentityOrBounds` for PID 38492 /
window 86. Its complete typed issue record has no first sample and a new second
sample measuring 66 × 20, active and onscreen, with no requested role read.
No purpose is inferred from that size. No sixth HIDE or SHOW is issued.

This is not a reader crash, a native move timeout, or an undrained background
publisher. The preceding successful witness also has sequence 82; sequence is
not a globally unique event identifier. Source line and uptime distinguish it
from this failed later read.

The proposed next repair is restricted to the first, still-current, no-write
held-card preparation read. It will request at most one entirely new complete
directory under the same metadata capability, retaining all original identity,
physical, closing-roster and Coordinator checks. This run does not verify it.
See [FAST interpretation](fast-interpretation.json),
[compressed analysis](fast-analysis.json.gz), [raw manifest](fast-raw-manifest.json),
and [freeze verification](fast-freeze-verification.json).

## FULL: a distinct first-card appearance failure before any witness

The complete **release** candidate records one actual input and no physical
confirmation or settled selection. It receives directory results from one
helper without an exclusivity trap, parent transport error or target AX-list
failure. The independent Controller passes separately.

The real current-card button identifies PID 43543 / window 52. The first
after-action directory, revision 4, returns a complete result. The existing
selection guard then rejects: `appearanceMatches = false`,
`groupLifetimePresent = false`, `selectionNoLongerCurrent`, with epoch unchanged
and cancellation false. Preparation lasts **48.326 ms**; navigation failure is
logged at `1215.980482583`. No witness read or formal visibility write begins.

The fixture config, earlier readiness and later external observations identify
the original target as PID 43543 / birth `1795864497997767` / window 52.
External reads later find it onscreen at home record 12 with its frame intact.
However, revision 4's exact rows, role, membership, birth and census were not
recorded. Those earlier and later observations cannot establish what revision 4
contained or why its appearance expired. No reset defect, target disappearance
or common cause with FAST is asserted.

The next diagnostics retain only bounded identity/role/membership/count facts
from that exact returned directory and existing enumeration counters, without
issuing additional native queries or changing the failed selection guard.
See [FULL interpretation](full-interpretation.json),
[compressed analysis](full-analysis.json.gz),
[analysis manifest](full-analysis-manifest.json),
[raw manifest](full-raw-manifest.json),
[publication audit](full-publication-audit.json) and
[Dock-delivery audit](full-dock-delivery-audit.json).

## Evidence and acceptance limits

The source, FAST and FULL artifacts each have one assigned download owner.
Their provider digests and all 10 / 110 / 432 raw extracted files are verified
against the original ZIP members. The compact runtime archive preserves 109
original JSON/log/XML/native-test entries, excluding application binaries.

- [Artifact metadata](artifact-api-metadata.json), [provenance](provenance.json),
  [workflow run](workflow-run.json) and [jobs](workflow-jobs.json).
- [Source context ZIP](cloud-source.zip), [Swift XML](source/swift.xml),
  [Rust log](source/rust.log), [C decoder log](source/binding-attributes.log),
  and [candidate receipt](candidate-receipt.json).
- [Original runtime archive](runtime-traces-7c8cdc.tar.gz) and
  [member/hash manifest](runtime-traces-manifest.json).

The repaired exact-member button bounds are not exercised by a member press in
this run. Continuous R4, join/split, later lifecycle/system interactions and
latency acceptance remain unfinished. The target Mac remains offline and
exact-target GUI acceptance is NOT_RUN. Successful cleanup or an independent
Controller run does not fill these missing formal Host phases.
