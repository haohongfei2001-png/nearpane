# Physical StageGroup benchmark receipts

This evaluator reads captures from a trusted physical test session. It starts no application, opens no window, samples no system service, and sends no input. It calculates Gate 4 in [the StageGroup performance standard](../../../../engineering/research/NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md). The checked-in tests generate temporary synthetic data solely to exercise the evaluator.

```sh
python3 -B scripts/acceptance/window-engine/performance/evaluate.py \
  --qualification engineering/verification/window-engine/runs/44881106930/corner/result.json \
  --output /tmp/new-gate4-preflight.json

python3 -B scripts/acceptance/window-engine/performance/evaluate.py \
  --manifest /path/to/immutable-physical-capture/manifest.json \
  --output /path/to/new-report.json

python3 -B -m unittest discover -s scripts/acceptance/window-engine/performance -p 'test_*.py'
```

A preflight emits `NOT_RUN` and exits 2. An evaluation exits 0 only when every required workload, safety measurement and performance threshold passes. Use a fresh output path. Missing, synthetic, non-equivalent and contradictory input retain separate outcomes.

## Captures

The JSON manifest contains `schema: 1`, the installed candidate's SHA-256 as `candidateSHA256`, a `qualification` artifact, and `cases`. An artifact reference contains `path` relative to the manifest directory and `sha256` for the complete file. Symbolic links and changed content are refused. The test session must preserve the original sources and the identities of the processes which produced these digests. Hashes detect changed content; they do not certify where a supplied file originated.

The qualification artifact identifies the installed candidate and contains `kind: installed-stagegroup-safety`, `status` and four separate `phases` named `single`, `ten`, `fifty` and `soak`. Each phase supplies a run for exactly 1, 10, 50 or 1,000 successful end-to-end inputs with unique intent and marker. A contradictory prior safety result stops evaluation before benchmark evidence is opened.

Each case contains an `id`, both directions as pairs of group UUIDs, and an `apple` and a `nearpane` run. A run contains a session UUID and artifact references for the following channels.

| Reference | Recorded by | Required information |
| --- | --- | --- |
| `environment` | Physical session inventory | Hardware hash, boot, OS/build/SIP, physical displays with positions, mode, scale and color space, input device, power, warm/cold state, workload/fixture versions, permissions, initial layout and the signed control owner's PID, birth and path. The Apple control and installed Nearpane Host are identified independently. |
| `input` | Physical input recorder | Actual HID mouse-down, sequence, original clock tick, system control hit, intent and per-trial marker, dispatch start/end/return, both groups and their window lifetimes, planned geometry, and cancellation/recovery state. |
| `observations` | Display, Accessibility and CGWindow observer | Hardware presentation ticks, independent click hit on the enrolled control, visible lease marker digests matching the source, CG/AX identities and geometry, focus, key window, before/during/after order, inactive hit-region readbacks, and unchanged Dock/native/bystander evidence. Captures contain no private titles or text. |
| `owners` | Enrolled fixture receiver | Which process generation and actual window received the unique marker, native receive tick, and before/after synthetic document digests for the target and every sibling. |
| `workload` | Read-only fixture scenario inventory | Confirmed group layout and workload classes. Group sizes and same-/cross-app classes are checked against actual transitioned leases. Bystander and system surface classes require their own enrolled observations. |
| `resources` | Process-accounting observer | Original per-process cumulative CPU counts for the engine, WindowServer and replayd, baseline sampling duration and CPU count, process identities, resident memory, one-second switch bursts and a contiguous 30-minute cycle. |
| `lifecycle` | Physical system lifecycle observer | Stable-notification/reconciliation times, original/restored identity digests and unowned hidden windows for sleep/wake, hot plug and app relaunch. System takeovers include acquisition/release time and the complete write trace. |

All channels except the environment are JSON lines with a header containing schema version, session, boot, clock, collector role, PID, process birth and code SHA-256. The three timing channels include native-to-mach-continuous calibration endpoints, timebase numerator/denominator and an uncertainty in ns. Raw input, presentation and receiver ticks must reproduce the normalized timestamps inside the reported bound. Append every attempted action. Only pre-dispatch external input, topology change and cancellation with zero issued actions can be excluded. A delayed or missing observation after an issued action remains unresolved. The temporary builders in `test_evaluate.py` show the complete field layout.

## Calculation

The evaluator joins independent streams by intent. It checks the original process generations, both AX and CG numbers, the actual pointer hit on the signed system control, fresh composited pixel markers, exact focus and which file actually changed. It checks both directions separately in each matched workload and physical configuration. Each side needs at least 100 valid observations per direction. At least two measured blocks must alternate which system goes first, using actual timestamps. The control process may differ between Apple and Nearpane; the physical environment, display, workload and independent observers must match.

P50, P95 and P99 use nearest rank, one-based index `ceil(p × n / 100)`. The report retains nominal distributions and clock-bounded lower and upper limits. Nearpane must meet both absolute and Apple-relative thresholds. An interval that straddles a limit is `UNKNOWN`. All recorded display slots must be accounted for. Layout converts all four physical-pixel edges to points using the measured display scale. CPU is kernel CPU time divided by elapsed time for one core. Memory uses decimal MB. If idle CPU exceeded 5%, the capture needs its predeclared sustained-duration policy to classify the measured interval. A missing high-refresh/multidisplay, recovery or system takeover case remains in the outstanding matrix.

The current preflight receipt in this directory points to the archived provider gate. It contains no timing distribution, receiver trials or performance claim.
