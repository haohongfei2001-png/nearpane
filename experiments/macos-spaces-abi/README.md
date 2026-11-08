# P1-A: isolated ABI and CF contract experiment

This is an offline command-line experiment, not a Nearpane Host module or a production Spaces adapter. The current executable uses synthetic CF objects and never loads SkyLight, enumerates user windows, changes focus, switches Spaces, requests permissions, changes settings, or captures pixels.

The user's safety correction is authoritative: the only permitted live membership selector is `0x7`; no other selector may be called, including as a negative test. Both C and Swift call sites now contain the literal `0x7`. There is no selector option or selector sweep. Live initialization is compiled out by default (`NEARPANE_ENABLE_LIVE=0`), is not exposed by the CLI, and the CLI refuses a build with that flag enabled. The dormant C loader receives a syntax check only.

**Live selector-0x7 verification remains NOT TESTED within the corrected sandbox boundary.** The initial sandbox attempt returned NULL for managed spaces and found fewer than two usable window metadata records; it stopped before membership. Do not repeat it with higher privileges. Earlier privileged runs occurred before the correction, are retained privately and disclosed in the report, and do not pass this gate.

## Files

- `skylight-shim.h` / `skylight-shim.c`: pinned C declarations, Clang width/type assertions, fixed-selector wrapper, input guards, synthetic backend and a CF allocation observer.
- `abi-probe.swift`: C/Swift calling convention and encoding comparisons, checked CF/Foundation parsing, exact UInt64 fixtures, ownership and bounded repeated-call tests.
- `run-verification.py`: sandbox-compatible offline build/test runner; each invocation creates a new private receipt directory. No escalation or live execution path.
- `summarize-evidence.py`: read-only receipt/hash verification and export of synthetic results, sanitized historical counts and hashes. It launches no helper.
- `evidence/20261109/`: current offline receipts and the complete index of private evidence.
- `SHA256SUMS.txt`: public source/report/evidence hashes, with paths relative to the repository root.
- `.local/`: ignored, private raw evidence, binaries, exact source snapshots and compiler caches. Never commit or upload this directory.

## Reproduce offline

Use the existing workspace sandbox. Requires Python 3, Clang, Swift and the macOS SDK. The recorded environment is macOS 27.0 / 26A428 / arm64, Apple Clang 21.0.0 and Swift 6.4.

Prepare the two pinned reference texts only if absent. These are source downloads, not execution of yabai:

```sh
python3 - <<'PY'
from pathlib import Path
from urllib.request import urlopen
root = Path('experiments/macos-spaces-abi/.local/reference')
root.mkdir(parents=True, exist_ok=True)
root.parent.chmod(0o700)
revision = 'dd845723416f5fe92af49fad5ebab00369e07edd'
for name, source in [('yabai-extern.h', 'src/misc/extern.h'), ('yabai-window.c', 'src/window.c')]:
    target = root / name
    if not target.exists():
        data = urlopen(f'https://raw.githubusercontent.com/asmvik/yabai/{revision}/{source}', timeout=20).read()
        with target.open('xb') as output:
            output.write(data)
PY
python3 experiments/macos-spaces-abi/run-verification.py
```

The runner prints the new private run path. It compiles a C object and a standalone Swift executable, verifies that the binary has no loader/SLS/window-list imports, checks the dormant live C path without linking or running it, injects six faults, runs the fixture matrix with 1000 measured repetitions, then compiles and runs AddressSanitizer with 200 measured repetitions. Runs and failed attempts are never overwritten.

The runner does not retry `leaks`: the preserved offline attempt failed because the current sandbox denied its task-port request. The CF allocation observer is local to this process and counts only CF objects created with the fixture allocator. It does not prove the absence of all process leaks or anything about SkyLight ownership.

To export receipts into a **new** output directory:

```sh
python3 experiments/macos-spaces-abi/summarize-evidence.py \
  experiments/macos-spaces-abi/.local/20261108T171713.345866Z \
  experiments/macos-spaces-abi/evidence/NEW-DIRECTORY
shasum -a 256 -c experiments/macos-spaces-abi/SHA256SUMS.txt
```

`NEW-DIRECTORY` must not already exist. The timestamp above is the recorded final offline run; use the newly printed path after a new run. The summarizer verifies all archived run manifests before exporting. Historical live identifiers, display identifiers, and raw output stay private. Fixture IDs in the public results are explicitly invented.

## Interpretation

The synthetic membership rules intentionally supply NULL, empty, one-ID and multiple-ID responses. Their deduplication/order behavior is a fixture definition, **not a claim about selector 0x7**. Local type checks preserve unknown/malformed values rather than coercing them to zero or a default Space. NSNumber storage may be canonicalized by Core Foundation; explicit SInt32 construction does not promise that `CFNumberGetType` will always report the requested storage width.

The unsigned-window guard first checks the exactly representable 32-bit numeric domain. This closes an observed regression where `NSNumber(UInt64.max)` reported a successful SInt64 conversion to `-1`. Space IDs use exact integer/decimal parsing without a Double intermediate; their supported parsing fixtures are not evidence that SkyLight emits those high values.

Copy returns in the C path are borrowed for inspection then explicitly released once. The Swift path calls `takeRetainedValue()` once and leaves an autorelease pool before shutdown. The custom allocator confirms destruction of controlled CF allocations, including on malformed-response paths. Neither accounting nor fixtures establish an undocumented private +1 contract.

See the [report](../../engineering/P1-ABI-CONTRACT-20261109.md) and [technical gate review](../../docs/reviews/P1-TECHNICAL-GATE-REVIEW.md). P1-A's live contract remains open; no cross-build stability or production readiness is claimed.
