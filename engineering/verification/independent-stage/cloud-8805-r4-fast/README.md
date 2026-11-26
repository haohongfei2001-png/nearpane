# 8805 fast: real first witness, UI-actor reads still block fresh context

Source `8805a3dbd22c44ff0f95a53476357b4dd45a2ef3`;
[run45742189742](https://github.com/haohongfei2001-png/nearpane/actions/runs/45742189742),
fast job139649628519,
[artifact15080719909](https://github.com/haohongfei2001-png/nearpane/actions/runs/45742189742/artifacts/15080719909).
Hosted27.0.1 /26A434 /arm64 /SIP disabled. This foundation/debug Host is the same
production R4/engine source, not the complete companion-workspace release.

## Actual result

- The normal foreign-window engine and complete physical cleanup pass in this VM.
- The helper confirms the actual button AXWindow equals the retained panel,
  then issues exactly one AXPress with error0. The product handler and group job run.
- The worker becomes ready. The initial physical witness actually completes:
  sequence1, three windows, three managed members.
- A real native Dock observation reaches total age1133.81ms. Ownership is withdrawn
  and Core interrupts initial-witness before NP_LAUNCH. **Product FAIL /cleanup PASS**.
- This run already has live bindings and no `current-click-new-bindings` event.
  It cannot qualify the cold background rebind path introduced by8805.
- The three current fixture images and saved R4 image are not held-image or
  successful group-switch evidence. Cold preview, crash/restart and lifecycle
  checks remain NOT_RUN under their separate prerequisites.

## Actual profile and next correction

The entire290,347-byte Host sample is retained. Among86 main-thread observations,
10 enter the first witness: four opening-roster role reads, four original-window
bindings and two physical observations. This establishes execution on MainActor;
it does not quantitatively apportion the separate1133.81ms delay.
The native Dock reader itself already runs on a background actor.

Moving the earlier live-scope rebinding reads does not move these retained-witness
reads. The next correction isolates only original-AX read work, preserves the
original object and monitor/owner identity, and rechecks input, cancellation,
lifetime, claim and permission after each await. It must not widen750ms, treat an
unknown context as ordinary, or substitute fresh numeric-ID objects for retained
ones. All writes and monitors stay on their owning actor.

`provenance.json` records original artifact paths and hashes. The separate full
candidate's source results passed164 Rust/174 Swift with one skip; this fast lane
does not independently rerun that suite or qualify the full release.
