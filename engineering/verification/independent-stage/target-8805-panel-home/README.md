# Target Mac: own-panel discovery deadline before any migration

Source: `8805a3dbd22c44ff0f95a53476357b4dd45a2ef3`.
Executed through the existing unified runtime entry on **macOS 27.0 /26A428,
Apple Silicon, SIP enabled**, with the console logged in and existing AX access.
The clean, separate checkout was fast-forwarded; the daily application and its
working checkout were not changed. Original output:
`/private/tmp/nearpane-independent-8805-runtime-20261127-b`.

An earlier invocation stopped at the build step because its PATH did not expose
the already installed portable Cargo. It created no test windows. The recorded
invocation reused that existing compiler, built the current production archive,
and created two disposable foreign processes with three real ordinary windows.

## Actual result

- All three initial foreign-window identities, original frames, on-screen state
  and exclusive ordinary home `4` were independently read twice.
- The controlled front window was positively focused before `NP_LAUNCH`.
- The controller-owned panel `121041` prepared, opened and was read on the real
  AppKit main loop. Its first complete home observation was `4` at 3 ms. The
  second was also `4` at 208 ms, with reverse membership containing the panel.
- The launch discovery loop used a 120 ms deadline. It rejected the second
  positive observation as expired: `panel-home`, status `2`, detail `207`.
- No hidden Space was created and **zero foreign hide/restore requests** occurred.
  This is `BLOCKED / candidateCanaryNotConfirmed`, not a foreign bridge failure.
- The original panel was closed. The first release returned `owned=0`; two
  independent complete reads confirmed the three original windows and exact
  original 16-entry Space inventory. Both fixture children exited normally.
  **Cleanup PASS**; product R4 and every foreign behavior remain `NOT_RUN`.

The trace does not separate the 205 ms between observations into main-queue work,
AX/WindowServer reads, or thread scheduling. No cause such as App Nap is inferred.
The follow-up changes only the own-panel discovery budget and adds phase timing;
the ordinary 120 ms Space-mutation acknowledgement deadline stays separate.
Later successful execution cannot rewrite this blocked run.

`provenance.json` hashes the unmodified source files copied from the target. No
desktop screenshot or unrelated user-window content is included.
