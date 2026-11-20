"""Optional receipt for one already authorized, PID-targeted Field Notes marker."""
import hashlib
import json
import os
import secrets
import tempfile
import time

from space_scope import private_file


PHASES = {"arm", "end", "appKeyDown", "appKeyUp", "windowKeyDown", "windowKeyUp", "editorKeyDown", "editorKeyUp",
          "insertText", "afterInsert", "setMarkedText", "afterMarked", "unmarkText"}
TERMINAL = {"SEALED", "EXPIRED", "EXITED", "UNAVAILABLE"}


class MarkerWatch:
    def __init__(self, folder, session, intent, pid, birth, numbers, target, marker, reader_hash):
        self.folder = folder
        self.identity = dict(session=session, intent=intent, pid=pid, birth=birth, numbers=numbers, target=target,
                             digest=hashlib.sha256(marker.encode()).hexdigest(), readerHash=reader_hash)
        self.grant = {**self.identity, "tag": 1 + secrets.randbits(62), "expires": time.monotonic() + 14}
        self.last = None
        self.sender = {"status":"NOT_ATTEMPTED"}

    def submitted(self):
        self.sender = {"status":"REPLY_UNKNOWN"}

    def dispatched(self, reply):
        tagged = (reply.get("issued") is True and reply.get("tagged") is True and reply.get("targetedOnly") is True and
                  reply.get("axFocusedWindow") == self.identity["target"] and reply.get("markerDigest") == self.identity["digest"] and
                  all(type(reply.get(k)) in (int,float) for k in ("beforePost","afterPost")) and
                  0 < reply["beforePost"] <= reply["afterPost"] < self.grant["expires"])
        self.sender = ({"status":"TAGGED_POST", "beforePost":reply["beforePost"], "afterPost":reply["afterPost"]} if tagged else
                       {"status":"REFUSED" if reply.get("issued") is False else "TAG_UNCONFIRMED"})
        return tagged

    def command(self, mode):
        with tempfile.NamedTemporaryFile(dir=self.folder, prefix=".marker-command-", delete=False) as f:
            name = f.name
            try:
                f.write(json.dumps({"mode": mode, "grant": self.grant}).encode())
                f.flush()
                os.replace(name, self.folder / "marker-watch-command.json")
            finally:
                if os.path.lexists(name):
                    os.unlink(name)

    def validate(self, value):
        if (not isinstance(value, dict) or any(value.get(k) != v for k, v in self.identity.items()) or
                set(value) != set(self.identity) | {"status", "events", "truncated"} or
                value.get("status") not in ("ARMED", "SEALED", "EXPIRED", "EXITED", "UNAVAILABLE") or
                type(value.get("truncated")) is not bool or not isinstance(value.get("events"), list) or len(value["events"]) > 64):
            return None
        numbers = self.identity["numbers"]
        previous = 0
        for e in value["events"]:
            if (not isinstance(e, dict) or set(e) - {"step", "clock", "key", "main", "active", "marked", "responders",
                                                      "eventWindow", "eventClock", "receiver", "markerMatches", "attribution"} or
                    not isinstance(e.get("step"), str) or e["step"] not in PHASES or type(e.get("clock")) not in (int, float) or
                    not 0 <= previous <= e["clock"] < 2**53 or type(e.get("active")) is not bool or
                    any(type(e.get(k)) is not int or e[k] not in [-1,0,*numbers] for k in ("key", "main"))):
                return None
            previous = e["clock"]
            for k in ("responders", "marked"):
                if not isinstance(e.get(k), list) or len(e[k]) != 2 or any(type(x) is not bool for x in e[k]):
                    return None
            for k in ("eventWindow", "receiver"):
                if k in e and (type(e[k]) is not int or e[k] not in [-1,0,*numbers]):
                    return None
            if "attribution" in e and e["attribution"] not in ("eventTag","signedSenderAndDigest"):
                return None
            if "markerMatches" in e and type(e["markerMatches"]) is not bool:
                return None
            if "eventClock" in e and (type(e["eventClock"]) not in (int,float) or not 0 <= e["eventClock"] < 2**53):
                return None
        return value

    def wait(self, wanted, timeout=.85):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            try:
                value = self.validate(json.loads(private_file(self.folder / "marker-watch-response.json", limit=65536)))
            except (OSError, ValueError):
                value = None
            if value is not None:
                self.last = value
                if value["status"] in wanted:
                    return value
            time.sleep(.025)
        return None

    def arm(self):
        self.command("arm")
        proof = self.wait({"ARMED"})
        return bool(proof and proof["events"] and proof["events"][0]["step"] == "arm" and not proof["truncated"])

    def seal(self):
        self.command("seal")
        closed = self.wait(TERMINAL)
        result = dict(closed or self.last or {**self.identity,"status":"NO_ACK","events":[],"truncated":False})
        result["sender"] = self.sender
        result["closureConfirmed"] = bool(closed and closed["status"] == "SEALED" and closed["events"] and closed["events"][-1]["step"] == "end")
        return result
