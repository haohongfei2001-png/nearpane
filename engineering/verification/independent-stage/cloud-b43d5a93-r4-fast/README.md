# b43d5a93: real R4 input revoked during system ownership confirmation

Run [45726209534](https://github.com/haohongfei2001-png/nearpane/actions/runs/45726209534),
source `b43d5a93797c993cf7f7561711d799dd714e3fe1`.

The R4-fast job uses the existing foundation debug configuration and the same
production Host, R4, ordinary window runtime, Spaces worker and acceptance
packager. It omits the companion workspace modules and does not qualify or
replace the complete release candidate. That release job is independent.

## Source and compilation

The full job's early source artifact reports **160 Rust passed**, **169 Swift
passed and 1 skipped**, including the three new retained-minimize/desktop-focus
boundary tests. The lifecycle acceptance additions compiled. The fast job built
the actual foundation Host and sealed its acceptance copy successfully.

## Actual fast-job boundary

The live R4 card was pressed through external AX. `AXPress` returned 0 and the
handler and real navigation queue ran. Timing from the original Host trace:

| Phase | Uptime (s) | Observation |
| --- | ---: | --- |
| Card handler | 433.654915 | Navigation allowed; group and member present |
| Navigation dequeue | 434.031615 | Dispatch allowed, same epoch, current selection |
| System confirmation returned | 435.296238 | Confirmation false, dispatch false, epoch and selection revoked |

Readiness had shown three fresh groups with preview observation enabled. The
actual pre-input PNG still contains placeholders, so this run does not prove
that all three real images were displayed before the click. By final failure the
feed snapshot was nil and gallery visibility had been withdrawn. The paired
original PNGs show the cards before input and the empty panel after withdrawal. The production
group-choice Host and worker were never entered, so this VM provides **no new
Finder desktop structure observation** and no evidence for or against the new
desktop-focus classification.

The original trace does not identify which system ownership observation changed
the epoch. The source can withdraw it for an expired/incomplete Dock read, panel
occlusion revalidation or an actual native desktop/overview change. A 1.265-second
confirmation interval alone does not distinguish those causes. No guard is
relaxed based on this run; the next source adds the exact Dock read timestamps,
reason and ownership transition to that existing trace.

All three fixture windows stayed on their original home with their original
frames; target foreground focus and inactive departures were not observed.
Product result **FAIL**, cleanup **PASS**, qualification **false**. Merge/split,
yellow routing, lifecycle and native system interactions were NOT_RUN.

`provenance.json` distinguishes the full job's early source artifact from the
fast job's actual product artifact. Every included receipt and image is copied
byte-for-byte; debug product behavior is not promoted using release source tests.
