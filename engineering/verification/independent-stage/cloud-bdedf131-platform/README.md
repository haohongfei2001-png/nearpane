# First confirmed third-party hidden-Space mechanism result

[Run 45693479951, diagnostics job 139485867520](https://github.com/haohongfei2001-png/nearpane/actions/runs/45693479951/job/139485867520), revision `bdedf131c94a85621cd24b8969ebbb3564afe0b1`, produced `PLATFORM_FOREIGN_PASS`. Original receipts and the complete logs are in [artifact 15058004983](https://github.com/haohongfei2001-png/nearpane/actions/runs/45693479951/artifacts/15058004983). The files here are original bytes, with SHA-256 hashes in `summary.json`.

## What physically happened

Two newly created ordinary applications owned three real windows: A0 = 53, A1 = 55 (PID 2477), B0 = 56 (PID 2511). They were distinct from the controller process. All three initially belonged to ordinary Space 12. The shipping `np_stage_*` platform atoms created internal hidden Space 13, moved A0 into it and back to 12, then moved B0 into it and back to 12. All four bridge calls returned 1. The test never moved A1.

Eight readback stages each contain two successful physical samples of all three windows. They verify retained original AX identity, process birth and executable, exact window number, forward and reverse Space membership, exclusion from other Spaces, CG onscreen state, and original geometry. Thus the evidence covers an actually hidden foreign window, a same-app bystander, and a second application's independent window; it is not the controller's own-panel canary.

After both cycles, all windows were back at home with original frames. Hidden Space 13 had zero occupants, its destroy call returned 1, and the final all-Spaces inventory matched the original inventory. This platform transaction's cleanup is confirmed.

## What this does not establish

The host was macOS build **26A434**, Apple Silicon, **SIP disabled**. This is useful positive mechanism evidence, not qualification of the user's **26A428/SIP-enabled** host. The diagnostic directly reuses the production C platform atoms; it does not execute the Rust state machine, the worker IPC lifecycle, group switching, the yellow-button transaction, or R4 interaction. Those statuses remain separate.

The preceding normal production controller had created no engine or foreign-window operation: its nonce-bound fixture focus command used activation options 0, and the expected key/foreground prerequisite did not become true. Its receipt remains `BLOCKED controlledFixtureFocusUnavailable`, zero writes. The follow-up adjusts only that explicitly requested fixture activation and logs each acknowledgement/key/exact-focus fact; it does not loosen the production canary's focus checks.

The whole diagnostics job is red because the separate Mission Control bootstrap cleanup ended on a transient `createdDesktopEmptyReadChanged` observation of ordinary Space 12. The hidden Space 13 transaction had already restored all windows and destroyed its own Space. The ordinary desktop cleanup remains unconfirmed in this run, so overall runtime is `UNKNOWN` and subsequent native edge experiments were skipped. A failed whole-job conclusion must not erase the independently confirmed platform result, and the platform result must not promote the whole job or product to PASS.
