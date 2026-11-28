#!/usr/bin/env python3
"""Compare existing Spaces rendering/boundary tests on the same macOS runner.

The pre-workbench PR 16 commit is tested without source patches in a disposable
worktree. Its failure is diagnostic, not an exemption for a candidate regression.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


BASELINE = "60cf3219901c6997db400a1d08e143ddd011d0a0"


def main() -> int:
    repo = Path(__file__).resolve().parents[3]
    output = repo / "build/unified-workbench-evidence/baseline"
    output.mkdir(parents=True, exist_ok=True)
    samples = output / "render-samples"
    samples.mkdir(exist_ok=True)
    receipt = {
        "schema": 1,
        "sourceCommit": BASELINE,
        "candidateCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "scope": "Unmodified PR 16 baseline; same macOS runner; only boundary and existing native renderer suites",
        "filter": "SpaceInventoryTests|DesktopRosterPresentationTests",
        "status": "RUNNING",
    }
    with tempfile.TemporaryDirectory(prefix="nearpane-baseline-", dir=repo / "build") as temporary:
        worktree = Path(temporary) / "source"
        added = False
        with (output / "baseline-tests.log").open("w") as log:
            try:
                subprocess.run(["git", "fetch", "--depth=1", "origin", BASELINE], cwd=repo,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
                subprocess.run(["git", "worktree", "add", "--detach", str(worktree), BASELINE], cwd=repo,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
                added = True
                env = dict(os.environ, NEARPANE_ROSTER_SAMPLE_DIR=str(samples))
                result = subprocess.run(["bash", "scripts/test.sh", "--no-parallel", "--filter", receipt["filter"]],
                                        cwd=worktree, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
                receipt["exitCode"] = result.returncode
                receipt["status"] = "PASS" if result.returncode == 0 else "FAIL"
            except Exception as error:
                receipt["status"] = "BLOCKED"
                receipt["reason"] = str(error)
            finally:
                if added:
                    subprocess.run(["git", "worktree", "remove", "--force", str(worktree)], cwd=repo,
                                   stdout=log, stderr=subprocess.STDOUT, check=False, timeout=30)
    (output / "baseline-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
