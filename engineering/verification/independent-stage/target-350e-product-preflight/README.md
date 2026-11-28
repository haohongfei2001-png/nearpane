# Separate 350e target product invocation: preflight blocked

This is the later invocation at
`/private/tmp/nearpane-independent-350e-product-20261127`, after the same source
`350e848cc30106c32156ddba2c222ab639ab141f` completed its full release build on
the target27.0/26A428/arm64/SIP-enabled Mac. It is separate from the earlier
[complete foreign-engine PASS](../target-350e-engine/README.md).

## What actually occurred

The raw controller could not establish the controlled fixture's foreground.
Its final front PID was425 (`loginwindow`); no AX focus write or foreign
hide/restore request was issued. It records
`BLOCKED / controlledFixtureFocusUnavailable`, then confirms full physical
cleanup. Both fixture processes subsequently exit0.

The separately packaged product started but stopped even before its AX/TCC and
WindowServer checks, at `isolatedFixtureConfigurationRequired`. Actual R4 inputs
were zero. Its original product receipt and overall incomplete result are retained.

The subsequent read-only Foundation/CG probe confirms `screenLocked=1` with
console/login state set. It also reproduces a distinct configuration bug:

- Existing output and config parent standardize to `/tmp/.../runtime/product/`.
- The parent of the not-yet-created profile retains `/private/tmp/.../runtime/product/`.
- Config-parent equality is true, profile-parent equality is false.
- Resolving the actual parents makes the same-directory comparison true.

The source correction canonicalizes both real parents and compares paths while
retaining exact fixture PID, process identity and directory scope checks.
Tests cover an absent child reached through a directory alias and reject a
profile that actually resolves outside the output. This correction does not
unlock the console, modify TCC, issue UI input in a locked session, or promote
the blocked original run to a product success.

All seven originals have exact byte lengths and hashes in `provenance.json`.
No desktop screenshot or unrelated user-window content is published.
