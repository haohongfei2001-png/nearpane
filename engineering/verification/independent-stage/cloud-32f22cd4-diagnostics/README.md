# Minimize animation exposes a repeatable AX health-observation failure

[Run 45714010064, diagnostics job 139555324928](https://github.com/haohongfei2001-png/nearpane/actions/runs/45714010064/job/139555324928), revision `32f22cd41793cdbb0299e34877cd189608863959`, [artifact 15068154266](https://github.com/haohongfei2001-png/nearpane/actions/runs/45714010064/artifacts/15068154266). Original receipts/logs are preserved here; `provenance.json` records their hashes and the verified artifact digest.

The real normal engine again passed launch, foreign round trip, same-app independence, cross-app group and all three A → B → C → A cycles (22 PASS hide/show receipts). A real CG transition produced an onscreen-property value of 1 while the separately read onscreen list contained no target window. That sample was correctly reported as Readback, and the group checks still completed; an incomplete sequential sample was not accepted as physical proof or mistaken for a confirmed identity replacement.

After the fixture invoked its actual AppKit yellow-button action on A0, the health worker read the original retained AX object of same-app A1, which was already hidden in Space 24. The exact trace is **AXMinimized CannotComplete (-25204) → view-minimized-read → health-owned-readback** for window 56 / PID 11516. The one-error health latch then rejected the queued mini adoption with RestoreFirst (218). The mini binding and bridge path did not execute in this run. This is an observed health-observation problem, not proof that third-party hidden-Space migration or a minimized-window move failed.

The first release request also encountered CannotComplete on the original retained A1 object. The second request on the same engine and original leases succeeded; destroy returned zero, and two independent readbacks confirmed all three original windows home with preserved frames, plus the exact original Space inventory. **Yellow-button behavior remains FAIL; cleanup=true.** No writer was reconstructed and no Space with occupants was destroyed.

## Source correction prompted by these observations

The next change preserves AXCannotComplete as a distinct error instead of merging it with a positively read AXMinimized=true. Only that unavailable transport observation may be retried on the original witness inside the existing 650 ms health-observation budget. After it occurs, two consecutive complete identity, geometry, Space-membership and topology observations are required to keep the engine healthy. A positive minimized state, identity replacement, membership change, or any other fault still stops immediately. Persistent unavailability exhausts the same budget and retains the original error and leases. This loop issues no window or minimization writes.

The opt-in CannotComplete diagnostic also stops issuing a second AX window-number request solely for logging, which had added another messaging timeout while the app was already unresponsive. The paired Rust fault records the original lease's exact PID/CGID; skipped diagnostic reads are explicitly labeled unattempted, not fabricated successes.

Three focused Rust regressions cover complete recovery, persistent unavailability and positive bad states before/after a transport retry. Physical verification of this health correction is pending the next fixed revision. The detailed mini-binding diagnostics remain available for the first actual adoption attempt; no AXWindows-absence assumption has been used to alter binding.

The machine is hosted macOS 27 build 26A434 with SIP disabled. This evidence does not qualify the user's 26A428/SIP-enabled target or the R4 product path.
