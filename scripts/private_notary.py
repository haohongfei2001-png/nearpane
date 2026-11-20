#!/usr/bin/env python3
"""Prepare and reconcile a private Nearpane notary archive. Uploads are an external operation."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
import zipfile

import candidate_signing as signing

gate = signing.gate
BUNDLE = "Nearpane.app"
release = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-candidate.py"))
publisher = importlib.util.module_from_spec(release)
release.loader.exec_module(publisher)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size < 6_000_000, "unreadable JSON record")
    return json.loads(path.read_bytes())


def save(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", delete=False) as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(f.name, path)


def archive_names(archive):
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        require(0 < len(entries) < 8192 and sum(i.file_size for i in entries) < 1_000_000_000,
                "archive member or size limit")
        seen, links, parents = set(), set(), set()
        for e in entries:
            path = PurePosixPath(e.filename)
            name = e.filename.rstrip("/")
            require(path.as_posix() == name and not path.is_absolute() and ".." not in path.parts and
                    "\\" not in name and name.casefold() not in seen, "ambiguous archive member")
            seen.add(name.casefold())
            mode = e.external_attr >> 16
            if path.parts[0] == "__MACOSX":
                # ditto preserves a stapled package's AppleDouble data. Its actual bundle member must exist.
                require(path.parts == ("__MACOSX",) or
                        len(path.parts) >= 2 and (path.parts[1] == BUNDLE or path.parts == ("__MACOSX", "._"+BUNDLE)),
                        "foreign AppleDouble root")
                require(e.is_dir() or path.name.startswith("._") and stat.S_ISREG(mode), "unexpected AppleDouble payload")
            else:
                require(path.parts[0] == BUNDLE, "unexpected bundle root")
                require(stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode), "unexpected entry type")
                if stat.S_ISLNK(mode):
                    require(0 < e.file_size < 4096, "invalid bundle link")
                    target = PurePosixPath(z.read(e).decode())
                    require(not target.is_absolute() and ".." not in target.parts, "nonlocal bundle link")
                    links.add(name.casefold())
                parents.update(str(p).casefold() for p in path.parents)
        require(not links.intersection(parents), "archive contains children of a link")
        for name in seen:
            if name.startswith("__macosx/") and "/._" in name:
                target = name.removeprefix("__macosx/").replace("/._","/").removeprefix("._")
                require(target in seen, "AppleDouble entry has no matching bundle object")


def unpack(archive, dest):
    archive_names(archive)
    gate.cmd("/usr/bin/ditto", "-x", "-k", str(archive), str(dest))
    app = dest / BUNDLE
    require(app.is_dir() and app.resolve() == app, "unpacked application identity changed")
    return app


def archive_app(app, dest):
    gate.cmd("/usr/bin/ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", str(app), str(dest))


def code_slice(path, arch):
    output = gate.cmd("/usr/bin/codesign", "--display", "--architecture", arch, "--verbose=4", str(path))
    fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    require("Authority=Developer ID Application:" in output and fields.get("TeamIdentifier") == gate.PRODUCT_SIGNING_TEAM
            and bool(fields.get("Timestamp")) and re.search(r"flags=0x[0-9a-f]+\([^)]*\bruntime\b", output)
            and re.fullmatch(r"[0-9A-Fa-f]{40}", fields.get("CDHash","")), "incomplete distribution signature for "+arch)
    return dict(cdhash=fields["CDHash"].lower(), secureTimestamp=fields["Timestamp"], team=fields["TeamIdentifier"])


def helper_pins(app, info):
    contents=app/"Contents"
    fixture=contents/"Helpers/NearpaneFixtureWindows.app/Contents"
    fixture_info=plistlib.loads((fixture/"Info.plist").read_bytes())
    subjects=[(contents/"Helpers/NearpaneDesktopReader",info["NearpaneDesktopReaderSHA256"]),
              (contents/"Helpers/NearpaneOrdinaryWindowController",info["NearpaneOrdinaryWindowControllerSHA256"]),
              (contents/"Helpers/NearpaneSpaceAction",info["NearpaneSpaceActionSHA256"]),
              (fixture/"Helpers/NearpaneDesktopReader",fixture_info["NearpaneDesktopReaderSHA256"]),
              (contents/"Resources/AcceptanceTargetGuard.js",info["NearpaneDraftGuardSHA256"])]
    subjects.extend((contents/relative,expected) for relative,expected in info["NearpaneAutomationSHA256"].items())
    pins={}
    for path,expected in subjects:
        require(path.is_file() and path==path.resolve() and sha(path)==expected,"packaged helper or resource pin mismatch")
        pins[str(path.relative_to(contents))]=expected
    return pins


def fingerprint(app, revision):
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "expected a full frozen source revision")
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    require((info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), info.get("NearpaneSourceState"),
             info.get("NearpaneSourceRevision")) == ("5.22", "90", "clean", revision), "version, build or frozen source differs")
    package = gate.inspect(app)
    gate.verify_install_identity(app)
    require(not package["missingDistributionSignatures"], "at least one binary lacks its distribution signature")
    expected = set(gate.update_runtime.EXECUTABLES)
    for name in gate.PRODUCT_IDENTIFIERS:
        item = app/name
        if item.is_dir():
            identifier = plistlib.loads((item/"Contents/Info.plist").read_bytes())["CFBundleExecutable"]
            item = item/"Contents/MacOS"/identifier
        expected.add(str(item.relative_to(app)))
    binaries = package["binaries"]
    require({"Contents/"+key for key in binaries} == expected and len(expected)==13, "frozen binary inventory differs")
    inventory = {}
    for rel, meta in binaries.items():
        path = app/"Contents"/rel
        requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{gate.PRODUCT_SIGNING_TEAM}" '
                       'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
        gate.cmd("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R="+requirement, str(path))
        inventory[rel] = dict(sha256=meta["sha256"], designatedRequirement=meta["designatedRequirement"],
                              slices={a:code_slice(path,a) for a in meta["architectures"]})
    return dict(source=revision, version="5.22", build="90", bundle=info["CFBundleIdentifier"], binaries=inventory,
                helperResourcePins=helper_pins(app,info),sparklePublicKeyConfigured=bool(info.get("SUPublicEDKey")))


def same_code(left, right):
    # codesign formats its timestamp in the scanner's locale/time zone. Each scan
    # independently requires a secure timestamp on every slice. Compare the signed
    # bytes and slice CDHashes themselves across different Macs.
    def canonical(record):
        return (record["source"], record.get("version"), record.get("build"), record.get("bundle"), record.get("helperResourcePins"), record.get("sparklePublicKeyConfigured"),
                {rel:(m.get("sha256"),m.get("designatedRequirement"),
                      {arch:(sl["cdhash"],sl.get("team"),bool(sl.get("secureTimestamp")))
                       for arch,sl in m["slices"].items()}) for rel,m in record["binaries"].items()})
    return canonical(left)==canonical(right)


def private_dir(path):
    s = path.lstat()
    require(path == path.resolve() and stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and not s.st_mode & 0o077,
            "expected a canonical, private owned session directory")


def input_zip(path, expected):
    require(path.is_file() and not path.is_symlink() and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]+\.zip", path.name)
            and re.fullmatch(r"[a-f0-9]{64}",expected or "") and sha(path)==expected, "archive name or SHA-256 differs")


def prepare(source, destination, revision, expected):
    require(not destination.exists() and not destination.is_symlink(), "session exists; use verify to resume")
    require(destination.parent == destination.parent.resolve(strict=True), "session parent is not canonical")
    with tempfile.TemporaryDirectory(prefix=".notary-prepare.", dir=destination.parent) as build:
        stage = Path(build)
        session = stage/"session"
        session.mkdir(mode=0o700)
        if source.suffix == ".zip":
            input_zip(source,expected)
            archive = session/source.name
            shutil.copyfile(source,archive)
            input_zip(archive,expected)
        else:
            require(source.name == BUNDLE and source.resolve(strict=True) == source and expected is None,
                    "expected a normal Nearpane.app or pinned ZIP")
            source_identity = fingerprint(source,revision)
            archive = session/("Nearpane-5.22-90-"+revision[:12]+".zip")
            archive_app(source,archive)
        with tempfile.TemporaryDirectory(dir=stage) as copy:
            identity = fingerprint(unpack(archive,Path(copy)),revision)
        if source.suffix != ".zip":
            require(same_code(source_identity,identity), "app source changed during archive creation")
        result = dict(status="PREPARED", archive=archive.name, sha256=sha(archive), candidate=identity,
                      upload="NOT_RUN", notarization="NOT_RUN", staple="NOT_RUN", cleanMacInstall="NOT_RUN",
                      cleanMacUpgradeRollback="NOT_RUN", publicRelease=False)
        save(session/"prepared.json",result)
        publisher.rename(session,destination,4)
    return result


def verified(session, work):
    private_dir(session)
    record = read_json(session/"prepared.json")
    require(record["status"] == "PREPARED" and Path(record["archive"]).name == record["archive"], "invalid prepared record")
    archive = session/record["archive"]
    input_zip(archive,record["sha256"])
    app = unpack(archive,work)
    require(same_code(fingerprint(app,record["candidate"]["source"]),record["candidate"]), "prepared code inventory changed")
    return record, app


def job_for(prepared, submitted, info):
    job = str(uuid.UUID(submitted["id"]))
    require(job == submitted["id"] == info.get("id") and info.get("name") == prepared["archive"],
            "Apple job ID or reported filename differs")
    return job


def accepted(prepared, submitted, info, log):
    job = job_for(prepared, submitted, info)
    require(job == log.get("jobId"), "Apple job IDs differ")
    require(info.get("name") == prepared["archive"] == log.get("archiveFilename") and
            prepared["sha256"] == str(log.get("sha256","")).lower(), "Apple record belongs to another archive")
    require(info.get("status") == log.get("status") == "Accepted" and type(log.get("statusCode")) is int
            and log["statusCode"] == 0, "Apple job has no accepted result")
    expected = {(f'{prepared["archive"]}/{BUNDLE}/Contents/{rel}',arch,sl["cdhash"])
                for rel,meta in prepared["candidate"]["binaries"].items() for arch,sl in meta["slices"].items()}
    entries=log.get("ticketContents")
    require(isinstance(entries,list) and all(isinstance(e,dict) for e in entries), "Apple ticket contents unavailable")
    available = {(e.get("path"),e.get("arch"),str(e.get("cdhash","")).lower()) for e in entries
                 if str(e.get("digestAlgorithm","")).upper()=="SHA-256"}
    require(expected <= available, "Apple ticket does not identify every enrolled binary slice")
    return job


def reconciliation(prepared, submitted, info, log=None):
    job=job_for(prepared,submitted,info)
    status=info.get("status")
    require(status in ("In Progress","Invalid","Rejected","Accepted"),"unrecognized Apple job status")
    result=dict(job=job, reportedStatus=status, archive=prepared["archive"], inputSHA256=prepared["sha256"],
                matchesAppleArchiveDigest=False, ticketValidated=False)
    if log is None:
        result["status"]="SERVICE_ACCEPTED_AWAITING_LOG" if status=="Accepted" else status.upper().replace(" ","_")
        return result
    require(log.get("jobId")==job and log.get("archiveFilename")==prepared["archive"] and
            str(log.get("sha256","")).lower()==prepared["sha256"] and log.get("status")==status,
            "Apple log does not describe this job and archive")
    result["matchesAppleArchiveDigest"]=True
    if status=="Accepted":
        accepted(prepared,submitted,info,log)
        result["status"]="ACCEPTED_EXACT_ARCHIVE"
    else:
        result["status"]=status.upper().replace(" ","_")
    return result


def gatekeeper(app):
    assessed=gate.cmd("/usr/sbin/spctl","--assess","--type","execute","--verbose=4",str(app))
    require("source=Notarized Developer ID" in assessed.splitlines(), "no local Notarized Developer ID assessment")
    gate.cmd("/usr/bin/syspolicy_check","distribution",str(app),"--json")
    return {"spctl":"Notarized Developer ID","syspolicyCheck":"PASS","scope":"current Mac only"}


def finalize(session, submitted, info, log):
    stage_name="preparedIdentity"
    with tempfile.TemporaryDirectory(dir=session,prefix=".staple.") as staging:
        work=Path(staging)
        try:
            prepared,app=verified(session,work)
            stage_name="AppleResult"
            job=accepted(prepared,read_json(submitted),read_json(info),read_json(log))
            output=session/"stapled"
            if output.exists():
                rec=read_json(output/"result.json")
                require(rec["job"]==job and rec["inputSHA256"]==prepared["sha256"],"existing result differs")
                final=output/rec["archive"]
                require(final.parent==output and final.name=="Nearpane-stapled.zip","unexpected final archive")
                input_zip(final,rec["sha256"])
            else:
                stage_name="ticketStaple"
                gate.cmd("/usr/bin/xcrun","stapler","staple",str(app))
                gate.cmd("/usr/bin/xcrun","stapler","validate",str(app))
                require(same_code(fingerprint(app,prepared["candidate"]["source"]),prepared["candidate"]), "code changed during stapling")
                staging=work/"delivery"
                staging.mkdir(mode=0o700)
                final=staging/"Nearpane-stapled.zip"
                archive_app(app,final)
            stage_name="finalArchiveReadback"
            with tempfile.TemporaryDirectory(dir=work) as reread:
                restored=unpack(final,Path(reread))
                require(same_code(fingerprint(restored,prepared["candidate"]["source"]),prepared["candidate"]),"final code differs")
                gate.cmd("/usr/bin/xcrun","stapler","validate",str(restored))
                local=gatekeeper(restored)
            result=dict(status="STAPLED_ARCHIVE_VERIFIED", job=job, source=prepared["candidate"]["source"],
                        inputSHA256=prepared["sha256"], archive=final.name, sha256=sha(final), localGatekeeper=local,
                        cleanMacInstall="NOT_RUN", cleanMacUpgradeRollback="NOT_RUN", publicRelease=False)
            if not output.exists():
                save(final.parent/"result.json",result)
                publisher.rename(final.parent,output,4)
            return result
        except (OSError,ValueError,KeyError,subprocess.CalledProcessError) as exc:
            save(session/"last-finalize-failure.json",dict(status="BLOCKED",stage=stage_name,
                 reason=str(exc) if isinstance(exc,ValueError) else type(exc).__name__,originalArchiveRetained=True))
            raise


def rollback_check(session, previous, previous_hash, revision):
    input_zip(previous,previous_hash)
    with tempfile.TemporaryDirectory(prefix=".rollback.",dir=session) as tmp:
        work=Path(tmp)
        (work/"new").mkdir();(work/"old").mkdir()
        prepared,new=verified(session,work/"new")
        old=unpack(previous,work/"old")
        before=fingerprint(old,revision)
        require(before["source"]!=prepared["candidate"]["source"], "rollback needs two distinct source revisions")
        signing.check_continuity(old,new)
        for relative,_ in gate.update_runtime.COMPONENTS:
            for source,target in ((old/relative,new/relative),(new/relative,old/relative)):
                rule=gate.designated_requirement(source)
                gate.cmd("/usr/bin/codesign","--verify","--strict","--all-architectures","-R="+rule,str(target))
        publisher.rename(old,new,2)
        try:
            require(same_code(fingerprint(old,prepared["candidate"]["source"]),prepared["candidate"]),"private replacement differs")
        finally:
            publisher.rename(old,new,2)
        require(same_code(fingerprint(old,revision),before) and same_code(fingerprint(new,prepared["candidate"]["source"]),prepared["candidate"]),
                "previous and candidate identities did not recover")
        result=dict(status="PRIVATE_PACKAGE_ROUNDTRIP_VERIFIED",scope="two non-running private unpacked bundles",
                    previousSource=revision, previousSHA256=previous_hash,currentSHA256=prepared["sha256"],
                    permissionSubjects=len(gate.PRODUCT_IDENTIFIERS),
                    mutualSigningRequirements=len(gate.PRODUCT_IDENTIFIERS)+len(gate.update_runtime.COMPONENTS),codeRestored=True,oldArchiveUnchanged=sha(previous)==previous_hash,
                    installed=False,userDataOrPermissionsTested=False)
        save(session/"private-rollback.json",result)
        return result


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    cmds=parser.add_subparsers(dest="action",required=True)
    new=cmds.add_parser("prepare");new.add_argument("input",type=Path);new.add_argument("session",type=Path)
    new.add_argument("--source",required=True);new.add_argument("--sha256")
    check=cmds.add_parser("verify");check.add_argument("session",type=Path)
    state=cmds.add_parser("reconcile");state.add_argument("session",type=Path)
    for key in ("submission","info","log"):state.add_argument("--"+key,type=Path,required=key!="log")
    final=cmds.add_parser("finalize");final.add_argument("session",type=Path)
    for key in ("submission","info","log"):final.add_argument("--"+key,type=Path,required=True)
    roll=cmds.add_parser("rollback-check");roll.add_argument("session",type=Path);roll.add_argument("previous",type=Path)
    roll.add_argument("--sha256",required=True);roll.add_argument("--source",required=True)
    a=parser.parse_args()
    session=a.session.absolute()
    if a.action=="prepare":
        result=prepare(a.input.absolute(),session,a.source,a.sha256)
    else:
        private_dir(session)
        with contextlib.ExitStack() as stack:
            fd=os.open(session,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            stack.callback(os.close,fd)
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if a.action=="verify":
                work=stack.enter_context(tempfile.TemporaryDirectory(dir=session))
                record,_=verified(session,Path(work))
                result=dict(status="PREPARED_VERIFIED",source=record["candidate"]["source"],sha256=record["sha256"])
            elif a.action=="reconcile":
                work=stack.enter_context(tempfile.TemporaryDirectory(dir=session))
                record,_=verified(session,Path(work))
                result=reconciliation(record,read_json(a.submission),read_json(a.info),read_json(a.log) if a.log else None)
                save(session/"notary-state.json",result)
            elif a.action=="finalize":
                result=finalize(session,a.submission,a.info,a.log)
            else:
                result=rollback_check(session,a.previous,a.sha256,a.source)
    print(json.dumps({k:v for k,v in result.items() if k!="candidate"},indent=2))


if __name__=="__main__":
    try:main()
    except (OSError,ValueError,KeyError,zipfile.BadZipFile,subprocess.CalledProcessError) as err:
        raise SystemExit(str(err))
