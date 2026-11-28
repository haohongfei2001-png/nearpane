# Target 10195c7e: release compile rejected

Exact source: `10195c7e5e50756816ba25cb49202a5cb7f01ef4`, PR #16.
**FAIL at release compilation.** Fetch and exact fast-forward succeeded, then
`scripts/build-app.sh release` exited1 after64.5104515 seconds.
Package generation and signature verification were not executed.
The candidate was not launched; there was no R4 input or target window write.

## Actual compiler failure

The original [release log](source-build/release.log) rejects the nested
`rejected` function in `StageWindowEngineHost.swift`: its accesses to
`phase` and `permittedRejection` are diagnosed as concurrent/non-Sendable
captures (original source lines700 and705). A static review had missed this
local-function isolation inference issue.

The follow-up source fix explicitly marks that local helper `@MainActor`,
matching its enclosing group-choice and permission closure. It changes no
guard, native query, deadline, asynchronous hop or cleanup result.
Successful compilation of that fix must be established by a new exact-source
build; this failed build is never upgraded.

## Provenance

[The original result](source-build/result.json) records source, parent and step
exits. The wrapper stops at the failing release step, so there is no completed
package receipt or successful finished-build marker. All four originals are
preserved byte-for-byte, with target paths, byte lengths and SHA-256 in
[provenance.json](provenance.json). Transport and all original digests were
verified before copying. There are no window-roster derivatives.
