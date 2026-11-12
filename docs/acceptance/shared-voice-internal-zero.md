# Shared voice panel • 内测 0.0

Nearpane uses the standalone editor, glass frame, transcript scroller and SQLite edit transaction from Saytile commit `d4afac741bab284855c7bd71d6e02f927ece77a1`. The source inventory digest is `b1ebb03123283eb419dcbf8ba45c443d0ed7405c38f6ee2464ffad73b4b3599c`. The existing Nearpane speech and Riftlet domains retain their previous pins and independent profile stores.

| Local Apple Silicon macOS check | Result |
| --- | --- |
| Complete Swift Testing suite through `NEARPANE_OFFLINE=1 scripts/test.sh` in the desktop session | PASS · 316/316 across 52 suites |
| Dependency inventory, verified cache and compiler-input checks through `python3 scripts/test-dependencies.py` | PASS · 6/6 |
| Real embedded AppKit editor, window-local shortcuts, dedicated pasteboard, Chinese marked text, deletion and reopening the isolated archive | PASS |
| Selecting text across two recorded rows, undo, redo, later ASR, atomic rollback when a later row has a newer human revision | PASS |
| Disposable debug bundle, embedded provenance and resources, ad hoc signature verified with `codesign --verify --strict --deep` | PASS |
| User installation, release publishing and cloud calls | NOT_RUN |

The hidden native test window uses a fresh local voice directory and a named pasteboard. Text-only rows have no associated audio and do not enter recovery. Edits to spoken rows keep their original IDs, original audio and immutable revisions.
