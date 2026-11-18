"""Admission of disposable desktops from the native provisioner's paired receipts."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import uuid

ROOT = Path(__file__).resolve().parents[3]
LEDGERS = ROOT / "build/verification/secondary-route-followup"


class ScopeError(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise ScopeError(reason)


def private_file(path, limit=131072):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, "unsafe or symbolic receipt path")
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as f:
            st = os.fstat(f.fileno())
            require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == os.getuid()
                    and st.st_mode & 0o077 == 0 and 0 < st.st_size <= limit, "unsafe receipt owner, mode or length")
            data = f.read(limit + 1)
    except FileNotFoundError as e:
        raise ScopeError("test Space creation manifest or receipt is missing") from e
    require(len(data) == st.st_size, "receipt changed while reading")
    return data


def guid(value):
    try:
        return str(uuid.UUID(value)).upper()
    except (TypeError, AttributeError, ValueError) as e:
        raise ScopeError("invalid UUID") from e


def positive(value):
    require(type(value) is int and value > 0, "invalid numeric identity")
    return value


def shape(snapshot):
    return {s["scope"]: [(r["id"], r["type"], r["uuid"]) for r in s["records"]] for s in snapshot["scopes"]}


def geometry_matches(archived, displays):
    if len(archived) != len(displays):
        return False
    for line in archived:
        fields = line.split(":")
        if len(fields) != 4:
            return False
        match = [d for d in displays if d["uuid"] == fields[0]]
        numbers = re.findall(r"-?\d+(?:\.\d+)?", fields[1])
        if len(match) != 1 or len(numbers) != 4:
            return False
        d = match[0]
        if [float(n) for n in numbers] != d["bounds"] or float(fields[2]) != d["rotation"] or float(fields[3]) != d["scale"]:
            return False
    return True


def validate_live(scope, observation, expected_host, require_highlight=True):
    require(observation.get("host") == expected_host == scope["host"] and observation.get("installedHostCount") == 1,
            "installed Host signing identity, PID or process generation changed")
    require(observation.get("observerAX") and observation.get("windowListAvailable"), "observer AX or real window inventory unavailable")
    require(observation["uptime"] < scope["expiresUptime"], "test scope expired")
    require(shape(observation) == scope["_shape"] and observation["displays"] == scope["_displays"],
            "display layout or Space UUID/order changed")
    require(all(s["current"] == scope["_others"][s["scope"]] for s in observation["scopes"] if s["scope"] != scope["display"]),
            "untargeted display changed its Space")
    current = next(s["current"] for s in observation["scopes"] if s["scope"] == scope["display"])
    ids = {s["id"] for s in scope["spaces"]}
    require(current in ids, "current Space is outside the test lease")
    occupancy = observation.get("otherLayerZeroMemberships", {})
    require(occupancy.get("unresolved") == 0, "unresolved window membership")
    for n in ids:
        count = sum(w["space"] == n for w in scope["witnesses"])
        require(occupancy.get("counts", {}).get(str(n), 0) == count, "extra or missing window on a leased Space")
    rows = observation.get("sidebar", {}).get("rows", [])
    for r in scope["spaces"]:
        expected = f'native-space-row:{scope["display"]}:{r["id"]}'
        matched = [v for v in rows if v["identifier"] == expected]
        require(len(matched) == 1 and matched[0]["matches"] == 1, "missing or duplicate installed sidebar Space row")
        if require_highlight:
            selected = matched[0].get("currentLabel") or matched[0].get("selected") is True
            require(bool(selected) == (r["id"] == current), "sidebar highlight differs from WindowServer")
    return current


def load_scope(path, observation, boot, now):
    scope = json.loads(private_file(path))
    require(scope.get("schema") == 1 and scope.get("boot") == boot, "wrong scope schema or boot")
    guid(scope["session"])
    scope["display"] = guid(scope["display"])
    until = scope["expiresUptime"]
    require(type(until) in (float, int) and math.isfinite(until) and now < until <= now + 900, "invalid lease duration")
    spaces = scope["spaces"]
    require(isinstance(spaces, list) and 2 <= len(spaces) <= 3, "two or three created test Spaces required")
    require(len({positive(s["id"]) for s in spaces}) == len(spaces)
            and len({guid(s["uuid"]) for s in spaces}) == len(spaces), "duplicate leased Space")
    host = scope["host"]
    positive(host["pid"])
    require(isinstance(host["launch"], (int, float)) and host["launch"] > 0 and re.fullmatch(r"[0-9a-fA-F]{40}", host["codeHash"]),
            "Host lacks launch and code identity")
    ordered = []
    last_issued = None
    for s in spaces:
        receipt = Path(s["receipt"])
        ledger = receipt.parent
        require(receipt.name == "created.json" and ledger.name == "provision"
                and ledger.parent.parent == LEDGERS and guid(ledger.parent.name), "unrecognized creation ledger")
        require(not any(os.path.lexists(ledger / n) for n in ("removed.json", "remove-intent.json")), "Space already removed or removal pending")
        data = private_file(receipt)
        require(hashlib.sha256(data).hexdigest() == s["sha256"], "creation receipt digest mismatch")
        made = json.loads(data)
        intent = json.loads(private_file(ledger / "create-intent.json"))
        require(made["intent"] == intent and guid(intent["operation"]) and guid(intent["display"]) == scope["display"]
                and intent["boot"] == boot, "creation intent does not match system receipt")
        issued = intent["issuedUptime"]
        require(0 <= now - issued < 900 and until <= issued + 900
                and (last_issued is None or issued > last_issued), "expired or reordered creation receipts")
        last_issued = issued
        before, after = intent["initial"], made["after"]
        n = str(s["id"])
        fullscreen = set(after.get("fullscreenIDs") or [])
        require(fullscreen == set(before.get("fullscreenIDs") or []) and fullscreen.issubset(before["sideOrder"])
                and intent["source"] not in fullscreen and n not in fullscreen, "fullscreen identity or type changed during creation")
        require(made["target"] == n and n not in before["sideOrder"] and after["sideOrder"].count(n) == 1 and
                [i for i in after["sideOrder"] if i != n] == before["sideOrder"] and intent["source"] in before["sideOrder"],
                "receipt does not prove exactly one new Space")
        require(set(before["sideOrder"]) == set(before.get("spaceUUIDs", {}))
                and set(after["sideOrder"]) == set(after.get("spaceUUIDs", {}))
                and all(after["spaceUUIDs"][k] == v for k, v in before["spaceUUIDs"].items())
                and guid(after["spaceUUIDs"][n]) == guid(s["uuid"]), "created Space UUID was not witnessed")
        require(before.get("primaryScope") == after.get("primaryScope")
                and before["geometry"] == after["geometry"] and geometry_matches(after["geometry"], observation["displays"]),
                "display changed after test Space creation")
        if ordered:
            require(before["sideOrder"] == ordered and before["spaceUUIDs"] == bound and fullscreen == bound_fullscreen,
                    "discontinuous independent creation receipts")
        ordered, bound, bound_fullscreen = after["sideOrder"], after["spaceUUIDs"], fullscreen
    live = next((s for s in observation["scopes"] if s["scope"] == scope["display"]), None)
    lease_ids = {s["id"] for s in spaces}
    require(live and [str(r["id"]) for r in live["records"]] == ordered
            and all(r["type"] == (4 if str(r["id"]) in bound_fullscreen else 0) and (r["id"] not in lease_ids or r["type"] == 0)
                    and guid(r["uuid"]) == guid(bound[str(r["id"])]) for r in live["records"]),
            "live inventory no longer matches provisioned identities")
    indices = sorted(ordered.index(str(s["id"])) for s in spaces)
    require(indices == list(range(indices[0], indices[-1] + 1)), "a personal Space interrupts the test route")
    witnesses = scope["witnesses"]
    require(isinstance(witnesses, list) and len(witnesses) <= 8 and len({positive(w["number"]) for w in witnesses}) == len(witnesses),
            "invalid fixture inventory")
    for w in witnesses:
        require(positive(w["pid"]) and positive(w["birth"]) and w["space"] in lease_ids
                and w["bundleID"] == "net.example.spaces-document" and re.fullmatch(r"[a-fA-F0-9]{40}", w["codeHash"])
                and Path(w["bundlePath"]).name == "Field Notes.app", "unrecognized test window owner")
        require(isinstance(w.get("state"), str), "missing disposable fixture attestation")
        state = Path(w["state"])
        kit = state.parent.parent
        require(state.name == "windows.json" and guid(state.parent.name) and kit.parent == Path("/private/tmp")
                and kit.name.startswith(("nearpane-wp5.", "nearpane-d01.", "nearpane-space-trials."))
                and Path(w["bundlePath"]) == kit / "Field Notes.app", "unrecognized disposable fixture location")
        receipt = json.loads(private_file(state))
        require(receipt["pid"] == w["pid"] and receipt["birth"] == w["birth"] and w["number"] in receipt["numbers"]
                and guid(receipt["session"]) == guid(state.parent.name), "current fixture did not attest this window generation")
    scope["_shape"], scope["_displays"] = shape(observation), observation["displays"]
    scope["_scopes"] = observation["scopes"]
    scope["_others"] = {s["scope"]: s["current"] for s in observation["scopes"] if s["scope"] != scope["display"]}
    validate_live(scope, observation, host)
    return scope
