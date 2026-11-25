# Normal engine diagnostics, 81669d13

[Run 45703598130](https://github.com/haohongfei2001-png/nearpane/actions/runs/45703598130), diagnostics job `139519726914`, artifact `15063428182`. Product implementation is unchanged from 5607d3b; this workflow revision moves the existing fast lane to real CIWorkspace preparation so it can exercise normal engine preconditions before the full package finishes.

The controlled AX preparation successfully set the exact fixture window Main and its application Frontmost: both calls returned zero and their state reads passed. Final fixture `key`, application-active, foreground PID, and two exact AX focused-window reads all confirmed the intended window. The helper nevertheless reported `controlledFixtureFocusUnavailable` because a guard prevented a subsequently attempted Raise step and the helper required all three preparation steps to complete. Raise was **not written**, NP_LAUNCH was **not executed**, and engine Space writes were zero. `setupAXWrites=2` keeps the two actual preparation writes explicit. This identifies a preparation-completion bug; it supplies no canary or normal-engine success evidence.

The separate platform diagnostic again passed its foreign round trips and cleanup. Real CIWorkspace preparation and cleanup returned READY, and both fixture processes exited via nonce-bound quit commands. The source suite, complete candidate, and R4 product path were NOT_RUN in this lane. The runner remained build 26A434 with SIP disabled, so this is not target qualification.

The five receipt/log files are byte-identical originals. `provenance.json` records their source paths, hashes, and the complete platform receipt's artifact hash without duplicating its events.
