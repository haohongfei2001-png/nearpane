# Shared voice panel • 内测 0.0

Nearpane uses the standalone editor, glass frame, transcript scroller and SQLite edit transaction from Saytile commit `c4adf967799c7faee90b70c74184b2e4179edc0e`. The source inventory digest is `06f843a3427be85229b9439027806853901ef8a020a06ed7f8c272f4227b2be5`. The existing Nearpane speech and Riftlet domains retain their previous pins and independent profile stores.

| Local Apple Silicon macOS check | Result |
| --- | --- |
| Complete Swift Testing suite through `NEARPANE_OFFLINE=1 scripts/test.sh` in the desktop session | PASS · 316/316 across 52 suites |
| Dependency inventory, verified cache and compiler-input checks through `python3 scripts/test-dependencies.py` | PASS · 6/6 |
| Real embedded AppKit editor, window-local shortcuts, dedicated pasteboard, Chinese marked text, deletion and reopening the isolated archive | PASS |
| Selecting text across two recorded rows, undo, redo, later ASR, atomic rollback when a later row has a newer human revision | PASS |
| Disposable debug bundle, embedded provenance and resources, ad hoc signature verified with `codesign --verify --strict --deep` | PASS |
| User installation, release publishing and cloud calls | NOT_RUN |

The hidden native test window uses a fresh local voice directory and a named pasteboard. Text-only rows have no associated audio and do not enter recovery. Edits to spoken rows keep their original IDs, original audio and immutable revisions.

The earlier shared build set an ordinary non-key sidebar editor as the window's first responder. A fresh speaking capture showed zero violet tail pixels in Nearpane and an 82-pixel caret in standalone Saytile even before the fixture made any selection. The shared editor now requests the system insertion caret only while its own window has keyboard focus.

## Saytile 内测 0.1

Nearpane now resolves eight shared files from Saytile `6271a65f17f5b749ff89427e6e2681a76a11b386`. Their combined SHA-256 is `8c094b4a2ebbbf7231de3282bf093a8753b24c2a0eaacda7b5f6a97004a6e22a`. Two view files changed. Nearpane's sidebar still supplies its own glass rail and uses the default framed voice slot. The standalone app owns its border preference.

| Check on this pin | Result |
| --- | --- |
| Fetch the eight files from the pinned GitHub archive and verify the inventory | PASS |
| Dependency resolver tests | PASS · 6/6 |
| Complete offline Swift suite in the local macOS desktop session, including the embedded AppKit editor | PASS · 316/316 across 52 suites |
| Initial sandbox-only run | BLOCKED · the Swift test process received signal 5 during native tests |
| Fresh cross-host screenshot comparison on this pin | NOT_RUN |
