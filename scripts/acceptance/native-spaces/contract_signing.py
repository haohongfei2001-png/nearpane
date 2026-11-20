"""Verify both real code signatures before resuming a lease across a signed install."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import tempfile
import zipfile

from acceptance import APP, checked, digest, identity
from space_scope import require

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from candidate_signing import gate


def continuity(previous_archive, install_receipt, original_hash, live_hash):
    require(previous_archive and install_receipt, "changed Host needs --previous-archive and --install-receipt")
    archive = previous_archive.resolve()
    record = json.loads(install_receipt.read_bytes())
    require(record.get("deepSignatureValid") is True and record.get("resourceAndRuntimeCheck") is True
            and record.get("bundlePath") == str(APP) and record.get("continuityCheckedBothDirections",0) >= 2
            and record["oldSignature"].get("CDHash")==original_hash and record["newSignature"].get("CDHash")==live_hash,
            "installation receipt does not cover the old/new installed CDHashes")
    with zipfile.ZipFile(archive) as z:
        entries=z.infolist()
        require(0 < len(entries) < 8192 and sum(e.file_size for e in entries) < 1_000_000_000, "unbounded candidate archive")
        for entry in entries:
            path=PurePosixPath(entry.filename)
            require(not path.is_absolute() and '..' not in path.parts and path.parts[:1]==("Nearpane.app",), "unexpected archive path")
            if stat.S_ISLNK(entry.external_attr>>16):
                require(entry.file_size<4096,"invalid archive link")
                dest=PurePosixPath(z.read(entry).decode())
                require(not dest.is_absolute() and '..' not in dest.parts,"link escapes the candidate bundle")
    with tempfile.TemporaryDirectory(prefix="nearpane-contract-signatures-") as scratch:
        checked(["/usr/bin/ditto","-x","-k",str(archive),scratch],timeout=30)
        old=Path(scratch)/"Nearpane.app"
        for bundle,fields in ((old,record["oldSignature"]),(APP,record["newSignature"])):
            code=identity(bundle)
            require(code==fields and code.get("TeamIdentifier")==gate.PRODUCT_SIGNING_TEAM
                    and code.get("Identifier")==gate.PRODUCT_IDENTIFIERS["."], "archived or installed signed identity differs")
            checked(["/usr/bin/codesign","--verify","--strict","--deep",str(bundle)],timeout=30)
        old_rule, new_rule = gate.designated_requirement(old), gate.designated_requirement(APP)
        require(gate.normalized_requirement(old_rule)==gate.normalized_requirement(new_rule)==gate.normalized_requirement(record["stableRequirement"])
                and "anchor apple generic" in new_rule and gate.PRODUCT_SIGNING_TEAM in new_rule, "unstable Developer ID designated requirement")
        for rule,target in ((old_rule,APP),(new_rule,old)):
            checked(["/usr/bin/codesign","--verify","--strict","-R="+rule,str(target)],timeout=20)
    return dict(old=original_hash,new=live_hash,team=gate.PRODUCT_SIGNING_TEAM,bothDirections=True,
                installReceiptSHA256=digest(install_receipt),previousArchiveSHA256=digest(archive),
                requirementSHA256=hashlib.sha256(new_rule.encode()).hexdigest())
