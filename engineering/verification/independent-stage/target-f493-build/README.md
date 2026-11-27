# Target f4934582: full release build only

Exact source: `f4934582e3b3634117b4d44ca2debbdd0e3adac4`, continuing PR #16.
The authorized target Mac completed the full release build, packaged the isolated
workspace candidate, and passed strict deep code-signature verification.
**The candidate was not launched. No R4 input or window write was attempted.**

The most recent runtime context explicitly showed a locked session; see
[the original 6d05 locked-session receipts](../target-6d05-runtime/README.md).
This build supplies native compilation evidence, not a runtime or R4 pass.
No Swift unit-test result is claimed by this build-only receipt.

## Exact execution

Started UTC: `2026-11-27T18:18:42.168418+00:00`. Finished UTC: `2026-11-27T18:23:13.752115+00:00`.
The isolated checkout was clean at the recorded parent, then fetched and
fast-forwarded to the exact source above. The daily installed application was
not replaced.

| Step | Exit | Seconds |
|---|---:|---:|
| fetch | 0 | 2.637773 |
| fastforward | 0 | 0.273161 |
| release | 0 | 265.444810 |
| package | 0 | 2.643402 |
| signature | 0 | 0.283526 |

The [original result](source-build/result.json) records the candidate path and
SHA-256/byte lengths of its Host, engine worker, desktop reader and Info.plist.
The [release log](source-build/release.log), [package log](source-build/package.log),
and [signature log](source-build/signature.log) retain original bytes. An empty
signature log accompanies the recorded successful `codesign --verify --strict --deep`
exit; its emptiness is not a missing artifact.

## Provenance

All six target files are unmodified originals, totaling 33620 bytes.
[provenance.json](provenance.json) maps every published file to its exact target
path, byte length and SHA-256. The gzip/base64 transport was decoded locally and
its complete export digest plus all six file digests verified before copying.
There are no window-roster derivatives in this build-only evidence.
