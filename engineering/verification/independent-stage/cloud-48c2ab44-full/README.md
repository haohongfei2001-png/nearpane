# 48c2ab44 full: first rejected physical-read phase identified

Run [45722428165](https://github.com/haohongfei2001-png/nearpane/actions/runs/45722428165),
full job 139583779827, source `48c2ab44991c7dd3c7bf751ada2a2fe4a8ce5767`.
The originals and SHA-256 provenance are stored beside this note. The GitHub artifact
also contains the complete app, source logs, fixture traces, screenshots and cleanup receipts.

## Build and source evidence

- Rust: **159 passed**. Swift: **166 passed, 1 skipped**. Source checks PASS.
- Complete companion-workspace app build and strict/deep signature verification PASS.
- Candidate ZIP: **25,205,980 bytes**;
  `25f8f2fa06e2ecb3134a4518db93a5a1e2d391897c617a493b2bd7a117c03947`.
- Cloud environment: arm64 macOS 27 build 26A434, SIP disabled. This does not
  establish compatibility with the user's build 26A428, SIP enabled.

## Product input and the actual rejection

The real R4 card was found and pressed through external Accessibility, with
`AXPress` returning 0 and `actualR4Inputs=1`. The handler, navigation queue and
group-choice Host ran; all three fixture windows had fresh group lifetimes and
the same production worker connected. This is input/routing evidence only.

The new phase receipts now identify the first failed observation precisely:

- `stagePhysicalReadRejected.step = focused-window-identity` while binding
  fixture PID 36471, window 54.
- The actual front process was Finder PID 373. Its `AXFocusedWindow` object had
  role `AXScrollArea`; its subrole and `AXWindowNumber` attributes returned
  `attributeUnsupported (-25212)`. The canonical window-number read returned 0.
- `witness-read-rejected.step = initial-window-binding`, `bindings=0`,
  `sequence=0`; Core's `stageActivationBeforeBackendRejected.step = initial-witness`.
  No backend `NP_LAUNCH` occurred.

This establishes a failure to represent the real nonstandard focused AX object;
it does **not** establish its parent, containing-window attribute or complete
Finder window-list relationship. Those properties must be observed before that
object can be treated as a known desktop focus. A zero/unsupported window number
alone must not become a fabricated absence of focus.

All three real fixture windows remained on the home desktop at their original
frames. The requested inactive-window departure and target foreground focus did
not occur. R4 product result **FAIL**, cleanup **PASS**, qualification **false**.
The engine's initial yellow-minimize case also failed on this VM and cleaned up;
later cases and native system-interaction acceptance remained NOT_RUN.

The moved initial focus request no longer withdrew the panel before input on
this run. Its ACK does not prove that macOS made the fixture the front process.
