# A · Host Foundation closeout — 2026-11-09

Start: `7d09cce95ec62e1fb2e20123e7123421bc7e389d`, clean, same GitHub engineering head. macOS 27.0 (26A428), arm64, Apple Swift 6.4. No visible windows.

- Placement now filters empty/invalid screens. Startup, redisplay and hotplug respect both usable placement and the saved hide intent. Missing monitors do not erase the preference. Screen changes no longer re-order an already visible surface. The expanded module's dismissal surface leaves both first-party slots interactive.
- Stop releases event subscribers and simulated grants; same-object restart reads new preferences against catalog defaults. Bounded configuration reads preserve unreadable, oversized and invalid files. Earlier v1 files still load.
- `scripts/test.sh`: **49/49**, including hidden AppKit panel, negative-origin/fallback placement, ratios/overflow, persisted hide, same-object restart and corrupt/oversized data. Initial run: 48/49; CLT FileHandle reports Cocoa code 4 on a missing file. Corrected to accept both missing-file codes only, then reran.
- `scripts/build-app.sh debug` and `scripts/build-app.sh release`: both passed plist lint, strict executable signature check and packaged-byte comparison. Development bundles are not distribution signed. Known CLT linker search-path and native-engine deprecation warnings are retained in local logs.
- NOT RUN: visible placement/focus, physical display hotplug, live overlay/scroll interaction, idle energy, or crash containment. Snapshot/provider faults remain isolated at the Swift error boundary. No live Spaces actions. Next gate: same-process first-party domains.

Exact file manifest: `git show --name-status ':/fix(host): respect display availability'`. Local raw build/test logs are ignored in `build/verification/`. SHA-256 at this stage:
5b63d31603c7c9226fa84db63288b6462f50f4179d12190eb59c3f60e396247e  build/verification/A-tests.log
0d17263be7dad883810549d2a973bc44b0550e4d1ae678f7b4509f14f268b229  build/verification/A-tests-final.log
2b96ee21b5d0ff95fdada82f44ad457d9818ed4d39fabf385176fea3f1744e93  build/verification/A-debug-final.log
4a96c3c2ae1897b64b81368659bd0788d05c854cc7137b6feb776ebac9a4c63f  build/verification/A-release-final.log
e683ad4a468071d118abdf808073b960e5b4e0acfc34e15c1b233f753d12c792  build/debug/Nearpane.app/Contents/MacOS/NearpaneHost
e3b296e962fb808cbe1ab5f1b1e4f4e44c71e21f5d191ec239098a9c96f233f0  build/release/Nearpane.app/Contents/MacOS/NearpaneHost
