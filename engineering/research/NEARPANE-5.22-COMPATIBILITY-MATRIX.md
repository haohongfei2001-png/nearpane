# Nearpane 5.22 — Compatibility Matrix

Date: 2026-11-20  
Baseline hardware: Apple Silicon, one physical display.  
Installed OS evidence: macOS 27.0 build 26A428.  
Important: a version family is not a compatibility guarantee. Exact OS build + signed installed candidate + independent readback are required.

## OS/API compatibility

| Capability | API / mechanism | API class | macOS 26.0–26.5 | macOS 26.6–26.7 | macOS 27.0 (26A428) | Status / policy |
|---|---|---|---|---|---|---|
| Window inventory | CGWindowListCopyWindowInfo, CGWindowID | Public CoreGraphics | Available | Available | Available | Use as one inventory source; relatively expensive; does not prove complete Space membership |
| Window focus | AXUIElement, AXFocusedWindow, AXMainWindow, AXRaise | Public Accessibility | Available with permission | Available | Available with permission | AX calls may timeout or be unsupported; verify focused target independently |
| App activation / window state | AppKit NSApplication / NSWindow | Public AppKit | Available | Available | Available | App activation alone is not exact window focus |
| Space list / IDs | CGSCopyManagedDisplaySpaces / SLS* | Private SkyLight | Undocumented | Undocumented | Undocumented | Runtime-gated, no public compatibility guarantee |
| Adjacent Space switching | Synthetic Dock swipe through CGEvent + undocumented fields | Undocumented event protocol | Do not enable zero-travel optimization; ordinary native fallback | Experimental low-travel adapter | Requires serialized IOHID payload | No release support until per-build installed tests |
| macOS 27 Dock payload | ISS-derived serialized IOHID payload | Reverse-engineered | N/A | N/A | Observed required by Dock | Version-gate exact protocol; do not infer future compatibility |
| Empty Space landing | Activation/Dock window-follow behavior | System behavior | Reported on 26 | noswoosh says underlying bug fixed 26.6 | Reproduced 8/8 without guard in noswoosh 27.0 test | Keep guard isolated; test real multi-app topology |
| Cross-Space move | SLSBridgedMoveWindowsToManagedSpaceOperation | Private SkyLight ObjC class | Not established | Reported on 26.4.1; test exact build | Not established by Nearpane | Experimental only; current Nearpane capability false |
| Legacy move | SLSMoveWindowsToManagedSpace / compat ID | Private SkyLight / scripting addition | Unreliable across OS; Sequoia compat-ID workaround reported dead | Do not use as fallback | Do not use as fallback | Prohibited fallback |
| Capture | ScreenCaptureKit / native screenshot UI | Public framework / system UI | SDK availability dependent | Available | Available | Permission and coordinate transforms must be validated |
| Browser automation | Apple Events + AX | Public OS automation facilities, target-specific scripting dictionaries | Browser-dependent | Browser-dependent | Browser-dependent | No universal guarantee; existing login profile and domain adapter |
| Translation | Translation framework / TranslationSession | Public framework | Check SDK availability | Check SDK availability | Available according to current SDK docs | Language/model availability is runtime-dependent |
| Translation service | NSServices / service provider | Public AppKit service mechanism | Available | Available | Available | Service invocation, process handoff and panel visibility separate tests |
| Speech | Speech framework / SFSpeechRecognizer | Public framework | Available; locale/device support varies | Same | Same | On-device only if supportsOnDeviceRecognition true |
| Auxiliary UI | NSPanel | Public AppKit | Available | Available | Available | Floating/key behavior must match user interaction requirements |
| Signing/notarization | Developer ID + Hardened Runtime + notarization | Apple distribution tooling | Available | Available | Available | Current candidate not notarized and nested signatures incomplete |

## Installed candidate evidence

| Candidate / source | Environment | What was tested | Result |
|---|---|---|---|
| 5.22 (90), source 0777130 | macOS 27.0 26A428, arm64, one display | 50 Space choice contract | 0/50 |
| 5.22 (90), source 0777130 | Same | Nine supplemental row selections | 0/9 confirmed; one later foreign Space observed, cause UNKNOWN |
| 5.22 (90), intermediate candidate | Same | Same-app dual-window focus/input | 1 PASS, 1 FAIL |
| 5.22 (90), final candidate | Same | TextEdit intent/final readback | 1 intent, 0 confirmed input, UNKNOWN |
| 5.22 (90), source 0777130 | Same | Cross-Space migration | BLOCKED; canMove=false; 0 move attempts |
| 5.22 (90), source 0777130 | Same | Translation service | Service dispatched; no bubble; FAIL |
| 5.22 (90), source 0777130 | Same | Wordbook persistence | BLOCKED |
| 5.22 (90), source 0777130 | Same | Browser attachment | BLOCKED: guest profile had no usable editor; zero attach/send events |
| 5.22 (90), source 0777130 | Same | Voice cold-start | 2 phrases PASS, 1 UNKNOWN after fullscreen transition |
| 5.22 (90), source 0777130 | Same | Fullscreen | Entry PASS; return not confirmed |
| 5.22 (90), source 0777130 | Same | Split View / multi-display | BLOCKED: controlled second window ambiguous / one physical display |
| 5.22 (90), source 0777130 | Same | Hidden capture stop and restore | PASS for scoped 60-second subtest |
| 5.22 (90), source 365fdc4 | macOS 27.0 26A428, arm64, one display | Empty/open/closed controlled windows | 0→2→0 window cards; scoped PASS |
| 5.22 (90), source 365fdc4 | Same | Swift/Python regression | 520/520 and 32/32 |
| 5.22 (90), source 365fdc4 | Same | Developer ID deep signature and launch | PASS; notarization NOT_TESTED; clean-Mac install NOT_TESTED |

## Distribution gates

| Gate | Current evidence | Required before release |
|---|---|---|
| Developer ID signature | Candidate signed and deep verification passed | All nested helper and Sparkle executables signed consistently |
| Hardened Runtime | Not fully proven for every nested executable | Verify runtime option and minimal entitlements for all executables |
| Notarization | NOT_TESTED | Submit, obtain accepted ticket, staple and validate |
| Clean install | NOT_TESTED | Clean macOS 26/27 install, first launch, permissions and helper registration |
| Upgrade continuity | Prior same-team continuity tests exist | Repeat on exact final candidate including every helper |
| Sparkle | Package gate lists missing distribution signatures | Signed update archive, appcast and updater chain |
| Mac App Store | Private API dependency | Not suitable unless all private adapters removed/replaced by documented APIs |

## Compatibility policy

- Never claim macOS 26 support as a single undifferentiated family. Split 26.0–26.5 from 26.6+ for the synthetic gesture path.
- Never infer macOS 27 compatibility from macOS 26.4.1 move-operation evidence.
- Keep private API adapters disabled by default on untested builds.
- On unknown protocol or failed independent observation, show native-control fallback and preserve logs.
- Re-run the minimal smoke suite on every macOS point release and the full suite on each major release.
- Record exact hardware, architecture, OS build, signing identity, candidate SHA-256 and source commit with every receipt.

## Primary references

- Apple CGWindowListCopyWindowInfo: https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29
- Apple Quartz Window Services: https://developer.apple.com/documentation/coregraphics/quartz-window-services
- Apple AXFocusedWindow: https://developer.apple.com/documentation/applicationservices/kaxfocusedwindowattribute
- Apple AX attributes: https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes
- Apple AXUIElementPerformAction: https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction
- Apple Translation: https://developer.apple.com/documentation/translation
- Apple Speech: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- Apple on-device Speech support: https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition
- Apple on-device accuracy caveat: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- Apple NSPanel: https://developer.apple.com/documentation/appkit/nspanel
- Apple Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Apple notarization: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- Apple Developer Program agreement: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- ISS source: https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c
- noswoosh: https://github.com/mmathys/noswoosh
- yabai Space manager: https://github.com/asmvik/yabai/blob/master/src/space_manager.c
- yabai private declarations: https://github.com/asmvik/yabai/blob/master/src/misc/extern.h
- DockDoor migration report: https://github.com/ejbills/DockDoor/issues/855
- DockDoor/yabai comparison research: https://github.com/ndelanhese/volta/blob/main/Engine/macos-spaces-research.md
