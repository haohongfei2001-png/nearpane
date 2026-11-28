# First normal-engine foreign/group successes, 5607d3b3

[Run 45702787052](https://github.com/haohongfei2001-png/nearpane/actions/runs/45702787052), full job `139516932129`, artifact `15063654234`.

The actual normal candidate ABI passed **NP_LAUNCH**, **foreignRoundTrip**, **sameAppIndependent** and **crossAppGroup**, with independent real-window readback. This goes beyond the separate platform-only probe. It does not prove the full repeated-switch sequence or product R4 path.

The next sequence failed at `cycle-0/C/show`: the runtime published status 2 with detail 223, flags 173, native Space 12, and one remaining session-owned window. Source inspection identified the generic runtime treating aggregate ownership of another hidden window as if the selected window had not returned. That step did not receive its immediate independent success readback because the controller stopped on the rejected receipt; its later physical state is recorded separately.

`windowWrites=9` counts **hide/restore request attempts**, including unverified and rejected requests. It is not a count of nine confirmed WindowServer migrations. The final retry for an already returned window was rejected with detail 210. Release-all returned status 0/detail 225/owned 0, engine destruction returned zero, and all three final independent window checks reported two observations on original home 12 with their original frames and onscreen state. The old cleanup accumulator nevertheless retained the earlier operation failure, so the original terminal receipt is **UNKNOWN / cleanupUnconfirmed**, cleanup false. This archival copy does not rewrite that result or claim a new two-sample whole-inventory cleanup proof. The product R4 run was skipped by that original cleanup gate.

Source checks passed 150 Rust tests and 156 Swift tests with one skipped, plus worker build/protocol and existing evidence/native-diagnostic suites. The complete candidate built and passed strict bundle verification; its archive SHA-256 is `55bee0acc03160712f7f1035d21a16f794891282a151f006f13b289de7ad9949`. Both fixtures quit normally and CIWorkspace cleanup returned READY. The hosted runner is build 26A434, SIP disabled, so exact target qualification remains unproven.

The six receipt/log files are byte-identical originals. provenance.json records their paths and SHA-256 hashes; no platform-only or native-renderer events are duplicated here.
