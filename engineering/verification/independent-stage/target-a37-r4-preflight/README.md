# a37 target: full build succeeds, current fullscreen Space blocks R4

Exact source `a37b56c6ac7ad2240405d23a33f02459dffb9a7a`, macOS27.0 /26A428 /arm64 /SIP enabled. The existing isolated checkout was clean before this attempt. The full release build finished successfully in371.913 seconds, and the existing acceptance packager produced the candidate. The daily installation was not replaced.

The native controller then positively observed one active display, ordinary desktop4 present but not current, and current native Space7015 with raw type4. `ordinaryCurrentCount=0`. It correctly returned `BLOCKED / ordinaryCurrentDesktopCountNotOne` before any canary, focus write or hide/restore. The product reported `BLOCKED / fixtureBaselineUnavailable`, with **zero actual R4 inputs**. This is a fullscreen-desktop precondition result, not a latency result or an R4 failure after a click.

Both fixtures exited normally through their owned quit command. The controller performed no window writes, confirmed the original Space inventory unchanged with two complete reads and reported cleanup=true. The product also reports cleanup=true. A subsequent read-only context probe confirmed the same active type4 state and ordinaryCurrentCount0; it performed zero window writes.

The separately executed exact-source Cargo suite failed at test compilation: three E0609 errors in `src/spaces/tests.rs:287`, because the optional injected test-window identity was not unwrapped. No Rust test count is claimed for this attempt. The later `b2513db0` changes only tests, correcting this mock and replacing fragile Swift MainActor timing assertions with explicit handshakes; its native verification is separate.

All14 originals have exact byte counts and SHA-256 hashes in [provenance.json](provenance.json). No desktop screenshot or unrelated user-window content is included. The top-level runtime remains overall INCOMPLETE, exactTargetEngine NOT_PROVEN, R4ProductPath BLOCKED and qualificationGranted=false. The older350e target engine PASS remains an independently recorded historical result.
