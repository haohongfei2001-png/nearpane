> **2026-11-28 权威范围更新：** [产品宪章](../../PRODUCT_CONSTITUTION.md) 是唯一现行产品规则。本文仍是 Spaces 独立调度后端及其实机证据的重要技术依据；不是整个 Nearpane 的产品定义。本文旧有任何排斥自动平铺、将布局恢复与新组布局混同、要求模块固定等级或阻塞其他成熟模块发行的解释，以宪章第 5、6、12 条为准。技术路线、恢复与真实验收保障保持不变。

# Nearpane — independent Stage Manager replacement

Current authority, 2026-11-28 (Asia/Shanghai). Baseline: PR #15, `6ac5eb63c97b7597e662770bac485be61f571bb8`.
Work branch: `pro/independent-stage-engine-20261126`.

## Product contract

Nearpane replaces Apple's Stage Manager. R4 flat, real-window thumbnails are its only stage interface.
The selected group contains real windows on the current ordinary desktop. Other groups leave that
desktop's work area by entering process-owned hidden Spaces. A card restores the original windows,
layout and exact focused member. Group identity is `Display → ordinary Desktop → StageGroup → window
(PID, process birth, CGWindowID, retained AX lifetime)`; applications are not the unit of dispatch.

Same-app windows may be in different groups; different apps may share one group. R4 merge, detach,
member selection and the existing screenshot, voice and file modules remain. Yellow minimize is an
event to retire the exact enrolled window and restore it through R4. Pre-existing Dock-minimized
windows retain their prior state. System desktop gestures, Mission Control, App Exposé, fullscreen,
Split View and desktop reveal remain system interactions.

Corner parking, wallpaper/shield masking, pointer interception to simulate invisibility, and Apple
native-strip mirroring are not product routes or fallbacks. Old receipts and recovery code are historical
evidence, not permission to choose one of those routes. A failed independent engine restores its owned
windows and stops scheduling; it does not silently activate another backend.

## Decision and its evidential boundary

**Implement route B: an independent hidden-Space scheduler.** Keep the existing Swift R4 and group
coordinator, Rust static library, and C ABI. This reuses implemented window identities, journalled group
switches, exact-window focus and geometry operations, and real preview ownership instead of replacing
the working product modules. The same Rust static library runs in a small sealed, bundled AppKit worker
so it retains the original AX leases and WindowServer connection when the Swift Host exits. Private
anonymous pipes carry the existing C request/receipt layout; EOF or parent exit enters release-only
cleanup and refuses to destroy an occupied Space. There is no second engine or same-process fallback.
Worker SIGKILL and WindowServer restart remain separate physical experiments, not inferred guarantees.

This is an implementation decision, not a claim that the complete macOS 27 product has passed.
The compiled candidate and the release qualification are separate paths. An explicit, separately
identified candidate application runs the complete Host and R4 with a separate profile. The automated
acceptance copy additionally restricts dispatch to enrolled fixture PIDs. Neither form manufactures a
passing qualification or overwrites `/Applications/Nearpane.app`.

### Current verification checkpoint

#### Current verification checkpoint: f4934582, 2026-11-28

`f4934582` reuses a pending directory result only when both its actual wall-clock
and native sampling starts are strictly later than the new action boundary. It
retains the real revision, all freshness/completeness limits, session revocation
and the subsequent independent proof. Its new async test runs all 16 parameter
cases successfully. Source reports 180 Rust and 228 Swift passes with one skip.
The original XML confirms229 function entries (228 passes/one skip), while the
new function has16 actual parameter executions in stdout. C identity checks
pass13 cases with zero window writes.
The target Mac separately completes the full release build (265.445 seconds),
package and strict deep signature. It remains a build-only result: the most recent
target context was locked, and no new candidate GUI or R4 input was launched.
[Target f493 native build originals](../verification/independent-stage/target-f493-build/README.md).

Fast issues one real R4 input and confirms no complete switch. Its sole initial
witness succeeds in818.329 ms, after222.763 ms preparation. There is no roster
rejection. All three explicit after-action reads finish with `reusedPrior=false`;
the sole prior revision3 sample began74.135 ms before both entry clocks, so the
new branch correctly refuses it and returns the fresh revision4. This lane has
not exercised a positive reuse hit and supplies no measured speedup.

The subsequent canary Open fails its existing300 ms budget. The label
`main-queue-timeout` covers queue wait plus the complete AppKit call: measured
queue wait is0.683 ms and panel-call work747.248 ms. The original guard prevents
late `orderFront` after construction. No fixture HIDE/SHOW follows. In parallel,
a Dock read runs1903.447 ms and arrives1096.859 ms after its native end; Host
revokes ownership. The worker has no absolute event timestamps in this revision,
so those two failures cannot be ordered against each other. Host main-thread
sampling does not identify the worker's slow AppKit subcall.

Fast's final status is UNKNOWN/productionRestoreIncomplete. Host shutdown reports
`released=false` and cleanup remains false. Two independent physical reads confirm
the three fixture windows at home and visible, while the worker separately retains
a `release-pending` receipt with status2/detail225/flags128/owned1. Outer CI cleanup
is successful. These three cleanup boundaries remain distinct. Fast's direct
engine passes26 requests; the separate diagnostics engine is BLOCKED before writes
by its canary, with only a platform fallback pass. A green diagnostics job does
not establish the direct engine result.
The unsampled full release also issues one input and confirms no switch, but
has a different early failure. Preparation succeeds in2860.695 ms; its first
directory waits1914.895 ms for prior revision4 and then843.606 ms for fresh
revision5. That prior begins46.973 ms before the actual read entry on both clocks
and is correctly not reused. The old native sample itself takes1914.856 ms;
its task queue takes only0.604 ms, so this is not a demonstrated actor-admission
stall. At roughly2955 ms after input, group choice exits at `current-intent`
with the generic busy error, before any witness, roster check or worker creation.
The four short-circuit checks at that point are wallpaper state, exact member
lifetime, current selection/session/input, and current environment. No action-time
Dock revocation or new-selection event selects one of them from the old trace.
Full's Host release, physical return double-read and outer CI cleanup all pass;
its direct engine passes26 requests.
[Exact f493 source and runtime evidence](../verification/independent-stage/cloud-f4934582-latency/README.md).

The next scoped patch explicitly carries the calling Swift task priority through
the existing worker SUBMIT/POLL/wait bridge, and measures actual task priority and
request timing. The old bridge omits that argument and samples execute on a
default-QoS queue; this does not measure their Swift task priority or explain the
747 ms panel body. Separate opt-in worker timing will locate time within the
original Open steps and correlate late callbacks using an absolute clock and call
ID. It adds no window/focus queries, moves no native operation and extends no
deadline. The same patch also caches the first failed current-intent guard and
its already-read environment rejection; it does not repeat these queries at exit.
No catalogue exception or cleanup-success override is justified here.

#### Earlier R4 latency work through 6d058079, 2026-11-28

Continue on the existing PR #16. The immediate deliverable is the formal R4 path from
the actual thumbnail press through real sibling hiding, target restoration and exact
focus. Interaction polish, broader stability qualification and release follow that
physical result. This is implementation work on the selected route, not a new route
comparison or a wholesale handoff.

`d230e38c` moves directory AX projection and advisory window-number enumeration away
from MainActor, and defers preview work during queued/running R4 dispatch. Its fast
native run reaches exact focus and eight complete witnesses, but does not hide the
two siblings before the unchanged eight-second physical-state deadline. The full
candidate builds and passes signature verification but rejects an incomplete opening
roster. Source reports 166 Rust passes and four issues among 204 Swift tests.
[Exact d230 receipts](../verification/independent-stage/cloud-d230e38c-latency/README.md).

`a3ab1e67` starts the full initial roster without waiting for the advisory hint,
moves cold SCStream construction off MainActor, revalidates capture after preparation,
and removes same-turn duplicate native queries. Its 166 Rust tests pass; 205 Swift
tests leave one capture-scheduling test issue while the earlier continuity/hint
failures pass. The fast product stops before input: a 72.6 ms catalogue is 12.45 seconds
old at failure, alongside a 2.475 ms Dock read delivered 12.6 seconds late. Its saved
directory already contains the three expected groups. Zero counted capture starts
does not exclude construction in progress, and there is no startup sample to name
the blocking call. The fast engine passes 26 requests; the separate diagnostics VM
fails after six, with cleanup confirmed independently. The full candidate builds
and passes signature verification. Its one actual R4
press focuses the target and hides one sibling; the other sibling remains visible
at the eight-second deadline. Eleven witness reads take 4,624 ms, approximately
82% in opening/closing directory acquisition. Product cleanup is UNKNOWN /
productionRestoreIncomplete: a restored-window AX list read cannot complete and
is classified as Identity. Later worker EOF cleanup is not an independent physical
return receipt and cannot upgrade this result.
[Exact a3ab receipts](../verification/independent-stage/cloud-a3ab1e67-latency/README.md).

`d66866eb` reuses the same Spaces coordinator's immediate full preflight inside the
session, preserving the new full read after worker health, Rust READBACK, independent
readback and both Coordinator post-write confirmations. A separate bounded startup
sample and opt-in attestation phase timings distinguish startup from actual-click
latency. The capture test now waits for a real MainActor turn instead of treating
parallel suite scheduling as a two-second performance test. Local Python runner
tests are 14/14 PASS. Exact-commit native source passes 166 Rust and 208 Swift
cases with one explicit skip; the complete candidate builds and passes signature
verification. The full product issues one actual R4 press but fails before both
siblings hide; physical cleanup is confirmed. Its independent engine fails the
later yellow-button case with cleanup confirmed. The fast and diagnostics native
runs are BLOCKED before foreign writes by independent ordinary-desktop/canary
preconditions; green job/platform-only status is not a foreign-engine PASS.
The new fast startup sample directly identifies lazy app-icon generation during
DesktopWindowCard Canvas drawing, waiting in synchronous IconServices XPC on the
main thread. No attestation phase was reached in that blocked product run.
The separate full run measures six environment attestations at 13.152–21.736 ms,
median 18.867 ms; this evidence does not identify attestation as its seconds-long
bottleneck. Its first witness takes 3,551 ms, including 1,136 ms opening directory
and 1,755 ms initial binding. Later witnesses take 327–531 ms.
[Exact d668 receipts](../verification/independent-stage/cloud-d66866eb-latency/README.md).

`ff2617f5` materializes app icons into independent bitmap pixels off MainActor,
shares the session's already-complete post-write Host witness with the Coordinator's
first confirmation, and preserves the second distinct complete confirmation. It
also distinguishes AXCannotComplete transport absence from a positive identity
failure without changing the 120 ms move-readback deadline. Its full release run
completes the first two actual R4 selections: 4,618 ms and 6,989 ms from external
AXPress to two independent physical readbacks and the exact-target-focus gate.
The first selection hides both siblings; the second restores the selected original
window and hides the previously active window. The third press queues 3,195 ms
behind the previous navigation job and is not completed. A separate worker health
receipt records zero complete observations and 882 ms elapsed against its unchanged
650 ms budget, still in the connection phase; it has no event timestamp permitting
an exact placement on the Host timeline. All original windows are independently
confirmed restored at shutdown. The product remains FAIL, although the direct
engine passes. Source Rust passes 169 tests; two Swift test compilation mistakes
are corrected in the following commit.
[Exact ff2617 receipts](../verification/independent-stage/cloud-ff2617f5-latency/README.md).

`5a1cfbc6` passes 169 Rust and 215 Swift tests, with one explicit Swift skip.
The full release package and signature pass, as do all three direct-engine lanes.
Full R4 completes its first real selection in 3,552 ms, then rejects the second
at the Coordinator's initial witness. That second click dequeues immediately;
its two overlapping witness intervals identify concurrent observation for further
investigation, not proof of a WindowServer write failure. All original windows
are physically confirmed restored. The fast R4 lane is BLOCKED before input:
the retained accessibility element changes from AXButton to AXStaticText and loses
its identifier at the pre-press check. It is correctly not pressed. Neither lane
is a full product PASS. No native -25204 binding fault occurs in these runs, so
their successful cleanup does not independently exercise the new transport-retry
classification. Opening/closing directory acquisition accounts for approximately
84% of summed full witness durations in both revisions; overlapping durations
are not wall-clock totals.
[Exact 5a1cfbc receipts](../verification/independent-stage/cloud-5a1cfbc6-latency/README.md).

`cb95d6aa` keeps new idle held-window verification outside the complete explicit
navigation lane, including the initial read before the Coordinator becomes busy.
Passive health preparation now scans only owned members of the selected original
lease's slot; its original deadline, full observation and command/release cleanup
are unchanged. Source passes 174 Rust and 217 Swift tests with one skip, and the
complete release package and signature pass. Both fast and full direct engines
pass 26 requests. The separate diagnostics candidate remains BLOCKED before
foreign writes; its platform-only result is narrower evidence.

The fast product completes selection preparation in 2,760 ms but later loses
dispatch eligibility when a 2 ms Dock read is delivered approximately 936 ms late.
Its first directory read spends 473 ms waiting for a prior task and 2,271 ms in
the new read; no complete witness or actual hide follows. Full preparation takes
only 244 ms, with a 202 ms new directory read, then completes one 453 ms witness.
Its separate failure is a canary panel-home focus observation: after five successful
Finder desktop structural proofs, one AXRole read returns AXCannotComplete while
the other owner/parent/containing-window/list relationships still match. The
canary rejects ProbeFocus before enabling the route. The canonical-number -25201
diagnostic also appears in earlier successful desktop proofs and is not the
changed field. Both products issue one actual input, confirm no selection, and
independently confirm every original window returned at shutdown. Neither reaches
a held selection, so this run does not physically validate the new idle gate.
[Exact cb95d6aa receipts](../verification/independent-stage/cloud-cb95d6aa-latency/README.md).

`a37b56c6` makes automatic HostSession display polling yield while the R4
navigation lane is occupied, without changing explicit authoritative reads,
in-flight readers or the saved snapshot's original expiry. Directory-task phase
timing separates queueing, native-helper work, projection and publication. The
external AX driver retains its first semantic button identifier across bounded
pre-press rediscovery, never replaying an issued action. Canary home discovery
distinguishes a narrowly proven missing Finder desktop AXRole from positive focus
or identity changes; its existing650ms deadline requires two new complete proofs,
remembering the first observed home across incomplete samples.

Both a37 product lanes still fail their first selection. Fast preparation is
286.6ms and navigation queueing0.54ms. One sibling is genuinely hidden and the
selected window has exact focus, but the other sibling remains visible at8s.
Initial witness binding takes1382.8ms; a subsequent fresh directory task waits
1499.4ms to start, then runs for154.1ms. Full preparation is132.4ms, with fast
opening directory reads, but its first witness rejects after4466.3ms when dispatch
evidence expires. The retained Dock observation itself took3.043ms and was3415.1ms
past its native end at expiry; this does not establish its first delivery time.
The full sample is mostly main-run-loop waiting and shows the background physical
reader on a utility-QoS cooperative worker. It does not prove App Nap or a single
synchronous call caused the elapsed interval. Both lanes confirm complete physical
return at shutdown; only fast had actually hidden a window. All three separate
direct-engine lanes pass26 requests.
[Exact a37 cloud originals](../verification/independent-stage/cloud-a37b56c6-latency/README.md).

The a37 source gate fails independently: three Rust test-mock E0609 compilation
errors and an old Swift test's two-second MainActor semaphore assertion.
`b2513db0` changes only these tests: explicit optional-window unwrapping and
deterministic physical-read/input handshakes. Its exact cloud source passes
180 Rust and219 Swift tests with one explicit skip. The same180 Rust tests and
full release build pass on the SIP-enabled target Mac. Those source/build results
do not upgrade the separately unpassed formal R4 runtime.

The target reconnected at23:43 Asia/Shanghai on November27. Its existing clean
isolated checkout was fast-forwarded, preserving the daily installation. The a37
complete release build succeeds in371.913s. Actual native preflight then finds
one display whose current Space7015 is raw type4, while ordinary desktop4 is
present but inactive. It correctly performs zero R4 inputs and zero window writes,
records BLOCKED and confirms unchanged Space inventory/fixture cleanup. A later
read-only context confirms that fullscreen state.
[Exact target preflight originals](../verification/independent-stage/target-a37-r4-preflight/README.md).

`34f37360` explicitly gives the existing navigation drain Task user-initiated
priority. Exact native source passes180 Rust and220 Swift tests with one skip,
including a utility-parent test that checks action priority before and after
real suspension. Full native R4 observes navigation priority25 and the relevant
directory tasks also record25 at exit. The change reached real execution but
did not remove the queue delay: opening-witness revision7 waits3029.316ms to
start, then executes in370.147ms, including79.731ms native observation. Saved
Dock evidence expires before the witness rejects its opening roster. One actual
input produces no confirmed selection and no product HIDE; all original windows
are physically confirmed returned at shutdown. Fast separately stops before
input on an incomplete live accessibility tree. Its automatic reads at priority17
do not describe a selected-window action.
[Exact34f source and cloud originals](../verification/independent-stage/cloud-34f37360-latency/README.md).

The complete34f target release and strict/deep signature also pass. Two separate
target attempts stop before an R4 press: one observes native Stage Manager enabled,
and the other reaches a fullscreen current Space at engine preflight after an
earlier ordinary-desktop observation. Neither is a product runtime PASS. Both
confirm fixture cleanup; the temporary preference change, original desktop and
original foreground were positively restored. Later observations show a new
ordinary-desktop/native-Stage-Manager-off state, then the daily Nearpane installation
running. This newer user state supersedes the old restoration target; the daily
application has not been replaced or terminated.
[Target candidate](../verification/independent-stage/target-34f-candidate/README.md),
[separate target preconditions and restoration](../verification/independent-stage/target-34f-preconditions/README.md).

`c64bf6d5` declares accepted explicit user work using
`ProcessInfo.userInitiatedAllowingIdleSystemSleep`, retaining it across the actual
navigation job and any existing asynchronous release it initiates. It ends when
those operations finish, not when long-lived hidden-window ownership disappears.
Automatic observations and focus resumption do not acquire this activity. This
is a user-work declaration, not a claim that App Nap caused the measured delay.
[Apple activity API](https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)),
[user-initiated option](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/userinitiatedallowingidlesystemsleep).

Opt-in task-created/task-started events and an external runner watchdog target
the previously missed queue interval. It distinguishes a sampler still capturing
from one only processing symbols, and can add at most one late capture. Native
uptime, external observations, capture-completion-marker observation and process
reaping remain separate. Existing samples do not prove complete queue coverage or
identify a single blocking function. No deadline or physical-proof requirement
is relaxed.

The complete release lane explicitly disables external Host stack sampling for
its formal R4 acceptance, while the fast debug lane retains the bounded diagnostic
watchdog. Sampling and later symbol processing are additional work, so an
unmeasured perturbation must not be folded into a product timing claim. This
separation is not a same-build A/B experiment and cannot establish that sampling
or activity alone caused a timing difference. All real-input, identity, complete
physical readback, exact-focus and cleanup requirements stay identical.

Exact c64 cloud source passes180 Rust and225 Swift tests with one skip, including
all five new activity-lifetime tests. Both product lanes actually begin and end
their user activity. Fast's24 paired read tasks have a maximum queue175.466ms;
full's11 started tasks peak176.548ms, with one additional task never starting.
Neither record reproduces the earlier3s read-task queue, but neither completes R4.
Fast completes six witnesses and reaches exact focus, then its second focus
confirmation returns after the unchanged8s acceptance window has begun shutdown.
Both sibling windows remain visible. Its first-witness-to-next-witness interval
is2236.644ms; only394.112ms of recorded canary panel work is separately measurable,
so the remaining interval is not attributed to one native call or scheduling cause.

Full, with all four sampler reports explicitly disabled, instead rejects its
first witness after3990.683ms in `physical-window-observation`. The worker has only
READY/CLOSED; it has not begun canary, HIDE or target focus. Its later Dock-expiry
and shutdown records do not establish the earlier guard failure. The relevant
dynamic management predicate uses the existing12s catalogue age/3s sample-duration
check, not a hidden750ms Dock check. Host physical cleanup is confirmed in both
lanes. Full CI desktop cleanup is also confirmed; fast's separate created desktop
is retained because it is not independently confirmed empty, so whole-workspace
cleanup is UNKNOWN in that lane.
[Exact c64 cloud evidence](../verification/independent-stage/cloud-c64bf6d5-latency/README.md).

The c64 target Mac completes the full release/package/signature checks and all26
selected navigation tests. A new ordinary-desktop trial, with native Stage Manager
already off and no competing engine worker, passes the foreign-window engine.
Formal R4 has three ready fixture groups but issues zero inputs: its external
controller rejects `directAcceptanceParentUnconfirmed`. Cleanup confirms all
fixture returns and exits, the original desktop/foreground/preferences are
preserved, and hardware input is unchanged. A separate read-only self-process
probe demonstrates the concrete path mismatch: `proc_pidpath` reports
`/private/tmp/...` while Foundation reports `/tmp/...`, with identical device and
inode. The old controller compares those raw strings before its signature check.
[Target c64 results and the path probe](../verification/independent-stage/target-c64-runtime/README.md).

`60cf3219` carries the Host's already captured executable device/inode
into the R4 request. The R4-only verifier compares both canonical paths and those
fixed file identities; direct parent, process birth, live/disk signatures, the
acceptance marker and single-press deadline remain required. Its actual C
comparator passes13 filesystem cases on both the local executor and the target
Mac, including path aliases, redirection and replaced-file rejection. This does
not upgrade the old zero-input trial. Cached failure labels also distinguish the
existing witness, original-window reader and management checks, preserving their
short-circuit order and native query count. The target complete release build
(225.321 seconds), package and strict/deep signature pass. Cloud source passes
180 Rust and225 Swift cases with one explicit skip; the added C comparator
build and self-test exit successfully.

The60cf fast product issues one real R4 input but confirms no switch. Its
3,726.860 ms initial directory preparation includes804.559 ms waiting for the
older read. After a session is created, the signed-Dock observation expires and
revokes its Host revision and navigation intent. The next ordinary Dock result
cannot revive that old intent. The initial binding stage therefore rejects before
a backend launch; this is not evidence that `StageHostWindow.bind` itself failed.
Product and CI workspace cleanup both pass. The periodic Dock poll still starts
from an implicit-priority Timer task, independently of the navigation job's
explicit user-initiated priority. A pending-request timestamp must not be joined
to an unrelated later physical sample to infer a single request's queue delay.
[Exact60cf cloud evidence](../verification/independent-stage/cloud-60cf3219-latency/README.md).

On the target, a new60cf release run without Host sampling passes the corrected
parent/file identity boundary but remains BLOCKED before input: the external AX
tree becomes unreadable and the last window-list read returns AXCannotComplete.
The retained tree diagnostic is from an earlier traversal, not proof that the
panel disappeared. A subsequent, separately identified diagnostic run of the same
release binary with the existing sampling enabled issues one successful actual
AXPress. Its first directory preparation takes508.944 ms; the first physical
rebinding read then throws after40.141 ms, with total preparation563.380 ms.
The raw failure is `stagePhysicalReadRejected / final-continuity`. Its error type
places the failure after the focus check, within original number, forward Space
membership, raw inventory equality or native Stage Manager state; the current
receipt does not distinguish those four checks. No witness/backend launch or HIDE
is reached. All three original windows remain visible at home4 and exact target
focus is not confirmed. Both target runs independently confirm product/engine
cleanup, fixture exit and preservation of the original desktop, foreground and
preferences. Their direct engines fail the later yellow-button case, separately
from these R4 results.
[Target60cf without sampling](../verification/independent-stage/target-60cf-runtime/README.md).
[Separate target60cf diagnostic](../verification/independent-stage/target-60cf-diagnostic/README.md).

`6d058079` gives only the existing periodic Dock poll
user-initiated priority while navigation is dispatching, preserving its idle
priority, read cadence,750 ms bound and revocation semantics. Per-request timing
distinguishes creation, actual task start and the same request's physical
return. The physical reader's final continuity checks also receive cached,
short-circuit failure labels without additional native reads or weaker proofs.
The60cf full release runtime, with sampling disabled, issues one real R4 input.
It positively confirms exact target54 focus and the first sibling56 hidden in
Space34 with `onScreen=false`; sibling57 is still visible at home12 at the final
readback. Thus the complete switch still fails the unchanged eight-second bound.
All11 witness reads complete; the last is the fresh read preceding the second
sibling HIDE and finishes after shutdown has already begun, so the following
interruption must not be described as an earlier failed witness. Preparation
takes1,912.256 ms and the initial witness2,518.362 ms, while subsequent witnesses
are much shorter. The direct engine passes26 requests, and Host double physical
return and outer CI workspace cleanup both pass. The new source comparator's
original stdout confirms13 PASS, zero failures and zero window writes.

The6d05 native source gate passes180 Rust and227 Swift cases with one skip;
both new test functions pass, including both priority arguments and the bounded
in-memory inventory diagnostic. Its sampled fast lane issues two actual R4
inputs and completes the first full switch in7,442.021 ms: target54 remains
visible on home12 with exact focus, while siblings56/57 are independently
confirmed hidden in Spaces33/34 with their original frames. Its34 periodic
Dock polls created during navigation actually run at priority25, and neither
action is revoked by Dock ownership. The second action fails in the next
opening roster after the last successful witness sequence25; its current
directory revision68 returns successfully and is rejected0.373 ms later.
The full release, without sampling, fails at its first opening roster after
only912.271 ms from the actual press. Preparation succeeds in234.217 ms and
the directory read in517.407 ms, with no prior wait or ownership revocation.
Thus neither particular rejection is an eight-second timeout or evidence of
slow task admission. The failing snapshots' exact catalog/roster condition is
not yet captured; a later good snapshot must not replace it. All three direct
engines pass, and both products' physical cleanup and outer CI cleanup pass.
[Exact6d05 cloud results](../verification/independent-stage/cloud-6d058079-latency/README.md).

The target6d05 release build, package and signature pass, but both original
context receipts explicitly say `screenLocked=true`. The wrapper incorrectly
continued because its guard checked console/login and secure-input status
without that lock flag. The engine and product then correctly refuse useful
work: no engine window writes, no product directory snapshot and zero R4 input.
All fixture cleanup and original context checks pass. This is a locked-session
precondition failure, not a product scheduling regression. Subsequent target
orchestration now refuses a locked session and will not request foreground
restoration while locked. No unlock operation is attempted.
[Target6d05 original locked-session evidence](../verification/independent-stage/target-6d05-runtime/README.md).

The next implementation can reuse a pending directory result only when its
actual native start and wall-clock sampling start are both strictly later than
the current `readAfterAction` entry, with current session/epoch, complete uncapped
data and fresh evidence. It retains the real revision and the subsequent
independent reads. The60cf full trace contains a concrete candidate: revision3
starts native sampling31.402 ms after entry but the current code still performs
an additional861.340 ms fresh read. The old trace lacks its wall-clock start,
so this is potential avoided work, not a demonstrated speedup. Additional
cached roster-rejection facts will distinguish the actual opening-catalog and
membership conditions without adding native queries or weakening them.

Freshness limits are unchanged and distinct: Dock ownership 750 ms, catalogue
maximum age 12 seconds and sampling duration 3 seconds, and actual R4 physical-state
deadline eight seconds. No failed input is replayed. Formal R4 has not passed and
no release qualification has been granted. Current target attempts and the existing
controlled macOS cloud fixtures retain separate exact-source evidence.

#### Earlier target-engine and package checkpoints

The earlier completed source/full-package checkpoint is
`350e848cc30106c32156ddba2c222ab639ab141f`: **166 Rust /174 Swift pass, one explicit skip**.
Complete workspace, companion resources and strict/deep ad-hoc bundle signatures pass. The full,
fast and diagnostics VMs independently pass the normal foreign-window engine and cleanup. These
are hosted **27.0.1 /26A434 /SIP disabled** results, not target qualification.
[Full candidate and original result](../verification/independent-stage/cloud-350e-full/README.md).

The350e fast VM issues one confirmed AXPress, then a real native-context total age
of901.886ms withdraws dispatch before the group job or witness. The full VM stops
during external button discovery with AXCannotComplete/windowListRead=-25204,
before input. Both independently confirm cleanup. Their complete Host samples
identify repeated session reads during SwiftUI rendering, task identity and gallery
request construction. The following presentation correction reuses already observed
display/session/permission state for rendering while actual actions, capture and
pixel admission retain their fresh native checks. It does not widen750ms or
retry an already issued action. [Separate fast originals](../verification/independent-stage/cloud-350e-r4-fast/README.md).

The preceding8805 fast product input confirms the actual button's AXWindow is the retained panel, issues exactly
one successful AXPress and completes the first witness with three actual windows and three managed
members. The real Dock sample then arrives at total age 1133.81 ms, so ownership is withdrawn before
NP_LAUNCH. The full VM stops before input when its last retained-panel canonical identity read is
unconfirmed. Its original receipt lacks that inner call's error and does not prove a wrong window
or an AX timeout. Both product runs confirm cleanup; neither is a successful R4 switch.
[Separate fast originals](../verification/independent-stage/cloud-8805-r4-fast/README.md).

The new full Host samples retain the complete stacks. Fast has 10 of 86 main-thread observations
in the initial witness: opening-roster role reads, original-window binding and physical observation.
This identifies synchronous UI-actor work, not a quantitative allocation of the 1133.81 ms delay.
The Dock reader already runs on its own actor. The previous 3437 full sample independently identified
the two synchronous physical rebinding passes (104/114 samples), which 8805 moves off MainActor.
Fast already had bindings this time; it does not prove that cold rebinding was physically exercised.
Every await still rechecks current input/epoch, cancellation, directory and ownership before use.
Observed presentation state cannot replace a fresh permission check for actions or pixel
admission; original-AX checks and the750ms dispatch boundary remain intact.

The target Mac became reachable again on 2026-11-26 at 19:13 UTC. Its clean isolated clone was
fast-forwarded to 8805; the daily installation and working checkout were preserved. The actual
**27.0 /26A428 /SIP enabled** runtime created and independently verified three foreign windows.
Own-panel home discovery then obtained the same complete home4 at 3 and208 ms, but rejected the
second read against its120 ms discovery budget. There were **zero foreign hide/restore requests**
and no hidden Space creation. The original panel, fixture windows and Space inventory were
completely restored and both fixture processes exited normally. This is an executed pre-migration
engineering blocker, not a negative hidden-Space API result. The next source correction separates
own-panel discovery timing from real mutation acknowledgement and adds actual phase durations.
[Target originals and exact hashes](../verification/independent-stage/target-8805-panel-home/README.md).

The follow-up `350e848cc30106c32156ddba2c222ab639ab141f` now **passes the complete
normal foreign-window engine on the actual target27.0 /26A428 /arm64 /SIP enabled**.
It obtains34/34 verified receipts,10/10 checks and26 actual hide/restore requests across
two independent fixture apps/three windows: same-app independence, cross-app combinations,
three A→B→C→A cycles, first and later yellow actions and exact focus. First release returns
owned0; two complete final reads restore every original frame/home and the exact16-entry
Space inventory. Both fixtures exit0. The first and later yellow actions finish two
complete hidden/offscreen/nonminimized reads at925/927ms. Own-close actually encounters
Readback217 and recovers inside its existing observation loop.166 Rust regressions also
pass on this target, and the separate350e cloud source run passes166 Rust/174 Swift, one skip.
[Decisive SIP-enabled foreign-engine originals](../verification/independent-stage/target-350e-engine/README.md).

This confirms the route's foreign-window mechanism on the requested target, without claiming
all third-party applications or the formal R4 path. A second350e product invocation finds the
console locked with loginwindow foreground and correctly performs zero foreign moves. Its
product preflight also exposes Foundation canonicalizing existing output to/tmp while an
absent profile's parent remains/private/tmp. Canonicalizing both real parents fixes that
read-only configuration error; exact PID and directory scope constraints remain. The original
blocked invocation stays blocked and its fixture cleanup succeeds. No locked-session UI input
is attempted after that condition is identified.
[Separate original blocked run and path/console probe](../verification/independent-stage/target-350e-product-preflight/README.md).

Committed6e5b205d isolates retained original-AX reads from the UI actor. A narrow
immutable AX receiver crosses executors, while the mutable owner, monitor and writers remain
on MainActor; per-window read/write phases exclude concurrent native access. All original
window/owner/lifetime/claim/home/lease/permission checks remain before and after awaits.
Initial role enumeration, initial binding's full read and ongoing observations use this path.
The input helper now logs exact canonical read errors and may rediscover only an explicitly
incomplete pre-action read in its original6s budget; no issued action is repeated. These
source changes still require their own Swift code-generation and actual product results.

The existing lifecycle experiment now creates a window that has never been captured, selects a
real R4 card to hide it, then enables pictures within the original five-second pending interval.
A cold-preview PASS requires the original real held image and two physical reads of that same
hidden Space before any restore; blank images or a later successful restore cannot qualify it.
Main R4, crash/restart, cold-preview and lifecycle prerequisites remain separately NOT_RUN until
executed. Their completed source code is not promoted into a native result.

### What is established

1. At `9509bd0`, Nearpane's own panel entered hidden Space 5643 and returned to ordinary desktop 4 on
   macOS 27.0 / 26A428, SIP enabled. Dual membership reads, destruction and cleanup were recorded.
   [Original experiment](../verification/window-engine/single-version-26A428/RESULTS.md),
   [raw panel cycle](../verification/window-engine/single-version-26A428/11-formal-panel-cycle.json).
2. That run executed **zero third-party window actions**. Its admission/Host restrictions blocked them.
   Subsequent unexecuted trials are not a negative WindowServer result.
   [External admission](../verification/window-engine/single-version-26A428/11-external-admission.json).
3. Upstream has advanced from the fixed v1.9.1 through v1.9.2 to **v1.10.0**,
   `204d8de1ac2b682d147389c31a07b0a485ef9368`, published2026-11-26 at17:23:02UTC.
   The actual118-file incremental diff has been audited. Hidden bridge/create/destroy/masks,
   engine selection and own-panel probe semantics are unchanged; notification and Cmd-Tab
   ordering changes supply specific compatibility cases, not a new renderer-decoupling route.
   Corner screenshot/cover performance claims are not imported into Nearpane.
   [Release](https://github.com/eugene-tea/stage-manager/releases/tag/v1.10.0),
   [fixed incremental audit](INDEPENDENT-SPACES-SOURCE-AUDIT.md#v1100-delta-audit).
4. Its hidden-Space route uses `SLSSpaceCreate`, bridged add/remove (`options=7` to hide,
   `options=0xf` to return), `SLSCopySpacesForWindows`, reverse membership and `SLSSpaceDestroy`.
   `SLSBridgedMoveWindowsToManagedSpaceOperation` serves ordinary managed-desktop movement; it is not
   interchangeable with the hidden-Space add/remove route.
5. Upstream's launch probe tests its own window, its engine selection can fall back to Corner, and
   some Mission Control/activation handling temporarily parks windows in a corner. None of those is
   inherited as product success or as a fallback. The useful v1.9.2 fixes concern home-desktop identity,
   lifecycle, reactivation and display topology; their mechanisms need individual adaptation.
6. This repository previously set the product Spaces route to unavailable and selected Corner only.
   The candidate constructor, transport, Core session, independent physical witness and R4 Host now
   have an explicit Spaces path. A successful launch still does not qualify a foreign window.
7. At `bdedf131c94a85621cd24b8969ebbb3564afe0b1`, the production platform atoms moved two windows
   belonging to two separate fixture processes from ordinary Space 12 into hidden Space 13 and back.
   All four moves passed two complete physical observations of all three fixtures; the same-app sibling
   remained at home. The hidden Space was confirmed empty, destroyed, and the original Space inventory
   restored. [Original foreign-window evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
   This establishes foreign-process hidden-Space movement on **26A434 / arm64 / SIP disabled**. It does
   not qualify the target SIP-enabled Mac, the Rust state machine, or R4. The normal engine controller
   stopped before its canary because the controlled fixture did not become foreground. Separately,
   removal of the CI-created ordinary Desktop 12 was not confirmed in that run; overall cleanup is not
   promoted by the successful hidden-Space transaction.
   The `e630b6bc` diagnostic independently repeated both foreign cycles on the original ordinary home 1,
   through hidden Space 12, with confirmed cleanup and **zero ordinary-desktop initialization inputs**.
   [Replication and full artifact reference](../verification/independent-stage/cloud-e630b6bc-diagnostics/README.md).
   This removes dependence on the CI bootstrap from the platform mechanism result, without assigning a
   synthetic ordinary UUID or promoting it to a state-machine/product qualification.
8. At `5607d3b3cddc6711514b16ce3fc7f431b03cd7db`, the normal candidate Rust engine itself passed
   its own launch canary, the independently observed foreign-window round trip, same-app separation,
   and a visible cross-app combination. This is stronger than the earlier platform-only result.
   Repeated switching then failed because the common receipt layer treated the Spaces session's
   aggregate `OWNED` flag as if the restored target were still hidden. The backend had recorded
   `ShowVerified`; another group's member remained owned. The corrected receipt contract retains
   that other member's ownership while accepting the target's verified home return. The original
   run remains a failure, with nine hide/restore request attempts including a later rejected cleanup
   request; its R4 path was not executed. [Normal-engine evidence](../verification/independent-stage/cloud-5607d3b3-full/README.md).
   A separate `afa7b8f8` run reached the canary but returned membership detail 207. The omitted
   upstream own-panel `CATransaction.flush()` has been restored and conditional phase diagnostics
   added; neither change is claimed to have resolved that run before a new physical result exists.
9. The subsequent `bbc08a09` normal-engine diagnostic passed its launch and all three A→B→C→A
   cycles, including 22 verified hide/show requests. The aggregate-ownership correction is therefore
   physically exercised. Yellow-button adoption was then refused because an earlier health read had
   already stopped scheduling; release failed an AX/minimized-state read and a same-app sibling
   remained in hidden Space 24. This is a real cleanup failure, not a reporting-only issue. The original
   failure and retained window are preserved in [the diagnostic evidence](../verification/independent-stage/cloud-bbc08a09-diagnostics/README.md).
   Precise health/AX diagnostics and bounded release retries retain the original lease and never
   substitute an unknown attribute with a false value. The separate full `81669d13` R4 run confirmed
   a complete catalogue, three distinct groups and the visible formal panel; its button search still
   stopped before any R4 input. Neither result grants a complete product or target-machine qualification.
10. Launch is not yet stable across hosted runs: the separate bbc full VM and the next `3bcb0640`
    diagnostic passed own-panel hidden-view but could not confirm the initial return. The latter's
    bounded, same-engine release completed physical cleanup, with zero foreign requests. Source
    audit identified an error classification defect: an unavailable or inconsistent CG observation
    was called Identity, prematurely ending the existing readback loop. The adapter now distinguishes
    Readback from a positively different PID/birth/window/original witness. It still requires two
    positive observations within the original deadline and never repeats the move. More precise
    diagnostics accompany this correction; its role in the observed failure requires a new run.
11. The `1d7402d4` diagnostic again passed launch and three full group cycles. The actual minimized
    request returned MinimizedOrAX before its precise failing precondition was recorded. Cleanup
    exposed a real, temporary AX CannotComplete on the original hidden A1 object; a second release
    on the same engine completed all physical restoration and destruction checks. Yellow behavior
    remains failed. Separately, the full `3bcb0640` product received its first real R4 AXPress, but
    subsequent state did not confirm a switch and no worker/WAL was created. Product entry and
    minimum-state diagnostics are being completed; neither input success nor recovery success
    substitutes for successful R4 scheduling.
12. The `32f22cd4` trace identifies the earliest yellow-time health fault: the original hidden A1
    object reports AX CannotComplete and is immediately latched restore-only. The subsequent
    correction preserves this specific AX error across C/Rust and retries only its observation,
    on the same witness, within the original 650 ms budget, requiring two complete positive reads.
    Positive changed state remains a fault. The next `33d65484` diagnostic actually recovered
    from that error with two complete reads, without latching the engine or repeating a move.
    Yellow adoption then reached its original binding checks and exposed a different, precise
    problem: the actually minimized window no longer reported the standard AX subrole. This
    is not an absent window or a failed hidden-Space operation. The next implementation retains
    the original standard AX object for every visible participant, including the active group
    before its first hide, and carries it through restoration. An actual minimized state on that
    same lifetime may admit a temporary subrole transition; a newly discovered unknown or
    dialog window cannot. Native validation must include yellow both before and after normal
    group switching. [Original health and binding evidence](../verification/independent-stage/cloud-33d65484-diagnostics/README.md).
13. The full `33d65484` candidate passed 155 Rust and 162 Swift cases, with one explicit Swift skip,
    the complete app build, and its strict bundle signature. This VM also passed launch and three
    normal-engine group cycles; yellow failed and cleanup passed. The R4 external client's actual
    AX reads timed out before it issued an input: `actualR4Inputs=0`. That cannot be called a failed
    handler or a successful product switch. Bounded external discovery now replaces the ineffective
    wait on the local hosting view's empty child list. [Original candidate and input receipts](../verification/independent-stage/cloud-33d65484-full/README.md).
14. The next `3e197761` diagnostic confirmed all six initial foreign-window readback registrations:
    three windows, two positive samples each, flags 45 and zero hidden ownership. The first current
    window, before any HIDE/SHOW, retained the exact original AX object through minimization. Its
    actual temporary subrole was **AXDialog**, which the initial AXUnknown allowance rejected.
    No foreign mini move was issued and cleanup passed. The narrow follow-up permits that observed
    dialog state only on the already registered standard object with the same positive identity,
    true minimization and false fullscreen checks. Newly discovered dialogs remain ineligible.
    [Original registration, subrole and cleanup receipts](../verification/independent-stage/cloud-3e197761-diagnostics/README.md).
15. The `44bc3759` diagnostic accepted that actual original-object AXDialog transition, moved the
    minimized foreign window into hidden Space 15 and passed the engine's hidden-membership check.
    After one AX deminiaturization request, its reused 120 ms Space observation deadline expired
    during real minimized/AXCannotComplete observations. Cleanup passed; the first yellow operation
    still failed. The follow-up separates the AppKit completion observation into a 650 ms budget,
    keeps the same witness and single write, and stops on any positive return to the original home
    or another Space. [Original boundary and cleanup](../verification/independent-stage/cloud-44bc3759-diagnostics/README.md).
16. In the separate full `44bc3759` VM, a real R4 AXPress reached current-card selection, the fresh
    complete group directory, worker creation and a configured session. All three actual window
    previews rendered. Activation then returned incomplete before any NP_LAUNCH reached the worker;
    physical windows stayed at home and cleanup passed. This narrows the failure to the initial
    Swift witness/prelaunch boundary, not the hidden-Space API. Read-only phase diagnostics now
    distinguish original binding, AX/CG geometry, membership, actual focus and a successfully
    returned witness from later coordinator checks. [Original product, worker and screenshot](../verification/independent-stage/cloud-44bc3759-full/README.md).
17. At `48c2ab44`, yellow's one deminiaturization request produced forward memberships `[15,16]`
    while original hidden 15 still contained the window and home 12 did not. The previous rule
    stopped on any extra membership after about 54 ms. This does not prove desktop escape or the
    type of Space 16. The next implementation observes the complete managed catalogue and every
    managed reverse membership. Additional non-managed membership remains unfinished, never PASS;
    actual managed membership or loss of the original hidden membership stops. Final completion
    still needs two original-witness samples with exclusive original hidden membership, true CG
    invisibility, unchanged frame and minimized=false, with no repeated move or AX write.
    [Original membership and cleanup evidence](../verification/independent-stage/cloud-48c2ab44-diagnostics/README.md).
18. The full `48c2ab44` R4 trace identifies `focused-window-identity` as its first failed physical
    read: the actual front process was Finder, whose focused object was AXScrollArea with no CG
    window number. No NP_LAUNCH occurred. The source correction requires the exact system Finder,
    an original AXScrollArea whose parent is that application, a positively absent containing
    window and its exclusion from the complete AXWindows list. The same original AX element and
    process generation must persist. Unknown focus is not converted to desktop focus. Swift and
    the C canary use this same positive structural proof; the next native run must establish that
    the observed object actually has this structure. [Original exact phase](../verification/independent-stage/cloud-48c2ab44-full/README.md).
19. The `b43d5a93` diagnostic positively excludes the extra Space 16 from the complete managed
    catalogue and reports raw type 3. During the actual system animation the window is temporarily
    CG-onscreen with changing geometry; those samples are not hidden PASS. By 621 ms the observed
    fields have converged to exclusive hidden 15, offscreen, original frame and minimized=false;
    the next observation at 653 ms exceeds the then-current 650 ms budget, so the operation still
    fails. The following source gives this active completion 1000 ms for the measured animation
    and two complete original-witness reads. Health remains 650 ms and Space acknowledgement
    120 ms, with no repeated write or relaxed final state. [Actual convergence and failed operation](../verification/independent-stage/cloud-b43d5a93-diagnostics/README.md).
20. The `b43d5a93` early source run passes 160 Rust and 169 Swift cases, with one explicit skip.
    Its separately labelled foundation/debug R4 run receives a real press but loses dispatch
    eligibility and its navigation epoch while awaiting native system confirmation, before the
    group-choice Host or worker starts. It does not exercise the Finder correction. The next
    read-only trace records the actual Dock reading interval, reason and ownership transition;
    the 1.265-second interval alone is not sufficient to infer a cause. [Original fast-run boundary](../verification/independent-stage/cloud-b43d5a93-r4-fast/README.md).
    The complete release build independently reproduces the same pre-worker withdrawal during
    a 1.400-second system confirmation, with three real previews subsequently rendered and cleanup
    confirmed. Build and strict bundle verification pass; product scheduling does not.
    [Complete candidate and separate release receipt](../verification/independent-stage/cloud-b43d5a93-full/README.md).
21. The `9cec081f` normal-engine diagnostic passes every required engine check on the **same**
    26A434/SIP-disabled VM: initial visible registration, the first never-hidden window's real
    yellow button, third-party round trip, same-app separation, cross-app combination, three full
    B/C/A cycles, the later yellow button and focus. Its 34 operation receipts are verified,
    including 26 actual hide/restore requests. The first/later minimized completion each obtains
    two full original-witness observations at 700/654 ms. The first release returns every surviving
    window and restores the full original Space inventory in two reads. This is actual
    `FOREIGN_ENGINE_PASS`, not inference from a successful CI job. It still supplies no R4 product
    or target-SIP-enabled qualification. [Original complete engine result](../verification/independent-stage/cloud-9cec081f-diagnostics/README.md).
22. The `9cec081f` complete release independently passes source, build, signature and normal-engine
    checks. Its real R4 press passes the signed-Dock check in 12.09 ms, reaches the worker and
    identifies a different Finder desktop representation: the top-level AXScrollArea is included
    in the full AXWindows list and AXWindow returns another AXScrollArea reference. The old
    unlisted/empty predicate rejects it. Self equality and exact list count are not established
    in that original receipt. The next Swift/C branch requires actual CFEqual to the original
    object and exactly one occurrence before recognizing this listed form.
    [Original actual structure and complete candidate](../verification/independent-stage/cloud-9cec081f-full/README.md).
23. The separate `9cec081f` debug run stops before input: the final button attributes return
    **AXCannotComplete (-25204)**. It does not prove a replaced SwiftUI object. The next helper
    batches the same six attributes, preserving per-field errors and all identity/frame checks;
    only a still-unissued transient read may rediscover within the original six-second budget.
    AXPress remains a single, non-repeated action. The acceptance's synchronous native readback
    also moves off the UI actor, with immutable samples and read/delivery timestamps, so testing
    does not itself occupy the actor being measured. This is a confirmed source isolation issue,
    not proof that it caused the older b43 timing failures.
    [Original no-input result](../verification/independent-stage/cloud-9cec081f-r4-fast/README.md).

Cold Host startup now has a read-only reconciliation path for a completed Spaces worker. A durable
record binds the original owner, nonce, boot, Host and worker generations before the first launch.
On the same boot, exact worker destruction and both process exits precede two independent window/home
and hidden-Space observations; only then can the old ledger be retired. A positive new boot separately
retires the former WindowServer's authority. No saved CG number recreates an old AX writer. The unified
crash test includes same-profile relaunch and another real R4 selection; implementation and actual
restart acceptance remain distinct until that path runs.

An explicit current R4 card click can establish new session bindings after that old authority has
ended. It first obtains a fresh complete ordinary-desktop roster; if any live participant needs a
new binding, two independent physical reads validate the entire current scope before atomically
binding its new lifetimes. A partly present saved group is rejected without partial mutation;
wholly absent historical groups are retained. The same click then continues through normal group
selection. An already bound click keeps its fast path. A missing current group projection no longer
silently downgrades a Spaces selection to ordinary focus. This source path still needs its own
real R4 input and physical scheduling receipt.

### Route A: not a product dependency

The discovered Apple integration follows existing native thumbnails through AX/gesture routes.
It does not independently disable their rendering and edge activation. Apple's documented recent-app
setting still allows edge reveal. An AX action's success return does not prove a group changed; upstream
has recorded successful-return/no-effect cases. These mechanisms cannot satisfy the product contract.

This evidence does **not** establish that a private decoupling mechanism can never exist. The remaining
question is executable research, isolated under [native-stage-decoupling](../../tools/native-stage-decoupling/README.md).
Its runtime/selector inventory and reversible edge sweep classify contrary observations as REJECTED and
missing evidence as INCONCLUSIVE; absence of AX nodes is never a decoupling PASS. Product code has no
dependency on a hypothetical strip-suppression interface.

The Pro session has now executed the read-only inventory on the actual 27.0 / 26A428 / arm64 / SIP-on
Mac. SkyLight, WindowManagement and WindowManager loaded; 394 runtime classes and the inherited
bridged-operation ABI were recorded. The two migration operations are Objective-C classes, not C
symbols. The asynchronous `performWithWMBridgeDelegate` returns void and takes no explicit argument;
the synchronous superclass method returns an object. Swift strip-gesture/layout symbols were present,
but no callable rendering/edge-suppression separation was proved. Preferences were unchanged throughout.
[Machine receipt](../../tools/native-stage-decoupling/evidence/macos-27.0-26A428-inventory.json).

Hosted controls now provide actual negative evidence for two concrete renderer hypotheses.
At `a73454a1` on macOS 27.0.1 / 26A434 / arm64 / SIP disabled, both `AutoHide=true` and
`LeftStripMaximumRowCount=0` produced native tilted thumbnails corroborated by AX members,
onscreen CG surfaces and captured pixels. AutoHide exposed them on left-edge dwell; the zero-row
setting left them rendered even at baseline. Each experiment retained 13 observations and restored
preferences, fixtures, pointer and foreground. [Original receipts and two decisive crops](../verification/independent-stage/cloud-a73454a1/README.md).
This rejects those two configurations, not every possible private separation mechanism and not a
substitute for a 26A428/SIP-on acceptance result.

## Runtime and system coordination

- The engine owns only the precise windows it enrolled. The original ordinary desktop is retained for
  each hidden member; hidden-Space IDs never replace the user's ordinary-desktop identity.
- Each actual move must be read back through both space membership directions and independent CG/AX
  visibility and geometry. No API status, mock, own-window probe or CI compile substitutes for that readback.
- The ordinary catalogue can still see a hidden window in CG's all-window list. It excludes that row only
  after two inclusive membership queries agree on exclusively non-managed Spaces, reverse membership
  confirms the exact window, and both CG observations are offscreen. Missing/empty membership alone
  remains incomplete. This prevents the Host from revoking its own correct hidden group while retaining
  all ordinary-desktop and window-identity requirements.
- CG's all-window list also contains allocated, unmapped surfaces. A separate exclusion requires two
  actual empty inclusive Space arrays and two complete CG onscreen, AppKit active and AppKit all-Spaces
  inventories that all omit the unchanged PID/birth/window identity. A missing CG `IsOnscreen` key is
  unknown, never false; an independent complete onscreen enumeration supplies negative evidence.
  This only excludes a surface from that sample's work-window roster. It cannot retire an owned window,
  release an AX lifetime or clear recovery ownership.
- Restore first; then destroy only an empty owned Space. Partial/uncertain moves retain recovery ownership.
- System overview handling returns windows to their real ordinary desktop and does not park them in corners.
  Fullscreen and native split windows remain outside ordinary group management.
- Blank-desktop reveal keeps inactive groups in their real hidden Spaces while pausing new group,
  arrival and minimize actions. It does not return hidden windows into the native reveal animation.
  Fresh ordinary-context and two physical visibility reads reopen scheduling; this grants no focus
  transfer. An actual desktop change, native overview or session suspension still returns ownership
  to the system even if wallpaper reveal had already paused dispatch.
- Returning from system navigation resumes the group of the independently verified focused window in the
  same serialized R4 action lane. A newer input supersedes it. Retained read-only AX objects reconnect
  ordinary sidebar appearances after two observations; old file leases are released before reacquisition.
- Restore preserves geometry and reads the current WindowServer stacking order. A group keeps its last
  visible order; only a changed order causes exact-window focus/raise operations, ending with the selected
  member. This implementation still requires physical group-order verification.
- Cached thumbnails retain the original window lifetime. They are pictures of actual windows, not a masking
  mechanism. A stale picture cannot authorize a new window mutation.

## Verification and delivery

Unified entry: `python3 scripts/acceptance/independent-stage/run.py OUTPUT --scope all`.
The source phase compiles/tests Rust, Swift Core/Host/UI and the C ABI. In `--scope all`, the same entry
then builds the complete embedded application, seals its separate workspace package, and supplies the
full application to product acceptance. The runtime phase
creates two independently owned fixture applications, one with two windows and one with one window,
and verifies foreign-window hide/return, bystanders, same-app independence and recovery. Product R4
acceptance is recorded separately; it may not be inferred from the low-level trial.

Results are appended here and under `engineering/verification/independent-stage/` after execution.
The target foreign engine and its yellow actions now have completed350e receipts. Formal R4,
native overview, physical gestures, product yellow routing and crash/lifecycle paths remain **NOT_RUN**
until their own completed results exist; engine-only evidence does not qualify them.

No unsigned/ad-hoc remote candidate is advertised as a notarized install. Existing signatures, installed
daily builds and uncommitted work in other checkouts are preserved.

### Executed checkpoints

- macOS source checks: the 147 Rust cases passed on the target Mac and on the hosted macOS runner.
  A synthetic own-panel wait originally depended on wall-clock CPU scheduling; its fake clock is now
  deterministic while the real 120 ms deadline is unchanged. Swift production modules and the complete source-check step then passed at `2a0cfbe9`. The complete
  embedded release also compiled and passed resource verification; the later workflow signature check
  incorrectly treated the Host inside its resource-bearing bundle as a standalone executable. The
  corrected whole-bundle package verification passed at `283831ef`, including the sealed native
  worker and complete workspace ZIP. Original receipts and checksum are in the evidence index.
- Hosted `283831ef` runtime stopped at the ordinary-desktop preflight before canary/enrollment;
  foreign writes were zero and fixtures exited normally. Product investigation found an obsolete
  exact-build read gate and a managed-only membership query in its physical witness. The read shim
  now attempts current arm64 Darwin 26 ABI-family symbol/shape reads, and the physical witness uses
  mask 15 to include classic hidden Spaces. Write qualification remains independent. Subsequent
  diagnostics distinguish the raw native topology, C parser refusal and product cleanup result.
- Hosted `85762ae0` passed source, full workspace packaging and strict/deep signature verification.
  Its raw WindowServer dictionary proved a real GUI with a single initial ordinary desktop whose
  native UUID was empty. Foreign writes remained zero; product cleanup now passed independently.
  [Original terminal receipts and candidate](../verification/independent-stage/cloud-85762ae0/README.md).
  The next CI-only preparation uses actual Finder/Mission Control/Dock operations to initialize a
  native desktop, never a generated identity. An uninitialized inactive desktop may remain in the exact
  topology but cannot become the current or retained home. Target-machine runs do not perform this CI setup.
- The first target runtime at `da51f75` obtained AX permission and independently read three real windows
  in two fixture processes twice. `NP_LAUNCH` then stopped with detail 217 before any third-party write.
  [Original receipt and log](../verification/independent-stage/target-da51f75/README.md).
- The controller's event-loop defect was reproduced with the same own-panel code: manual run-loop pumping
  failed preparation, whereas a real `NSApplication.run` succeeded at prepare/open/read/close. A subsequent
  main-queue reentrancy issue was corrected by running the controller scenario on a worker and reserving
  the main queue for AppKit. These are harness defects, not negative foreign-window migration results.
  [A/B receipt](../verification/independent-stage/target-own-panel-runloop-20261126.json).
- Hosted Actions uses macOS 27.0.1 / 26A434 with SIP disabled. Its source/build and available GUI receipts
  are useful but cannot substitute for the target 27.0 / 26A428 / SIP-on result.

The definitive latest result and candidate commit will be recorded in
[`engineering/verification/independent-stage/`](../verification/independent-stage/) when the running
source, full-package and controlled foreign-window experiments complete.
