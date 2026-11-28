# b43d5a93 full: complete candidate built; system confirmation revoked R4 choice

Run [45726209534](https://github.com/haohongfei2001-png/nearpane/actions/runs/45726209534),
full job 139596608442, source `b43d5a93797c993cf7f7561711d799dd714e3fe1`.

- Source: **160 Rust passed; 169 Swift passed, 1 skipped**.
- Complete companion-workspace release build and strict/deep bundle signature: **PASS**.
- Candidate ZIP: **25,296,704 bytes**, SHA-256
  `0b2736ed4b8f6164a4b606025314cd6bb531d0127c7ac38ea8fd17bca17a388d`.
- R4 product: **FAIL**, cleanup **PASS**, qualification **false**.

The original input receipt identifies the real enabled R4 AXButton and records
one issued AXPress with return code 0. Its handler and the real navigation queue
ran. At uptime 2413.236277 the queued selection still had a current epoch and
dispatch permission; at 2414.636122 the system-confirmation call returned false,
with dispatch, epoch and current-selection checks all revoked. This occurred
before group-choice, worker startup or the first physical window witness.

The same source's fast job had the same earlier boundary, but these are separate
VM observations. This full job later regained a fresh complete catalog at
revision 10 and dispatch permission; its three targets were no longer bound to
visible groups. That later state does not restore the already revoked input.
The actual physical readback still found all three windows on their original
desktop and the global front PID outside the requested target. No working-set
switch occurred. This run did not exercise the new Finder desktop-focus reader.

The existing trace cannot distinguish a queued/expired Dock read, occlusion
revalidation or an actual native desktop/overview change. The next candidate
adds the exact read interval and ownership reason without relaxing the gate.
Yellow routing, merge/split, lifecycle and native system acceptance remained
NOT_RUN after this first product failure.

The receipts here are byte-for-byte copies; `provenance.json` records their
artifact paths and SHA-256 values. The linked full artifact also retains the
complete app, original images, controller/worker traces and cleanup evidence.
