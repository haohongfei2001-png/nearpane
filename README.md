# Nearpane Host Foundation

P2 native macOS Host for [issue #4](https://github.com/haohongfei2001-png/nearpane/issues/4). This stage supplies the Host and **synthetic providers only**. Spaces Preview is **not implemented or validated**. Saytile and Riftlet are unconnected surface placeholders.

Requirements: macOS 14+, Swift 6 toolchain (Xcode Command Line Tools is sufficient). The recorded test environment is macOS 27.0 / build 26A428, Apple Silicon, Swift 6.4. Other macOS versions and Intel are not validated. There are no external package dependencies.

```sh
# Build a native development .app without launching it:
bash scripts/build-app.sh debug
# Run core tests and hidden AppKit construction tests; no visible window:
bash scripts/test.sh
# Optional optimized build, also without launching:
bash scripts/build-app.sh release
```

Artifacts: `build/debug/Nearpane.app` and `build/release/Nearpane.app`. SwiftPM intermediates and test scratch data stay under `.build/`. Build/test scripts do not open the app, change system permissions, or contact external services. The compiler-generated executable signature is verified before packaging; the development bundle has no distribution signature or notarization. Existing generated bundles are retained in `build/<configuration>/previous.*` when rebuilt.

Tests use Swift Testing and SwiftPM's currently supported `native` engine with explicit framework/plugin discovery for Command Line Tools 6.4. That engine emits a deprecation warning; the default `swiftbuild` engine failed here on test-bundle signing and incremental macro discovery. No installed toolchain is changed. Full-bundle signing is deferred: the local File Provider reintroduces Finder metadata after `.app` creation, invalidating a bundle seal ([Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html)). This does not change the compiled executable bytes. The app has **not** been launched to establish visible runtime acceptance.

Manual launch is a separate user action, **not performed during this implementation**:

```sh
open build/debug/Nearpane.app
```

On manual launch, the accessory app places one borderless, nonactivating panel at the right edge of the menu-bar display's visible area. The menu-bar control provides Show / Hide, Settings, and Quit. Only explicitly opening Settings activates the app. Settings supports module enable/disable, pinning and order, screen/edge selection, mock fixtures and simulated permission decisions. No settings control is added to the main surface.

The upper area reserves 3/8 for Saytile and Riftlet; the desktop area reserves 5/8. Optional samples use an independently scrollable control layer and one temporary expanded overlay. Display cards are labeled synthetic and are **not Space rows**. The 3+1 fixture's internal counts appear only in mock diagnostics, alongside the explicit unknown user-facing semantics.

On a manual app run, Host preferences are stored atomically at `~/Library/Application Support/Nearpane/host-configuration.json`. Only placement, module preferences and selected fixture are saved. Runtime desktop IDs, snapshots, permission grants and expanded state are not persisted. A corrupt or future-version file is preserved; the session runs with unsaved defaults. Disabling a module never deletes domain data. This stage does not create domain data stores.

Architecture, status matrix, test boundaries and follow-up acceptance: [P2 Host Foundation](engineering/P2-HOST-FOUNDATION.md). Raw receipts and hashes: [P2 verification](engineering/receipts/P2-20261109/README.md).

Product and visual authorities remain [PRODUCT_DEFINITION.md](PRODUCT_DEFINITION.md), [visual authority](design/NEARPANE-VISUAL-AUTHORITY.md), and the [P1 gate review](docs/reviews/P1-TECHNICAL-GATE-REVIEW.md). Their files and the HTML prototype are unchanged by P2.
