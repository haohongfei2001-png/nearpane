# Exact 60cf3219 cloud R4 evidence

**Terminal status: source PASS; fast and full each record one actual R4 input and zero confirmed selections, so both product lanes FAIL. Full performs one actual foreign-window HIDE and confirms exact focus before the incomplete selection times out. Both lanes confirm Host physical return, fixture cleanup and CI-created desktop removal.** Direct-engine success remains separate from complete production R4 acceptance.

Revision `60cf3219901c6997db400a1d08e143ddd011d0a0`, tree `92e4ac09c00c84c445fb23c18f978924316f87ad`, original PR #16 branch. [Workflow run 46042606128](https://github.com/haohongfei2001-png/nearpane/actions/runs/46042606128), run number 56, created `2026-11-27T17:32:12Z`.

These are cloud build `26A434` / SIP-disabled receipts, separate from the exact target-Mac run. New path-identity code and four-layer failure labels do not relax input, ownership, freshness or physical-readback requirements. This record does not claim that adding user activity established the cause of any earlier scheduling delay.

## Actual source gate

[The source summary](source/summary.json) reports **180 Rust tests PASS; 225 Swift tests PASS and one skipped**. [The Swift log](source/swift.log) ends with 226 tests in 34 suites passing after **6.585 s**. The four-layer diagnostic code is therefore native-compiled in this source gate; the fast Host build also succeeds.

The source summary records **`r4FileIdentityBuild=PASS` and `r4FileIdentity=PASS`, both exit 0**. The terminal full artifact now supplies [the original C stdout](source/r4-file-identity.log): **13 passed, zero failed, zero window writes**. Raw Rust stdout/stderr and all six C build/test process files are also preserved. Other source evidence, worker build/protocol, native diagnostic and read-only context checks pass. Source tests do not execute formal product R4 actions.

## Native lanes

| Lane | Direct engine | Formal R4 | Cleanup |
| --- | --- | --- | --- |
| diagnostics | `FOREIGN_ENGINE_PASS`, 26 request attempts | `NOT_RUN` | Engine and CI workspace confirmed |
| fast, sampling enabled | `FOREIGN_ENGINE_PASS`, 26 request attempts | `FAIL / R4SwitchReadbackFailed`; one actual input, zero confirmed selections | Host, fixture and CI workspace confirmed |
| full, sampling disabled by request | `FOREIGN_ENGINE_PASS`, 26 request attempts | `FAIL / R4SwitchReadbackFailed`; one actual input, zero confirmed selections; one observed foreign HIDE with exact target focus | Host, fixture and CI workspace confirmed |

The engine request counter includes rejected or unverified requests by its declared scope; it is not a successful R4-action count. Neither completed lane uses a platform-only fallback. See the original [fast engine result](fast/engine-result.json), [diagnostics engine result](diagnostics/engine-result.json), and [fast Host product result](fast/product-result.json).

### Fast failure and actual input

The original helper confirms a real external AXPress at native uptime **438.475886375**. The product records one input for the first singleton selection. Its first witness rejects at **443.6609081667** after **1,051.380 ms**, at **`initial-window-binding`**, window 58/PID 9316, with **bindings=0, claims=0, sequence=0**. No complete selection is confirmed. This is earlier than the physical-window-observation boundary diagnosed in the preceding c64 full lane; new physical-await labels must not be invented when that phase was never reached.

The last acceptance read still finds all three fixture windows visible on home 12. Focus is not verified: expected PID/window are 9119/55, while the front process is PID 374. Seeing the expected window number in a background process does not establish exact foreground focus.

One Activity begin/end pair is recorded for job `67BC7DB4-06FB-4C3D-A2E4-0A3BA181A52D`, beginning at **438.512959375** and ending at **443.70585375** with `completionHolds=1`. Group activation returns `interrupted` at **443.6614208333**, before acceptance shutdown starts at **446.79340125**. The activity ends after its work/release tail rather than remaining open until the later acceptance timeout. [The fast timing analysis](fast/timing-analysis.json) records preparation at 3,745.496 ms, then saved Dock observation expiry at 442.786771 and ownership withdrawal at 442.787034, before the initial binding rejection. The source causal chain revokes the old Host revision token on takeover. The broad initial-binding label cannot distinguish a preceding lifetime failure from its separate strict ordinary-permission check; an absent guard field is not a passing check. A pending request followed by a later published read is not treated as the same request without correlation evidence.

### Fast cleanup

The raw Host result records shutdown `released=true` after **5.045875 ms**, `cleanup=true`, and two successful physical return observations for all fixtures on their original desktop. [Fixture quit receipts](fast/fixture-cleanup.json) record both exit 0. [CI workspace cleanup](fast/ci-workspace-cleanup-receipt.json) separately confirms the temporary desktop was removed and the original desktop restored. These cleanup confirmations do not establish a completed product hide/restore transition.

### Fast sampling limits

The actual-press and group-preparation samplers have separate trusted trigger receipts and share one physical `host-main-thread.sample.txt`, with explicit `sharedWith=host-main-thread`. The main sample and raw sampler stderr are retained. The late read-queue sampler records **`NOT_RUN / noObservedR4ReadQueueDelay`**; this is the absence of its qualifying observed trigger, not a product PASS.

The main sample's capture progress markers are observed by the runner at monotonic **439.487951291** and **442.720628458**. Reaping occurs later at **447.406270833**. These are runner observations, not interchangeable with source uptime or exact native capture boundaries; reaping is not capture completion. Startup metadata/stderr are retained, while the startup sample text remains in the artifact with its SHA-256 recorded in provenance. Full records `hostSampling=disabledByRequest` in runtime/derived policy, with all four sampler metadata files `NOT_RUN / diagnosticsDisabled` and no sample text. The raw Host product result is unchanged.

## Full: actual first HIDE, incomplete selection, confirmed return

[The original full product result](full/product-result.json) records one actual input and zero confirmed selections. Its last physical read at uptime **1064.9952513333** proves window **56/PID 37234** is hidden in **Space 34**, while target **54/PID 37234** remains visible on home 12 with **exact focus=true**. Window **57/PID 37289** is still visible on home 12, so the whole R4 selection correctly remains FAIL.

The Host trace contains **11 completed witnesses** and no witness/physical rejection labels. The initial foreign HIDE has independent/Host readback evidence; the following work is still incomplete when acceptance starts shutdown at **1065.0749032917**. Activation returns `interrupted` later at **1065.17666275**. This must not be described as only a focus operation: a real foreign-window hide has occurred. Detailed phase attribution beyond these verified events may be added separately.

The Activity for job `4DB89A7D-7B13-4174-8D19-DABBE8BB1A6C` begins at **1056.8934095** and ends once at **1065.402086** with one completion hold. Shutdown returns `released=true` after **389.522167 ms**. Two physical return observations confirm all three fixtures visible on original home 12 with preserved frames; product cleanup, fixture quit and CI workspace cleanup all succeed. The full direct engine separately records PASS/26 requests/cleanup=true. [The candidate receipt](full/candidate.json) confirms full build and bundle signature PASS.

The unsampled full release and sampled fast debug lanes are separate runs, not a controlled sampling A/B experiment. Partial first-HIDE success and later cleanup do not establish a complete production group switch.

## Provenance

[provenance.json](provenance.json) records exact source revision, workflow/job/artifact IDs, archive sizes/hashes and each copied original's archive entry, size and SHA-256. ZIP sizes/hashes and head identity were verified before extraction. Raw Host product results and runtime-derived summaries remain separate byte-for-byte files. No binaries or candidate archives are checked into this directory.

| Artifact | Job | Artifact ID | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| source context | 140653851303 | 15221467113 | `76e80574bcc75ecb3de1208dd88242ae8239a7ed2918b93a31714f244fdb92ac` |
| fast | 140653851757 | 15220648077 | `4212971a0d5e92bbf11c12314b2a44db63861887cbace62bf95cdd356ba107dd` |
| diagnostics | 140653851735 | 15220932180 | `6025f371221c1c9787c9768457cd3f3e5069f92657297a07fd436cbf1c39ef6c` |
| full | 140653851303 | 15221528544 | `7aa58e9eb6ded98905072784088a25e78c51e99e851a0087a5fe22f0f4095d53` |

## Outstanding evidence

1. Keep the now-terminal exact-head originals fixed while evaluating the next source changes. Optional later phase analysis must remain labelled as derived and must not rewrite these outcomes.
2. Attribute the initial binding failure from the observed preparation, task and available guard evidence without assuming it is the preceding lane's physical-await failure.
3. Demonstrate consecutive actual R4 selections with foreign-window HIDE/SHOW and exact focus, followed by confirmed cleanup. Partial source or engine success does not pass this product gate.
4. Keep target-Mac panel-input and engine-yellow-button failures in their separate target evidence directory.
