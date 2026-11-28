# 9cec081f full: real Finder desktop structure differs from the first candidate

Run [45728613871](https://github.com/haohongfei2001-png/nearpane/actions/runs/45728613871),
full job 139604697439, source `9cec081fe8d125c3106adead51b6662dee811a6d`.

- Source: **161 Rust passed; 169 Swift passed, 1 skipped**.
- Complete companion-workspace release build and strict/deep bundle signature: **PASS**.
- Candidate ZIP: **25,317,102 bytes**, SHA-256
  `cf2f87d7c5bb112947917dedf00ee96098ad965e254720b4cc4679b30752fec8`.
- The controller's physical engine checks passed with cleanup true.
- R4 product: **FAIL**, one real AXPress issued, cleanup **PASS**, qualification **false**.

## Actual product boundary

The exact exported R4 button was pressed and the real handler, navigation,
group-choice Host and worker connection ran. The dispatch-time Dock confirmation
read from 1294.088669 to 1294.092425 seconds (3.76 ms); total request time was
12.09 ms. It positively reported ordinary desktop state and retained the input
epoch. This VM did not reproduce b43d5a93's earlier ownership revocation.

The first physical window witness then rejected Finder's foreground object.
The newly recorded structure is concrete:

- System Finder path/Bundle ID and PID 377 matched.
- The focused object was an `AXScrollArea` with no positive canonical window ID.
- Its actual `AXParent` was the exact `AXApplication` object.
- Finder's complete `AXWindows` array included the focused scroll area.
- `AXWindow` returned success and an AX object. That object's role was also
  `AXScrollArea`, with no positive window number.

The prior candidate only allowed an unlisted object with an explicitly empty or
unsupported `AXWindow` attribute, so it rejected this different representation.
The original receipt **does not establish CFEqual identity** between the focused
object and the returned `AXWindow`, nor the exact number of matching list entries.
The next Swift/C candidate supports this additional form only if it actually
proves that self equality and exactly one matching list entry. A different
containing object, duplicate/unknown list or unavailable attribute remains a refusal.

Core stopped at `initial-witness`; the worker had connected but no `NP_LAUNCH`
was issued. The three fixture windows remained on their original home with their
original frames. Their R4 images do not establish any working-set switch.
Merge/split, yellow routing, lifecycle and native system product checks remained
NOT_RUN after this first failure.

All included receipts are byte-for-byte originals, with artifact paths and
SHA-256 provenance. The complete artifact also retains the full app, real images,
worker logs, controller checks and cleanup evidence. These cloud results remain
separate from the user's SIP-enabled target environment.
