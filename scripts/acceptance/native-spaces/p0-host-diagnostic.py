#!/usr/bin/env python3
"""Run one private signed Host diagnostic. All ordinary product gates remain NOT_RUN."""
import argparse
import importlib
import os
from pathlib import Path
import signal

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit",type=lambda v:Path(v).resolve(strict=True))
    parser.add_argument("output",type=Path)
    parser.add_argument("--issuer-key",dest="diagnostic_key",required=True,type=lambda v:Path(v).absolute())
    parser.add_argument("--drift-kit",type=lambda v:Path(v).resolve(strict=True))
    for name in ("stage-kit","stage-workspace","stage-original-checkout","stage-previous-archive","stage-install-receipt"):
        parser.add_argument("--"+name,type=lambda v:Path(v).resolve(strict=True))
    parser.add_argument("--stage-space",type=int)
    parser.add_argument("--preflight-only",action="store_true")
    parser.add_argument("--booked-census-only",action="store_true",default=os.environ.get("NEARPANE_P0_BOOKED_CENSUS_ONLY")=="1",
                        help="stop after the first owned document and both endpoint censuses, before any setup shortcut or Host switch")
    args=parser.parse_args()
    if args.booked_census_only and (args.preflight_only or not args.stage_workspace):
        parser.error("--booked-census-only requires an enrolled Stage workspace and a distinct run from --preflight-only")
    args.through="diagnostic"
    args.route="ordinary"
    args.setup_input="ax"
    os.umask(0o077)
    def stop(signum,frame):
        raise RuntimeError("received termination signal "+str(signum))
    signal.signal(signal.SIGTERM,stop)
    raise SystemExit(importlib.import_module("p0-cards").run(args))
