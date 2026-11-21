"""Correlate only the installed Host's fixed-format, content-free sidebar timing records."""
import json
import math
import re
import subprocess
import threading
import time
import uuid


LINE = re.compile(r"operation=([0-9a-fA-F-]{36}) phase=(click|beforeAX|exactFocus|returned|beforeApplicationActivation) "
                  r"route=(sidebar|host|worker|application) action=(none|main|frontmost|raise|focusedWindow|unminimize) "
                  r"uptime=([0-9]{1,12}\.[0-9]{1,9})")


def parse(line, pid):
    try:
        raw = json.loads(line)
        if (raw.get("processID") != pid or raw.get("category") != "WindowFocusLatency" or
                raw.get("subsystem") != "com.holdsnow.nearpane.alpha"):
            return None
        match = LINE.fullmatch(raw.get("eventMessage",""))
        if not match:
            return None
        op, phase, route, action, uptime = match.groups()
        clock = float(uptime)
        if not math.isfinite(clock) or clock <= 0:
            return None
        return {"operation":str(uuid.UUID(op)), "phase":phase, "route":route, "action":action, "uptime":clock}
    except (AttributeError,TypeError,ValueError):
        return None


PAIR_PHASES = {"cardDown","cardDrop","pairScopeRefused","pairAdmissionRefused","pairResolving","pairPlacing",
               "pairVerified","pairBindingIncomplete","pairListed","pairScopeChangedAfterBinding","cardClick",
               "pairUsingBoundWindows","pairFinalInventoryUnconfirmed"}
PAIR_STAGES = {"admission","prepareLeft","prepareRight","layout","lock","verifyLeftBeforeWrite",
               "verifyRightBeforeWrite","acquire","placeLeft","placeRight","verifyLeftAfterWrite",
               "verifyRightAfterWrite","record"}
PAIR_REFUSALS = {"busy","scope","stale","lost","noGrant","ownership","ambiguous","minimum","storage",
                 "unavailable","identity","membership","display","permission","conflict","recoveryRequired",
                 "invalidLayout","minimumSize","excluded","incompleteInventory","unmanaged","workerWriteUnconfirmed",
                 "workerRefused","cancelled","other"}
PAIR_LOSSES = {"feedInvalidated","intentUnavailable","topologyChanged","permissionDenied","stageEnabled",
               "spaceChanged","windowAbsent","identityChanged","membershipChanged","noLongerOrdinary"}


def pair_phase(line, pid):
    try:
        raw = json.loads(line)
        if (raw.get("processID") != pid or raw.get("category") != "SidebarPointer" or
                raw.get("subsystem") != "com.holdsnow.nearpane.alpha"):
            return None
        name = raw.get("eventMessage","")
        if name.startswith("phase=") and name[6:] in PAIR_PHASES:
            return {"phase":name[6:]}
        refused = re.fullmatch(r"phase=pairTransactionRefused stage=([a-zA-Z]+) reason=([a-zA-Z]+)",name)
        if refused and refused[1] in PAIR_STAGES and refused[2] in PAIR_REFUSALS:
            return {"phase":"pairTransactionRefused","stage":refused[1],"reason":refused[2]}
        loss = re.fullmatch(r"phase=pairBoundEvidenceRevoked reason=([a-zA-Z]+)",name)
        if loss and loss[1] in PAIR_LOSSES:
            return {"phase":"pairBoundEvidenceRevoked","reason":loss[1]}
        return None
    except (AttributeError,TypeError,ValueError):
        return None


def correlate(attempts, records, status):
    for attempt in attempts:
        bounds = attempt.get("pointerObservationRange")
        if not bounds:
            continue
        seen = [r for r in records if r["phase"] == "click" and r["route"] == "sidebar" and
                r["action"] == "none" and bounds[0] <= r["uptime"] <= bounds[1]]
        if len(seen) != 1 or status != "OBSERVED":
            attempt["hostButton"] = {"status":"UNAVAILABLE" if status != "OBSERVED" else
                                     "AMBIGUOUS" if seen else "NOT_OBSERVED", "matchingClicks":len(seen)}
            continue
        item = seen[0]
        attempt["hostButton"] = {
            "status":"OBSERVED", "operation":item["operation"], "clickUptime":item["uptime"],
            "downToCallbackMs":(item["uptime"]-bounds[0])*1000,
            "phases":[r for r in records if r["operation"] == item["operation"] and item["uptime"] <= r["uptime"] <= bounds[1]+1]
        }


class HostFocusTiming:
    def __init__(self, pid):
        self.pid = pid
        self.log = None
        self.thread = None
        self.records = []
        self.phases = []
        self.truncated = False

    def start(self):
        # This new isolated Host owns the checked profile. Only content-free entries
        # from its exact PID, public category, and strict schema are ever retained.
        predicate = (f'processID == {int(self.pid)} AND subsystem == "com.holdsnow.nearpane.alpha" '
                     'AND (category == "WindowFocusLatency" OR category == "SidebarPointer")')
        try:
            self.log = subprocess.Popen(["/usr/bin/log","stream","--style","ndjson","--level","info","--predicate",predicate],
                                        stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,stdin=subprocess.DEVNULL)
            self.thread = threading.Thread(target=self._read,daemon=True)
            self.thread.start()
        except (OSError,RuntimeError):
            self.close()

    def _read(self):
        stream = self.log.stdout
        try:
            for line in stream:
                if len(line) > 32768:
                    continue
                phase = pair_phase(line,self.pid)
                if phase and len(self.phases) < 192:
                    self.phases.append({**phase,"readAt":time.monotonic()})
                row = parse(line,self.pid)
                if row:
                    if len(self.records) < 256:
                        self.records.append(row)
                    else:
                        self.truncated = True
        except (OSError,ValueError):
            pass

    def close(self):
        if not self.log:
            return "UNAVAILABLE"
        running = self.log.poll() is None
        try:
            if running: self.log.terminate()
            self.log.wait(timeout=.8)
        except (OSError,subprocess.TimeoutExpired):
            try:
                self.log.kill()
                self.log.wait(timeout=.5)
            except (OSError,subprocess.TimeoutExpired):
                return "UNKNOWN"
        if self.thread and self.thread.ident:
            self.thread.join(timeout=.5)
        self.log.stdout.close()
        return "TRUNCATED" if self.truncated else "OBSERVED" if running and self.thread and self.thread.ident else "UNAVAILABLE"
