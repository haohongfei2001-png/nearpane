# 350e full: complete build, incomplete external AX discovery

Source `350e848cc30106c32156ddba2c222ab639ab141f`;
[run 45883578306](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306),
full job 140128628465,
[artifact 15148989122](https://github.com/haohongfei2001-png/nearpane/actions/runs/45883578306/artifacts/15148989122).
Hosted macOS 27.0.1 / 26A434 / arm64 / SIP disabled. This VM is independent of the
fast and diagnostics lanes.

## Source, package and actual product result

- Source checks pass: **166 Rust / 174 Swift / one Swift skip**; FFI worker,
  protocol, evidence and diagnostic builds also pass.
- The complete companion-workspace candidate builds and its bundle signature
  check passes. `Nearpane-independent-candidate.zip` is 25,361,971 bytes, with
  SHA-256 `ef3ea48565d3ce551e1cb64432b00e83af9cd147e67808e3f13fcb57e58ea513`.
  Candidate metadata and the original checksum receipt are retained here; the
  ZIP remains in the linked artifact.
- All ten raw foreign-window engine checks and physical cleanup pass in this VM.
- Production overview readiness is observed. External AX discovery visits
  AXWindow, AXGroup and AXScrollArea, but never confirms a target button; its
  retained receipt ends with `windowListRead = -25204` (AXCannotComplete),
  `panelIdentityOrVisibilityUnconfirmed` and **issued = false**.
- No prePress validation, input handler, group job, retained-window witness or
  NP_LAUNCH is established. **Product BLOCKED / realExternalR4ButtonNotAccepted /
  actualR4Inputs 0 / cleanup PASS** is the result. The workflow correctly fails
  because the explicitly requested product path did not pass. Cold preview,
  crash/restart, lifecycle and system interactions remain NOT_RUN.

The pre-input screenshot shows three fixture cards with placeholders. Later
metrics report two cached images and five delivered frames, but this image does
not establish that those frames were actually displayed, nor that any hidden
window thumbnail succeeded.

This result must not be replaced by the separate fast VM's successful AXPress or
its later ownership expiry. It also does not prove that the original panel or
button was replaced; the actual AX discovery was incomplete.

## Actual profile

The complete 255,407-byte sample contains 44 main-thread observations. Several
enter SwiftUI rendering through `windowList`, `rawOverview`, `panelAvailable`,
the badge task identifier, and historical-picture lookup, making repeated
console-session reads. These corroborate the same avoidable presentation reads
seen in the fast VM. They do not prove the precise cause or duration of every
AXCannotComplete. The proposed presentation-only correction keeps fresh native
action and pixel checks, including the unchanged 750 ms dispatch boundary.

`provenance.json` records byte counts and SHA-256 hashes for all copied original
receipts, logs, source summary, sample and image, plus the outer artifact and
complete candidate. A successful build and raw engine test do not qualify the
actual R4 product path.
