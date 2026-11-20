#!/usr/bin/env python3
"""Exercise the installed sidebar on an already enrolled ordinary Space."""
import argparse
import importlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

from installed_profile import APP, PROFILE, owns_profile
from acceptance import Receipt, controlled_window, manifest
from contract_document import run as run_documents
from p2_stage_surfaces import lease_enrollment
from contract_workspace import empty_system_desktop
from space_scope import require

driver = importlib.import_module("preview-workspace")


def run(args):
    os.umask(0o077)
    kit, output = args.kit.resolve(strict=True), args.output.resolve()
    require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01.") and
            kit.stat().st_uid == os.getuid() and not kit.stat().st_mode & 0o077, "unqualified fixture kit")
    preview = driver.validate_script(args.preview, "paired-preview.py")
    media = driver.validate_script(args.media, "live-preview-media.py")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {"status": "BLOCKED", "newDesktops": 0, "preview": {"status": "NOT_RUN"},
              "stageRestore": {"status": "NOT_NEEDED"}, "media": {"status": "NOT_RUN"}}

    def save():
        temporary = output / "result.next"
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(output / "result.json")

    def record(event, **fields):
        with (output / "lease-events.jsonl").open("a") as f:
            f.write(json.dumps(dict(event=event, **fields)) + "\n")

    stage = None
    original_stage = None
    save()
    try:
        ledgers = None
        if args.original_checkout:
            ledgers = args.original_checkout / "build/verification/secondary-route-followup"
            require(ledgers.resolve(strict=True) == ledgers and ledgers.is_dir(), "unrecognized original lease directory")
        workspace = driver.PreviewWorkspace(kit, args.workspace.resolve(strict=True), record, resume=True,
                                            previous_archive=args.previous_archive, install_receipt=args.install_receipt,
                                            original_ledgers=ledgers)
        workspace.bind_quiet_cleanup()
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        require(owns_profile(workspace.host["pid"], home / PROFILE), "installed Host does not hold the isolated profile")
        _, space_uuid = driver.lease_for(workspace, args.expected_space)
        result["lease"] = dict(space=args.expected_space, uuid=space_uuid, original=workspace.cleanup_current)
        result["admission"] = empty_system_desktop(workspace, args.expected_space)
        original_stage = driver.states(kit)[-1]["state"]
        if args.scenario in ("controlled-window", "pair-pointer", "pair-focus", "pair-drag"):
            result["stageSurfaceEnrollment"] = lease_enrollment(
                workspace, args.expected_space, space_uuid, original_stage, result["admission"])
            save()
        stage = driver.PreferenceStage(kit, output, workspace, args.expected_space)
        require(stage.runtime(original_stage)["status"] == "PASS", "initial installed state not independently confirmed")
        if original_stage:
            result["stageSetup"] = stage.toggle("stage-off", True, False)
        result["offZeroBefore"] = driver.surface_checkpoint(kit, workspace.host, args.expected_space, False, 0)
        require(result["offZeroBefore"]["status"] == "PASS", "initial Host window area not empty")
        save()
        if args.scenario == "same-space-documents":
            require(subprocess.run(["/usr/bin/pgrep", "-x", "TextEdit"], capture_output=True).returncode == 1,
                    "a TextEdit process is already running")
            document_receipt = Receipt(output / "documents")
            try:
                proof = run_documents(workspace, document_receipt, args.expected_space)
                document_receipt.scenarios["W01"] = proof
                result["documents"] = {k: proof[k] for k in ("status", "operationStatus", "reason", "issued", "passes", "cleanup")}
            finally:
                document_receipt.finish()
        elif args.scenario == "pair-cross":
            from cross_app_pair import run as cross_pair
            source = plistlib.loads((APP/"Contents/Info.plist").read_bytes())["NearpaneSourceRevision"]
            proof = cross_pair(Path(os.environ["NP_P2_DOCUMENT_KIT"]), output/"cross-app-pair",
                               workspace, args.expected_space, space_uuid, source)
            result["crossApplicationPair"] = {k: proof[k] for k in ("status", "operationStatus", "attempts", "issued", "cleanup")}
        elif args.scenario in ("pair-pointer", "pair-focus", "pair-drag"):
            from pair_pointer import PairPointerRun
            receipt = Receipt(output / "pair-pointer")
            try:
                before = workspace.read()
                require(workspace.check(before)["current"] == args.expected_space, "leased desktop changed")
                receipt.write("installed-manifest.json", manifest(before, kit / "metrics"))
                pair = PairPointerRun(kit / "observe", before, receipt, workspace.hid, workspace, result["stageSurfaceEnrollment"])
                pair.focus_only = args.scenario == "pair-focus"
                pair.drag_only = args.scenario == "pair-drag"
                pair.run()
                proof = receipt.summary["pairPointer"]
                result["pairPointer"] = proof
            finally:
                receipt.finish()
        elif args.scenario == "controlled-window":
            fixture_receipt = Receipt(output / "controlled-window")
            try:
                before = workspace.read()
                require(workspace.check(before)["current"] == args.expected_space, "leased desktop changed")
                frozen = manifest(before, kit / "metrics")
                fixture_receipt.write("installed-manifest.json", frozen)
                reason = controlled_window(kit / "observe", before, frozen, fixture_receipt, 2,
                                           lease_hid=workspace.hid, lease_workspace=workspace, lease_admission=result["stageSurfaceEnrollment"])
                verdicts = [attempt["status"] for attempt in fixture_receipt.attempts]
                complete = len(verdicts) == 10 and all(v == "PASS" for v in verdicts)
                status = "PASS" if complete else "FAIL" if "FAIL" in verdicts else "UNKNOWN" if verdicts else "BLOCKED"
                proof = {"status": status, "reason": reason, "trials": len(verdicts), "confirmed": verdicts.count("PASS")}
                bound = fixture_receipt.summary.get("registeredDocuments")
                if bound:
                    proof.update(status=bound["status"], reason=bound["reason"], confirmed=bound["passes"],
                                 operationStatus=bound["operationStatus"], superseded=bound["superseded"], cleanup=bound["cleanup"])
                fixture_receipt.scenarios["W01"] = proof
                result["controlledWindow"] = proof
                fixture_receipt.summary["controlledWindowSubtest"] = proof
            finally:
                fixture_receipt.finish()
        elif args.scenario == "five-windows":
            five_script = driver.validate_script(Path(__file__).resolve().with_name("five-preview.py"), "five-preview.py")
            require(args.five_window_kit is not None, "the five-window fixture kit is required")
            installed = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
            require(installed.get("NearpaneSourceState") == "clean", "five-window trial requires a frozen candidate")
            child = subprocess.run([sys.executable, five_script, args.five_window_kit, output / "five-windows",
                                    "--expected-space", str(args.expected_space), "--expected-display", workspace.display,
                                    "--expected-space-uuid", space_uuid, "--expected-source", installed["NearpaneSourceRevision"]],
                                   timeout=150)
            proof = driver.readable_result(output / "five-windows/result.json")
            result["fiveWindows"] = dict(status=proof["status"], reason=proof.get("reason"), exit=child.returncode)
        else:
            mode = "--hidden-budget-only" if args.scenario == "hidden-budget" else "--witness"
            child = subprocess.run([sys.executable, preview, kit, output / "preview", "--expected-space",
                                    str(args.expected_space), mode, "--preview-sampler", "streams"], timeout=160)
            proof = driver.readable_result(output / "preview/result.json")
            result["preview"] = dict(status=proof["status"], reason=proof.get("reason"), exit=child.returncode)
        result["offZeroAfter"] = driver.surface_checkpoint(kit, workspace.host, args.expected_space, False, 0)
        result["status"] = proof["status"] if result["offZeroAfter"]["status"] == "PASS" else "BLOCKED"
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        result["reason"] = str(error)[:260] or "interrupted"
    finally:
        if stage is not None and original_stage is not None:
            try:
                result["stageRestore"] = stage.restore(original_stage)
            except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                result["stageRestore"] = dict(status="BLOCKED", reason=str(error)[:260])
            if result["stageRestore"]["status"] != "PASS":
                result["status"] = "BLOCKED"
            elif result["preview"]["status"] != "NOT_RUN" or any(k in result for k in ("documents", "fiveWindows", "controlledWindow", "pairPointer", "crossApplicationPair")):
                try:
                    result["afterFixture"] = empty_system_desktop(workspace, args.expected_space)
                except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                    result["cleanupReason"] = str(error)[:260]
                    result["status"] = "BLOCKED"
        save()
        if args.scenario != "hidden-budget" and (output / "preview/result.json").is_file():
            try:
                proc = subprocess.run([sys.executable, media, output / "preview"], timeout=30)
                result["media"] = dict(status=driver.readable_result(output / "preview/media/receipt.json")["status"],
                                       exit=proc.returncode)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                result["media"] = dict(status="BLOCKED", reason=str(error)[:160])
        save()
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit", type=Path)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-space", required=True, type=int)
    parser.add_argument("--scenario", choices=("paired-preview", "same-space-documents", "five-windows", "controlled-window", "pair-pointer", "pair-focus", "pair-drag", "pair-cross", "hidden-budget"), default="paired-preview")
    parser.add_argument("--five-window-kit", type=Path, help="signed five-application kit for the five-windows scenario")
    parser.add_argument("--previous-archive", type=Path)
    parser.add_argument("--install-receipt", type=Path)
    parser.add_argument("--original-checkout", type=Path)
    src = Path(__file__).resolve().parent
    parser.add_argument("--preview", type=Path, default=src / "paired-preview.py")
    parser.add_argument("--media", type=Path, default=src / "live-preview-media.py")
    raise SystemExit(run(parser.parse_args()))
