# First independent-engine source pass

[Run 45675486685](https://github.com/haohongfei2001-png/nearpane/actions/runs/45675486685), revision `2a0cfbe9b16675905237ab1917fe48b9a61d8789`, completed 147 Rust, 136 Swift and 8 Python tests successfully. One Swift test requiring its separate signed live fixture was explicitly skipped. The two `*-summary.json` files are exact original Actions artifact receipts; `summary.json` records their SHA-256 hashes and the narrower meaning of this run. Complete logs and xUnit XML remain in artifact 15051772431.

The full release executable and bundled Saytile/Riftlet resource checks also completed. The subsequent workflow signature check used the standalone executable at its assembled, still-unsealed bundle path and failed. This was a packaging-verification error, corrected by sealing and strictly verifying the complete candidate bundle in `283831ef`; it was not a Swift compiler failure. No candidate archive or foreign-window/R4 runtime pass was produced by this run.

The hosted runner was macOS 27.0.1 / 26A434, Apple Silicon, **SIP disabled**. Source and build success do not establish behavior on the target macOS 27.0 / 26A428 with SIP enabled.
