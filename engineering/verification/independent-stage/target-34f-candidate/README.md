# 34f target: complete candidate built and verified, not launched

The existing isolated target checkout was verified clean, fast-forwarded to exact `34f37360144eb8e339ac81b1f901536f31853ad6`, and built with the complete release configuration. Build exited0 in200.8537s. The existing acceptance packager created `/private/tmp/NearpaneIndependentStage-34f.app` in workspace mode with the exact requested source revision. A separate strict/deep codesign verification exited0.

[candidate.json](candidate.json) records exact source/candidate revisions and executable SHA-256 hashes. The3 original build/package/metadata files have exact lengths and hashes in [provenance.json](provenance.json). This is a development candidate, not a Developer ID/notarization or release qualification.

The candidate was not launched. The previously measured target desktop remains a fullscreen Space, and earlier single native switching/activation attempts did not establish the required ordinary desktop. R4ProductPath is NOT_RUN on this exact target revision. Source/runtime results from other commits or cloud machines remain separate.
