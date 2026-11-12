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

## Saytile 内测 0.3

Nearpane pins the nine shared inputs from Saytile `d80a537f6038674e8755c47bbde0b28c90e6684c`. Their combined SHA-256 is `c14f6f6f4c2d3c57e15d6b732223f50b3e35c1a4d89bc5c219d3d91f314f4c28`. Every cached file matched its corresponding Git blob. The host marks an in-progress recording's preferred partial revision as live. Final and edited revisions are displayed atomically. A copy snapshots the text visible for each recording ID when the user clicks, including when pagination shifts a record's position.

| Verification on Apple Silicon | Result |
| --- | --- |
| Full offline native Swift Testing suite, including the embedded AppKit editor, Chinese input, copy, selection, undo and independent host lifecycle | PASS · 319 tests across 52 suites |
| Changed preferred partial revision, inline edit and subsequent ASR result in an isolated SQLite store | PASS · the edit stays selected |
| Partial text copied with a shifted history position | PASS · the snapshot uses the original recording ID and visible prefix |
| Dependency inventory and resolver tests | PASS · 9 Git blobs matched, 6 resolver tests passed |
| Local debug app build, ad hoc bundle seal, deep strict verification, and packaged Saytile and Riftlet resource checks | PASS |
| New end-to-end live microphone trial and frame-by-frame cross-host comparison on this pin | NOT_RUN |

This run used disposable host fixtures and a local debug bundle. The recognition and tray dependencies keep their existing lock entries.

## Saytile 内测 0.4

Nearpane uses the shared editor at Saytile commit `7d575dc2437e5e1e9489e47ad093da04b6a313e4`. The ten locked inputs include `ReaderTextContainer.swift`, which retains line wrapping at the overlap between successive pages. Their combined SHA-256 is `bf9544bb6eae081b6dcfec02158d8b49434726e70e9a3fe47b8dfb5ade3814bf`.

| Verification on Apple Silicon | Result |
| --- | --- |
| Git blobs and offline source cache | PASS · 10 verified files and 6 dependency resolver tests |
| Concurrent Swift suite (initial run) | FAIL · 318 passed. The fresh module in the unverified-insertion restart test encountered an exclusive database lock in its synthetic directory. The underlying cause was not established. |
| Serial Swift suite | PASS · 319 tests in 52 suites, including expanding the history page, copying a group spanning pages, and editing the embedded transcript |
| Worktree debug bundle | PASS · native host and helper executables built, signatures checked, packaged Saytile and Riftlet resources verified |
| Installed Nearpane or fresh cross-host scroll capture | NOT_RUN |
