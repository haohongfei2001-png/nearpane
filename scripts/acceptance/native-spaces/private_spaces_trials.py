"""Connect one protected installed Host to its existing signed Spaces acceptance driver."""
from pathlib import Path
import json
import sys

from acceptance import identity
from space_scope import private_file, require
from contract_signing import verify_pair


def focus_lease(path):
    data = json.loads(private_file(path))
    for field in ("workspace", "originalCheckout", "documentKit", "originArchive", "signingChain", "dailyArchive"):
        p = Path(data[field])
        require(p.is_absolute() and p == p.resolve(strict=True), "Unresolved enrolled path: " + field)
    require(type(data["expectedSpace"]) is int and data["expectedSpace"] > 0, "Invalid enrolled ordinary desktop")
    require(Path(data["workspace"]).is_dir() and Path(data["documentKit"]).is_dir()
            and Path(data["originArchive"]).is_file() and Path(data["dailyArchive"]).is_file(), "Incomplete focus lease")
    return data


def extend_focus_chain(record, canonical, original_slot, out, gate, persist):
    """Re-read the two exchanged, signed bundles before binding the final lease transition."""
    plan = record["focusLease"]
    chain = json.loads(Path(plan["signingChain"]).read_bytes())
    require(chain.get("schema") == "nearpane-installed-signing-chain-v1" and isinstance(chain.get("intermediateInstalls"), list),
            "Original Space lease has no installation chain")
    old, new = identity(original_slot), identity(canonical)
    require(old["CDHash"] == record["original"]["cdhash"] and new["CDHash"] == record["candidate"]["cdhash"],
            "Protected transaction no longer owns the enrolled signatures")
    old_rule, new_rule = gate.designated_requirement(original_slot), gate.designated_requirement(canonical)
    require(gate.normalized_requirement(old_rule) == gate.normalized_requirement(new_rule), "Signed Host requirement changed")
    for rule, other in ((old_rule, canonical), (new_rule, original_slot)):
        gate.inspect(other)
        gate.cmd("/usr/bin/codesign", "--verify", "--strict", "-R=" + rule, str(other))
    pair = out / "focus-protected-pair.json"
    persist(pair, dict(bundlePath=str(canonical), deepSignatureValid=True, resourceAndRuntimeCheck=True,
                       continuityCheckedBothDirections=2, oldSignature=old, newSignature=new,
                       stableRequirement=old_rule))
    verify_pair(original_slot, canonical, pair)
    result = out / "focus-protected-chain.json"
    persist(result, {**chain, "intermediateInstalls": [*chain["intermediateInstalls"],
                    {"installedArchive": plan["dailyArchive"], "receipt": chain["finalInstallReceipt"]}],
                    "finalInstallReceipt": str(pair)})
    return result


def focus_command(here, record, out, chain, context):
    lease = record["focusLease"]
    scenario = record.get("focusScenario", "controlled-window")
    require(scenario in ("controlled-window", "pair-focus", "pair-pointer", "pair-drag", "pair-cross"), "Unrecognized ordinary-document scenario")
    context["NP_P2_DOCUMENT_KIT"] = record.get("pairKit", lease["documentKit"])
    return [sys.executable, here/"preview-on-lease.py", lease.get("stageKit",record["kit"]), lease["workspace"], out/"p2",
            "--expected-space", str(lease["expectedSpace"]), "--original-checkout", lease["originalCheckout"],
            "--previous-archive", lease["originArchive"], "--install-receipt", chain, "--scenario", scenario]


def diagnostic_command(here, record, out, chain=None):
    cmd = [sys.executable, here/"p0-host-diagnostic.py", record["kit"], out/"p0", "--issuer-key", record["issuerKey"]]
    if record.get("driftKit"):
        cmd.extend(["--drift-kit", record["driftKit"]])
    if chain is not None:
        lease = record["focusLease"]
        cmd.extend(["--stage-kit", lease["stageKit"], "--stage-workspace", lease["workspace"],
                    "--stage-space", str(lease["expectedSpace"]), "--stage-original-checkout", lease["originalCheckout"],
                    "--stage-previous-archive", lease["originArchive"], "--stage-install-receipt", chain])
    return cmd
