# P1-B separate-Spaces comparison — template

**Overall: NOT TESTED — pending explicit user authorization.**
This blank template and the synthetic test suite contain no off/on behavioral evidence.

## Provenance and scope

| Item | separateSpaces=false | separateSpaces=true | Restored original mode |
|---|---|---|---|
| Explicit authorization / permitted actions | NOT AUTHORIZED | NOT AUTHORIZED | NOT AUTHORIZED |
| Observer source commit / binary SHA-256 | — | — | — |
| OS version / build / session UUID | — | — | — |
| Raw evidence local path / SHA-256 (private) | — | — | — |
| Sanitized evidence path / SHA-256 | — | — | — |
| Start/end sequence; complete footer? | — | — | — |
| Effective API mode / operator setting report | NOT TESTED | NOT TESTED | NOT TESTED |
| Physical A/B to anonymous display mapping (session-local) | — | — | — |
| Public topology / rotation / main / mirror | — | — | — |
| Topology fingerprint (compare only within session) | — | — | — |
| Matching physical topology across modes confirmed? | NOT TESTED | NOT TESTED | NOT TESTED |
| Stage Manager / other settings / test-window conditions | UNKNOWN | UNKNOWN | UNKNOWN |
| Session restart required/performed/authorized? | NOT TESTED | NOT TESTED | NOT TESTED |
| Scope/Space counts (inventory only; no desktop-count claim) | — | — | — |

## Per-trial current-state and window comparison

For every row retain forward **and return** legs. Link marker sequence numbers, sample
revisions and failure records; expand rows when needed. All Space/window tokens below are
session aliases. For windows include known membership, unknown/null/empty/malformed counts,
onscreen changes and the privately identified test-window alias. Do not guess a display
assignment from window bounds; coordinate mapping remains a separate gate.

| Mode | Initiating display | Trial | Before/after/return revisions and markers | A current before→after→return | B current before→after→return | Onscreen + membership deltas / unresolved | Operator visible result on A / B | Stable status / topology unchanged? | Result |
|---|---|---:|---|---|---|---|---|---|---|
| false | A | 1 | — | — | — | — | — | — | NOT TESTED |
| false | A | 2 | — | — | — | — | — | — | NOT TESTED |
| false | A | 3 | — | — | — | — | — | — | NOT TESTED |
| false | B | 1 | — | — | — | — | — | — | NOT TESTED |
| false | B | 2 | — | — | — | — | — | — | NOT TESTED |
| false | B | 3 | — | — | — | — | — | — | NOT TESTED |
| true | A | 1 | — | — | — | — | — | — | NOT TESTED |
| true | A | 2 | — | — | — | — | — | — | NOT TESTED |
| true | A | 3 | — | — | — | — | — | — | NOT TESTED |
| true | B | 1 | — | — | — | — | — | — | NOT TESTED |
| true | B | 2 | — | — | — | — | — | — | NOT TESTED |
| true | B | 3 | — | — | — | — | — | — | NOT TESTED |

## Findings and limitations

| Question | Evidence-linked finding |
|---|---|
| false: do user-visible desktops change together reproducibly? | NOT TESTED |
| true: is A independent of B and B independent of A reproducibly? | NOT TESTED |
| What does the 3+1 inventory shape correspond to in visible behavior? | UNRESOLVED |
| Do current-state, membership and operator visible results agree? | NOT TESTED |
| Unknown scopes, missing current, unknown windows, transient/failed trials | NOT TESTED |
| Is there a verified mapping across modes without persisting runtime IDs? | NOT TESTED |
| Original setting, effective mode and visible layout restored? | NOT TESTED |
| P1-A ABI/selector/lifetime prerequisites and outstanding limits | NOT VALIDATED HERE |

Accept a mode/direction claim only with three consistent authorized forward/return trials,
matching topology/conditions, interpretable stable snapshots and corresponding operator
visible observations. Keep contradictions UNRESOLVED, failed trials FAILED, incomplete
logs INCOMPLETE, and absent tests NOT TESTED. State any limited known-window coverage.
Neither `stable` nor an `afterAction`/`restored` marker alone is a behavioral PASS.
No Nearpane production action support or cross-build compatibility claim follows from this report.
