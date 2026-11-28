#!/usr/bin/env python3
"""Control only signed sibling fixture windows. EOF ends the owning Host session."""
import json
import os
from pathlib import Path
import runpy
import select
import sys
import time
import uuid

here = Path(__file__).resolve().parent
lab = runpy.run_path(str(here / "verify-window-management.py"))
Trial, read, save, need = (lab[key] for key in ("Trial", "read", "save", "need"))


def run(support):
    config = support / "Nearpane" / "host-configuration.json"
    output = support / "WorkRect"
    need(support.resolve() == support and (support / "profile.version").read_text() == "Nearpane P4.5\n", "candidate profile required")
    output.mkdir(mode=0o700, exist_ok=True)
    trial = Trial(output, here.parent.parent / "Helpers")
    status = {"members": 0, "ready": False}
    def publish(**fields):
        status.update(fields)
        print(json.dumps(status, ensure_ascii=False), flush=True)

    pre = trial.command("preflight")
    need(pre["trusted"] and pre["parent"]["pid"] == os.getpid(), "signed controller requires Accessibility")
    display = pre["screens"]["secondary"]
    save(trial.dir / "run.json", dict(session=str(uuid.uuid4()), parent=pre["parent"], screens=pre["screens"], deadline=pre["uptime"] + 480))
    ratio, swap, explicit = 0.5, False, False
    def plan(persist=True):
        host = read(config)
        display_settings = host.get("displays", {}).get(display, {})
        raw = display_settings.get("measures", [])
        measures = dict(zip(raw[::2], raw[1::2])) if isinstance(raw, list) else raw
        key = [host.get("preferredDisplayID"), host["edge"], host.get("workspaces"), display_settings.get("placement"),
               display_settings.get("edge"), measures.get("reservedWidth", measures.get("panelWidth"))]
        if persist:
            save(trial.dir / "candidate.json", dict(configuration=host, ratio=ratio, swap=swap, keepIntent=explicit))
        return key

    previous = None
    try:
        publish(ready=True, directory=trial.dir.name)
        deadline = time.monotonic() + 440
        count = 0
        while time.monotonic() < deadline:
            need(trial.owner is None or trial.owner.poll() is None, "fixture closed or focus changed")
            ready, _, _ = select.select([sys.stdin], [], [], 0.25)
            cmd = sys.stdin.readline().strip() if ready else "poll"
            if cmd in ("", "end"):
                break
            layout = plan(False)
            if cmd == "poll" and (not count or layout == previous):
                continue
            plan()
            verb = "candidate-layout"
            if cmd == "add" and count < 5:
                if trial.owner is None:
                    trial.start_owner()
                count += 1
                trial.membership("create", count)
                if count == 2:
                    explicit = False
            elif cmd == "remove" and count > 1:
                trial.membership("close", count)
                count -= 1
            elif cmd.startswith("pair ") and count == 2:
                _, value, order = cmd.split()
                ratio, swap = float(value), order == "swap"
                need(.2 <= ratio <= .8 and order in ("swap", "original"), "invalid pair")
                explicit = True
                plan()
                verb = "candidate-pair"
            elif cmd != "poll":
                publish(ready=True, detail="当前窗口数不适用")
                continue
            result = trial.command(verb)
            previous = layout
            publish(ready=True, members=count, detail="AX / CG 已核对", errorPoints=result["maxModelError"])
        if count:
            plan()
            trial.command("candidate-exit")
    finally:
        trial.finish()
    publish(ready=False, members=0, detail="已关闭测试窗口")


if __name__ == "__main__":
    try:
        run(Path(sys.argv[1]))
    except Exception as error:
        print(json.dumps({"ready": False, "members": 0, "detail": str(error)}, ensure_ascii=False), flush=True)
        sys.exit(1)
