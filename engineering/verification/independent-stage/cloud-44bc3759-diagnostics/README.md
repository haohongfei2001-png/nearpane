# Original minimized window reaches the AX completion boundary

These are original bytes from the diagnostics lane of
[run 45719571199, job 139574198851](https://github.com/haohongfei2001-png/nearpane/actions/runs/45719571199/job/139574198851),
source `44bc3759198484aa6dcf34943334f4411bd7bb99`,
[artifact 15071028149](https://github.com/haohongfei2001-png/nearpane/actions/runs/45719571199/artifacts/15071028149).
`provenance.json` records the source paths, byte lengths, copied-file hashes and
GitHub-reported artifact digest. The machine is build **26A434, SIP disabled**.

All six initial visible registrations passed: two existing NP_READBACK receipts
for each of three foreign windows, flags 45, with no hidden ownership. The first
never-hidden window then minimized through its real title-bar action. Its retained
original AX object reported **AXDialog**, with `originalMinimized=true` and
`accepted=true`; the exact origin/identity checks admitted that observed state.

The engine proceeded through its minimized-window migration and its own forward
and reverse hidden-membership check for **Space 15**. The subsequent completion
trace records `view-confirmed-minimized` at parking 15, followed by the same
original object's **AXCannotComplete (-25204)**. This phase is reached only after
the one AX deminiaturization request. It does not establish completion of that
request or a successful yellow-button operation: operation 14 returned **UNKNOWN,
detail 217**, after about **268 ms**, and retained one owned window.

The code had reused the **120 ms Space-move observation deadline** for completion
of the asynchronous AppKit minimization transition. The follow-up gives that
completion its own bounded **650 ms read-only observation budget**. It never
reissues AX deminiaturization or the Space move. Each iteration records both
membership directions and the original home; a positively observed return to
home or another Space is a membership failure, not a successful hidden result.
Two complete original-witness reads must confirm non-minimized, unchanged
geometry and exclusive hidden membership within the budget. Persistently
unavailable reads preserve the original error and recovery ownership.

The original result remains **FAIL / initialYellowButtonFailed**. Later group
checks did not run. The first same-engine release restored all three windows and
the complete original Space inventory; **cleanup=true**. Cleanup success does
not qualify yellow minimization, R4, or the user's SIP-enabled target. The new
observation change requires its own macOS execution.
