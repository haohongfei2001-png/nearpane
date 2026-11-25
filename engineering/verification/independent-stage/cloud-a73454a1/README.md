# Hosted native rendering evidence and desktop selection timing

[Run 45690818649](https://github.com/haohongfei2001-png/nearpane/actions/runs/45690818649), revision `a73454a1c67e90e480f956423d198935da461cf0`, produced a complete signed candidate in [artifact 15059502866](https://github.com/haohongfei2001-png/nearpane/actions/runs/45690818649/artifacts/15059502866). Its downloaded ZIP matches the original packaging SHA-256: `857c3eb42aafd88649a6f6121736865cf009370f3169eb827d71f004ca28cdeb`. The source step failed only the two new ordinary-controller parent-path tests (three expectations); the complete application still built and passed signature checks. The follow-up corrects URL directory-hint equality by comparing canonical paths.

## Route A: two concrete native strip hypotheses rejected

Both automatic hiding and `LeftStripMaximumRowCount = 0` were actually exercised with native Stage Manager enabled, two freshly signed fixture applications, real foreground activations, and pointer dwell at both screen edges. Both returned `REJECTED_RENDERER_SEPARATION`: native AX strip members had corroborating onscreen CG thumbnail surfaces. Each experiment captured 13 samples. The selected baseline and first left-edge sample are preserved here with the original result; the two decisive edge/baseline PNGs are also preserved here. All samples and remaining images are in the artifact. Pixel review confirms the native tilted group: the AutoHide left-edge AX members 85/86 match onscreen CG thumbnail surfaces (alpha 1, 74×100), and the zero-row baseline matches 125/126. Neither preference is evidence of a separate native renderer-disable mechanism or independent grouping API.

Each experiment returned exit 0 and restored its changed preferences, test fixtures, pointer and foreground; the explicit second restore also returned 0. The original preferences/result/cleanup receipts remain unchanged. These observations apply to this hosted macOS build, not the user's SIP-enabled target; they do not prove that every possible private renderer-control mechanism is impossible.

## Route B: a real native desktop was created

The CI bootstrap successfully created ordinary Space 12 with an OS-supplied UUID. Its selection confirmation returned `systemTileSelectionUnconfirmed`, while the subsequent diagnostic already observed current Space 12. This is evidence of a delayed native transition in the acceptance helper, not a failure of WindowServer foreign migration. Cleanup independently removed the empty created desktop and restored original Space 1. No fixture or foreign-window operation had begun; the product remained `NOT_RUN`.

The next helper correction waits for two stable native reads of the selected desktop before concluding the system action. All original receipts are preserved; the Swift log file here is explicitly an excerpt, and the complete logs are in the artifact.
