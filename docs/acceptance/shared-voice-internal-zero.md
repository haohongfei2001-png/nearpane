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

## Saytile 内测 0.5

Nearpane uses the shared voice surface from Saytile `059fd4a43b262b2ce2e9e0c260d442bdc3f96a61`. Its 10 inventoried inputs have combined SHA-256 `417b9c7f343b3db57487a92fe94d47f2bb4da880fb6b80ddd5921d650cf4dff2`. Within the voice slot, text and controls retain their size as the sidebar narrows. The copy button hides below 112 pt of card width. At 80 pt or less of outer width the voice slot displays its single state control. The standalone app manages its own floating window and menu.

| Verification on Apple Silicon | Result |
| --- | --- |
| Source inventory and offline cache | PASS · all 10 files matched the final Git blobs and the resolver passed 6 tests |
| Complete offline native Swift suite on the final pin | PASS · 319 tests in 52 suites, including the embedded editor and host lifecycle |
| Installed Nearpane or an independent cross-host visual comparison at this pin | NOT_RUN |

## Saytile 内测 0.6

The embedded voice board displays the editable transcript, the copy control and the capture control. The host presents edit failures, capture issues and insertion results in the Voice settings tab. Host configurations that only expose module settings display this feedback in the voice module row.

| Verification on Apple Silicon | Result |
| --- | --- |
| Full serial offline suite in the desktop session, using the final Saytile pin (inventory SHA-256 `2b1121d1e1b968cbaf574ed53aebf423c615bbc850411fabde604317a8844ea7`) | PASS · 319 tests in 52 suites |
| Offline dependency resolver | PASS · 6 tests |
| Sandboxed preliminary run | BLOCKED · the runner terminated while checking the native editor's private pasteboard. The same editor assertion passed in the desktop session. |
| Final upstream commit pin | PASS · all 10 files match the Git blobs at Saytile `0dc49d8306e1fe09ec97140f69965aa4b144d60e` and the tested inventory |
| Nearpane installation or new cross-host visual capture | NOT_RUN |

### Saytile 0.7: target the entire voice button

Pin SaytileVoiceUI to `c331ecb2b62dd4a21d0088ccca96ea3564d1641e`. The copy and capture buttons retain their outlines but accept clicks within their entire rectangular controls. The canonical native panel probe reproduced eight unhandled corner clicks on the previous revision; all eight now invoke the expected action exactly once. On the updated Nearpane pin, the native serial suite passed 319 tests, and all six offline dependency checks passed. No new Nearpane application was installed.

### Idle transcript delivery while another fixture starts a child process

In [native job 131654963266](https://github.com/haohongfei2001-png/nearpane/actions/runs/43355040112/job/131654963266), the tray's process-lock fixture and the idle transcript test ran concurrently on the same main actor. The tray fixture took 2.940 seconds while the voice fixture failed after 2.957 seconds. Of the nine native runs visible for this branch through that SHA, this was the only failed run. These counts describe CI and do not measure user transcription failures.

A controlled test started the lock child's handshake immediately after publication and delayed the child's ready byte by 2.35 seconds. The voice test alone passed in 0.124 seconds. With the old synchronous pipe read, the voice assertion failed after 2.424 seconds and the lock check passed after 2.428 seconds. Moving the read and child exit wait off the main actor let the voice test pass after 0.120 seconds under the same delay. The lock check still passed after 2.488 seconds.

Both tests retain their original assertions, including the two-second transcript deadline, exact text, row count, paused state, unopened microphone, lock exclusion, and reacquisition. The exit status is now checked too. With the diagnostic handshake removed, the complete parallel offline suite passed all 319 tests. All data in this experiment came from isolated fixtures.
