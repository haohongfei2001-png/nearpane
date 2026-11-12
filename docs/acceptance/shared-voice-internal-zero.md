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
