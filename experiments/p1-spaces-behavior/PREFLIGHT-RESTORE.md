# P1-B preflight and restore checklist

**Current status: PREPARATION ONLY. Behavioral testing: NOT TESTED.**
No Space switching, Mission Control setting change, logout/restart, window activation,
focus/move/resize/close, pixel capture or new permission request is authorized in this session.
The following are future operator steps, not instructions for this helper to execute now.

## Before a future observation

- [ ] Record explicit authorization for the exact actions, displays, modes and recovery steps.
  Read-only polling permission alone does not authorize switching/settings/session changes.
- [ ] Record observer source commit, binary SHA-256, test receipts, OS build and start time.
- [ ] Reuse the existing P1 baseline report. Create a new bounded action-session receipt;
  do not silently treat old baseline evidence as a new before-state.
- [ ] Record original effective separateSpaces value, operator-reported settings value,
  Stage Manager state and any other relevant Mission Control settings. Do not change them
  merely to make the experiment easier. Conflicts remain UNKNOWN until resolved.
- [ ] Record public display topology/fingerprint, main display, rotation and arrangement.
  Privately associate physical roles A/B with this session's display aliases. A new process
  or login creates new aliases; establish role correspondence afresh, without publishing UUIDs.
- [ ] Identify safe existing test windows and record private metadata/restore references;
  any creating, moving, activating, fullscreen or closing of windows needs its own scope.
  This observer never performs those actions. Do not collect pixels or window titles.
- [ ] Save work through the operator's normal workflow before any separately authorized
  session change. Document a return path and stop criteria before the first switch.
- [ ] Choose a new local, non-synced evidence directory outside the repository; verify disk
  space and 0700/0600 output. Confirm count/duration/byte limits and marker input workflow.
- [ ] Obtain a repeated before-state with no intra-sample change. `stableIncomplete` requires
  documenting each unresolved scope/current/window and limits the claims possible.
  Do not use a transient/incomplete sample as proof of a completed transition.

## Future false/true observations (only after explicit authorization)

- [ ] Record the mode from the observer, not merely from the checkbox or a marker.
- [ ] For each mode, run A-initiated and B-initiated native user Space transitions, including
  return to the original state, at least three times per direction. Retain all failures.
  Each trial has beforeAction/afterAction markers, before/after stable revisions, user-reported
  visible result on both displays and unresolved-window counts.
- [ ] Record both scopes' current IDs/anonymous aliases and visible-window membership;
  do not add scope lengths and call the sum independent desktops. Do not infer behavior
  from current IDs without the operator's visible observation.
- [ ] Wait for a fresh repeated state after each action. If the deadline is reached without
  one, record TRANSIENT / UNRESOLVED and stop that trial; never retry automatically.
- [ ] Stop comparison if topology changes; keep the failed trial and re-establish matching
  conditions through a separately authorized step. Do not hide it by relabeling displays.
- [ ] A false/true setting change is a separate authorized operator operation. If macOS
  requires logout/relogin, obtain authorization for it; stop logging and save work first.
  Never initiate it from this helper. Start a new observer process after any session change.
- [ ] After login or a setting change, establish a new effective mode and topology receipt.
  Do not assume hot switching worked, carry old Space/window identities across sessions,
  or compare HMAC fingerprints across sessions. Match physical A/B roles privately.
- [ ] Window movement, fullscreen, sleep/wake, display attachment and activation experiments
  remain distinct scope; preparation here does not silently include those gate-review items.

## Stop and restore (future operator only)

- [ ] Send `stop` to end polling; record footer or INCOMPLETE if interrupted. Preserve all
  existing files, including partial/failed logs. Do not overwrite or automatically restart.
- [ ] The authorized operator returns to the original mode and desktop/Space on both displays,
  and restores only those settings/windows explicitly included in the experiment.
- [ ] If restoring the original setting requires logout, preserve work and obtain/verify that
  authorization before doing so. Never interpret this checklist as permission to log out.
- [ ] Start a fresh bounded receipt and record `restored` as an operator claim. Verify effective
  mode, topology, current-state relations and known test-window membership with repeated reads.
  Compare original physical roles and visible layout, not old runtime IDs across logins.
- [ ] Operator confirms visible restoration independently; unresolved mismatches remain
  RESTORE UNCONFIRMED. A marker or matching inventory alone is not restoration proof.
- [ ] Hash both local evidence files. Publish only reviewed sanitized material and a report;
  keep raw data and any private role/identity map on local private storage.
- [ ] Complete the comparison report and keep all unexecuted cells **NOT TESTED**. Preparation
  completion does not close P1-B or P1-Core and does not enable production Spaces actions.
