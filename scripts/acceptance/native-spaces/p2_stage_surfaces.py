"""Carry only this run's two matching Stage-ON observations into a fresh Stage-OFF census."""
import importlib
import json
import math
import subprocess

from space_scope import require

LIMIT = 8
CATEGORY = "offscreenSignedWindowManagerSurface"


def lease_key(ws, space, space_uuid):
    return dict(boot=ws.boot, display=ws.display, space=space, spaceUUID=space_uuid,
                hostPID=ws.host["pid"], hostBirth=ws.host_birth, hostHash=ws.host["codeHash"])


def fingerprint(surface):
    number, pid, birth = (surface.get(k) for k in ("number", "pid", "ownerBirth"))
    bounds = surface.get("bounds")
    require(surface.get("admitted") is True and surface.get("category") == CATEGORY and
            surface.get("publicOnscreen") is False and surface.get("listedAsOwnDocument") is False and
            surface.get("pixels") == 0 and
            all(type(i) is int and i > 0 for i in (number, pid, birth)) and pid > 1 and
            isinstance(bounds, list) and len(bounds) == 4 and
            all(type(v) in (int, float) and math.isfinite(v) for v in bounds) and min(bounds[2:]) > 2,
            "invalidStageSurfaceEnrollment")
    return dict(number=number, pid=pid, ownerBirth=birth, bounds=bounds)


def lease_enrollment(ws, space, space_uuid, original_stage, reads):
    require(type(original_stage) is bool and len(reads) == 2 and
            reads[1]["uptime"] > reads[0]["uptime"] and
            all(row["ordinary"] == 0 and row["unresolved"] == 0 for row in reads),
            "twoIndependentStageAdmissionsRequired")
    lists = []
    for row in reads:
        surfaces = row["inactiveStageSurfaces"]
        require(len(surfaces) <= LIMIT and (original_stage or not surfaces), "stageOnEnrollmentUnavailable")
        group = sorted((fingerprint(r) for r in surfaces), key=lambda item: item["number"])
        require(len({r["number"] for r in group}) == len(group) and
                len({(r["pid"], r["ownerBirth"]) for r in group}) <= 1, "ambiguousStageManagerGeneration")
        lists.append(group)
    require(lists[0] == lists[1], "stageSurfaceEnrollmentChanged")
    return dict(key=lease_key(ws, space, space_uuid), sourceStage=original_stage,
                clocks=[r["uptime"] for r in reads], surfaces=lists[0])


def fresh_ordinary_reader(ws, binding, enrollment, observer, record=None):
    key = lease_key(ws, binding["space"], binding["spaceUUID"])
    if enrollment is None:
        references = []  # An entry without Stage-ON enrollment can only launch on a genuinely empty lease.
    else:
        require(key == enrollment["key"] and (not enrollment["surfaces"] or enrollment["sourceStage"] is True),
                "stageSurfaceLeaseOrHostGenerationChanged")
        references = enrollment["surfaces"]
    by_id = {r["number"]: r for r in references}
    last_clock = None

    def read(members):
        nonlocal last_clock
        require(isinstance(members, list) and len(members) <= LIMIT and
                all(type(m.get("number")) is int and type(m.get("pid")) is int and
                    m["number"] in by_id and m["pid"] == by_id[m["number"]]["pid"] for m in members),
                "unregisteredOrdinaryWindowOnStageOffLease")
        ids = sorted(m["number"] for m in members)
        require(len(set(ids)) == len(ids), "duplicateOrdinaryMembership")
        query = {**key, "enrolled": references, "present": ids}
        proc = subprocess.run([observer, "p2-stage-surface"], input=json.dumps(query), text=True, capture_output=True,
                              timeout=5, env=importlib.import_module("preview-workspace").login_env())
        require(proc.returncode == 0, "stageOffSurfaceReaderFailed")
        reply = json.loads(proc.stdout)
        if record:
            record("P2-stage-off-ordinary-census", **reply)
        require(reply.get("status") == "READ", str(reply.get("reason", "stageOffCensusUnavailable"))[:120])
        clock = reply.get("uptime")
        after = last_clock if last_clock is not None else (enrollment["clocks"][-1] if enrollment else 0)
        require(type(clock) in (int, float) and math.isfinite(clock) and clock > after, "staleStageSurfaceCensus")
        last_clock = clock
        kept = reply.get("surfaces", [])
        require(reply.get("stageEnabled") is False and reply.get("scope") == key and
                len(kept) == len(ids) and [fingerprint(r) for r in kept] == [by_id[n] for n in ids] and
                reply.get("departed") == sorted(set(by_id) - set(ids)) and all(
                    r.get("cgOnscreenListed") is False and r.get("appKitListed") is False and
                    r.get("forwardAndReverse") is True for r in kept), "stageOffSurfaceReadbackMismatch")
        return kept

    return read
