# B · Embedded Saytile — 2026-11-09

Parent: `b63b0b7`. GitHub main was `99cfc1feb234af44e7a88b704758fa57d88f5d12`; it does **not** contain the requested engine. The authoritative single-expert implementation is [2bd114f on the dedicated branch](https://github.com/haohongfei2001-png/saytile/tree/2bd114f526013e6ccb422a26e17f4514e9d63836). Its compact-panel specification, CaptureState, VoiceCaptureGlyph, AudioController, SingleTranscriptEngine and SaytileStore set the contract. This is an integration pin, not a claim that the branch merged.

The registry and the surface share one VoiceModule. It opens a Saytile domain store at Nearpane/Voice and creates the upstream audio controller only on a deliberate capture/retry action. It does not open the standalone store, import its data, read its cloud consents, or run a second app. The native glyph is the unchanged upstream component. Ready/listening, voice level, durable preferred revisions, user edit protection, retry, UTF-16 content and copy derive from the domain. Hidden surface is independent of the capture lifecycle; disabling drains the device and store; quitting awaits the drain. Host diagnostics receive no transcript.

Build inputs come from selected, pinned git blobs of the existing sibling repository under the ignored build cache; no clone, checkout, package resolution network access or upstream edits. SaytileKit requires macOS 26. The integrated bundle records that minimum; the macOS 14 Foundation build remains selectable with NEARPANE_FOUNDATION_ONLY=1. The upstream sample resource and WebRTC notice accompany the integrated executable.

- scripts/test.sh: **52/52**. New tests drive the real SQLite store through partial/final replacement, explicit edit, late revision, recording failure, ordered copy on a private named pasteboard, close/reopen; inject capture events for the glyph and check one language expert plus GPT-6 per configuration. No device/controller created for the initial surface. Tests are not provider accuracy evidence.
- scripts/build-app.sh debug: passed, executable signature and copy verified, packaged ConnectionSample.pcm byte-compared. Initial CLT build lacked the optional SwiftUI State macro plugin. The view uses the public State property wrapper. A fixture enum spelling was corrected before the passing run.
- NOT RUN: microphone/TCC, on-device speech resources, paid ASR/GPT-6, production transcripts, visible pixel/focus acceptance. The local fallback is wired; no cloud activation or inherited Keychain permission. No upstream change needed for this stage. Next: Riftlet owner/queue contract and fixed tray.
- File manifest: git show --name-status ':/feat(voice): embed the pinned Saytile domain'. Raw logs remain under ignored build/verification. SHA-256:
092e7c16fa84c39b1139fb563d07cc3af7dfa838c308577b71fce0cc6787b3fb  build/verification/B-initial.log
a5bd2e7e57882d2424579d4ffca24799acd78421b6b32e0b05177ef67ebee4ff  build/verification/B-tests.log
cda1f27bac855eb93cf8cda44925a84cab4c899fa2b659e96d613274b12a1a36  build/verification/B-tests-final.log
3e1fc26109988b08a84032bd656e6a1b839ac9a23bea9dd4459b1484e12e2749  build/verification/B-debug-final.log
c7b3bc42012d5e8a4fec9040475e92894775d13e632e485e5a5f00f69ab8203f  build/debug/Nearpane.app/Contents/MacOS/NearpaneHost
