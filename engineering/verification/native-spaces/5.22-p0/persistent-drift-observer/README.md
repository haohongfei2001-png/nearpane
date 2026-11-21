# P0 persistent observation

The installed adapter for macOS build 26A428 remains disabled. The 10-second single-landing capture, a continuously witnessed 10-action run and the 50-action contract are **NOT_RUN**. The checked-in evidence contains an offline replay and build qualification.

## Archived observations

Run 18 reached Space 5020. The independent public foreground PID changed 2.377519 seconds after AXPress while Space 5020 was still active. The last sample remained on 5020. The following admission refused a second press and did not save a numeric Space sample. The later readback reports Space 6. The archive contains no continuous measurement joining those observations, no signing identity for the external process at handoff, and no contemporaneous membership for its focused window. Both the cause and the transition time remain unknown.

Run 11 independently verified the 2/2 round trip and 10/10 navigation. Its per-action traces end before the required ten seconds and omit the cross-action interval. The new diagnostic does not change those historical verdicts. The machine replay verifies both archive SHA-256 manifests and uses the existing receipt validator on every original action. [Historical replay](historical-replay.json)

## Read-only diagnostic contract

The observer is a separate acceptance executable. It shares the original Space, AX focus, process-birth and HID readers with the acceptance kit. A single process remains subscribed to workspace activation and active-Space notifications while independent sampling continues across journal completion and the next caller checkpoint. Every row carries a sequence, observer session and monotonic time. Each system sample also records when the read began.

Records include the physical display UUID, native Space ID and UUID, ordered topology hash, workspace foreground PID and generation, bundle and code signing identity, system AX focus and CGWindowID, independently matched window memberships, and the Dock and WindowManager identities. Foreground-window attribution pairs CG ownership with reverse membership and forward Space listing. Missing background CG rows are looked up by their exact native window number. An incomplete census preserves positive associations and leaves absence unknown. Reading ends on a change in the eight existing HID counters or eight additional counters covering pointer movement, key release, modifiers, button release and tablet activity. The observer issues zero input and zero restoration requests.

The classifier preserves each observed transition. `landed` requires a confirmed one-step installed journal and independent arrival. `settled` additionally requires continuous readback, exact retained target-document focus, system process identities and ten seconds after confirmation and arrival. `unexpectedForegroundHandoff` records a foreground change independently of Space. `unexpectedSpaceDrift` records a later change of Space. `userSuperseded` terminates observation upon new physical input. `unknown` preserves insufficient identity or continuity. The per-sample gap bound is 450 milliseconds. Relative timing and co-membership are evidence of correlation. The causal-attribution field stays unknown.

## Commands

From the checkout root, reproduce the offline evidence with

```sh
python3 -m unittest discover -s scripts/acceptance/native-spaces -p test_p0_drift.py
python3 scripts/acceptance/native-spaces/p0-drift.py replay
scripts/acceptance/native-spaces/build-p0-drift.sh
```

The build prints the private kit path. On a separately enrolled isolated installed Host, the future diagnostic accepts the following calls. Start observation before the action owner requests a selection. The capture has no action entry point.

```sh
python3 scripts/acceptance/native-spaces/p0-drift.py observe "$kit" "$new_receipt_dir" --seconds 45
python3 scripts/acceptance/native-spaces/p0-drift.py admission "$new_receipt_dir"
python3 scripts/acceptance/native-spaces/p0-drift.py summarize "$new_receipt_dir"
```

`observe` runs in its own process under an existing `NEARPANE_TEST_HOME`. The caller can run `admission` concurrently immediately before each proposed input. It records a private request and closing read, returns a nonzero exit code for unconfirmed or superseded admission, and never authorizes dispatch. The monitor reads new installed Host journal records from the isolated home, observes pending intents, and binds operation UUIDs to the two Space UUIDs and target-window incarnation. A capture with no confirmed selection records `NOT_RUN`. The isolated directory holds the local signing identities of foreground applications. The checked-in replay contains historical evidence only.

## Rollback

Stop the dedicated observer and its receipt collector. They hold no settings, permissions, Space leases or user windows to restore. Reverting the diagnostic commit removes the acceptance entry points and moves the shared numeric routines back to the original acceptance helper. The macOS adapter quarantine and the installed application are unchanged by these files.
