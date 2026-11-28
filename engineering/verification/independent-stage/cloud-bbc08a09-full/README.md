# Complete candidate built; this VM did not pass its launch canary

These are byte-for-byte originals from the **full** lane of [run 45706743845, job 139530560800](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/job/139530560800), revision `bbc08a09aef3fa1387a76f1e30f97e437e0f42e9`, [artifact 15066931486](https://github.com/haohongfei2001-png/nearpane/actions/runs/45706743845/artifacts/15066931486). This was macOS 27 build **26A434, Apple Silicon, SIP disabled**, not the user's 26A428/SIP-enabled target. The diagnostics lane used another VM; its successful foreign group cycles must not be substituted for this lane's results.

## Source and complete package

The source receipt records **151 Rust tests and 156 Swift tests passed, with 1 live-fixture Swift skip**. Evidence checks, native diagnostic checks, Spaces worker build and protocol self-test, and the read-only context probe also passed.

The complete candidate build step succeeded. At this fixed revision, that step packages the full application and executes `codesign --verify --strict --deep` before producing the candidate receipt and ZIP. The original receipt records `sourceChecks`, `fullBuild`, and `bundleSignature` as `PASS`. This is a successful CI signature verification, not a claim of notarization or a signature check performed on this Linux review host.

The ZIP was downloaded and independently hashed. Its **24,965,581 bytes** match the original `candidate.sha256`:

```text
6998bfeeb7a702c3aa5cd3b9d5eca80457aed4f2245bc9bc08dcc703316eb091
```

Reading its real Info.plist confirms `com.holdsnow.nearpane.independent-stage-candidate`, `NearpaneIndependentStageWorkspace=1`, both source revision fields equal to this commit, and `NearpaneStageEngineSourceState=clean`. This is the isolated full workspace candidate, not the daily application identity. The ZIP remains in the artifact; `provenance.json` records its digest and the raw Info.plist digest.

## Actual runtime boundary

The fixture's exact foreground window was independently confirmed twice before launch. The controller-owned canary window **71** acquired original ordinary Space **12** with matching forward/reverse reads at 2 ms and 40 ms. Its hidden-view trace reported success with private Space **13**. The subsequent finish-canary phase returned UNKNOWN / detail **206 (Identity)**; the full launch receipt returned in 0.214 seconds with owned count 2. The available trace does not identify the underlying failed identity predicate, so it is not evidence of a third-party migration failure.

The release request then returned UNKNOWN / detail **217 (Readback)** with owned count 2, and destroy returned BUSY (4). Final independent readbacks confirmed all three untouched foreign fixture windows on their original ordinary desktop, onscreen, with original geometry. However, private Space **13** still appeared in the inventory. The engine's cleanup is therefore **false**, its overall result is **UNKNOWN / cleanupUnconfirmed**, and its operation reason remains **candidateCanaryNotConfirmed**.

| Path | Result in this full-lane artifact |
| --- | --- |
| Third-party engine dispatch | **NOT_RUN**, zero hide/restore request attempts |
| Platform-only foreign diagnostic | **NOT_RUN** |
| R4 product path and Host-crash recovery | **NOT_RUN**; no product receipt exists |
| Group editing, yellow button, native fullscreen/Split View, Mission Control, desktop gestures | **NOT_RUN** |
| CI desktop bootstrap cleanup | **READY / cleanup true**, deleted this run's ordinary Desktop 12 and returned to original Desktop 1 |
| Owned fixture exit | Both fixture quit commands exited zero |

Successful bootstrap cleanup and later fixture exits do not erase the engine's earlier cleanup failure. All qualification fields remain false. The outer artifact digest, candidate digest, and all nine copied originals' byte lengths and hashes are indexed in the separately generated `provenance.json`; no runtime receipt was reformatted.
