"""Sign exactly one isolated Host request, without posting an AX, CG, or desktop action."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import time
import uuid

from installed_profile import APP, PROFILE, owns_profile, validate_home
from p0_session import matches_source
from space_scope import require

PREFIX = bytes.fromhex("302a300506032b6570032100")
SCOPE = "DIAGNOSTIC_ONLY"


def openssl():
    for program in (shutil.which("openssl"), "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"):
        if program and Path(program).is_file() and subprocess.check_output([program,"version"],text=True).startswith("OpenSSL 3."):
            return program
    raise ValueError("OpenSSL 3 Ed25519 issuer is unavailable")


def key_identity(key):
    info = key.lstat()
    require(key.resolve(strict=True) == key and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and info.st_nlink == 1 and not info.st_mode & 0o077 and not key.parent.stat().st_mode & 0o077,
            "expected the private campaign issuer key in its private staging directory")
    program = openssl()
    der = subprocess.check_output([program,"pkey","-in",key,"-pubout","-outform","DER"],timeout=3)
    require(der[:-32] == PREFIX and len(der) == 44, "issuer must be a campaign Ed25519 key")
    return program,der[-32:]


def signed_request(program,key,payload):
    # Ed25519 needs a seekable input on OpenSSL. No private key is copied or logged.
    data = json.dumps(payload,separators=(",",":"),sort_keys=True,allow_nan=False).encode()
    with tempfile.NamedTemporaryFile(dir=key.parent) as buffer:
        buffer.write(data)
        buffer.flush()
        signature = subprocess.check_output([program,"pkeyutl","-sign","-rawin","-inkey",key,"-in",buffer.name],timeout=3)
    require(len(signature) == 64, "unexpected Ed25519 signature size")
    return {"payload":base64.b64encode(data).decode(),"signature":base64.b64encode(signature).decode()}


class Issuer:
    def __init__(self,key,host):
        self.key = Path(key)
        self.program,self.public = key_identity(self.key)
        info = plistlib.loads((APP/"Contents/Info.plist").read_bytes())
        require(info.get("NearpaneP0DiagnosticPublicKey") == base64.b64encode(self.public).decode(),
                "running candidate has no sealed diagnostic key matching this issuer")
        self.home = Path(os.environ["NEARPANE_TEST_HOME"])
        validate_home(self.home)
        self.generation = Path(os.environ["NEARPANE_TEST_GENERATION"])
        self.revision = info["NearpaneSourceRevision"]
        self.host = host
        self.operation = str(uuid.uuid4())
        self.published = False
        self.endpoints = []
        self.spend = self.home.parent.parent/"nearpane-p0-diagnostic-spent"/hashlib.sha256(self.public).hexdigest()
        require(not os.path.lexists(self.spend), "this signed candidate's single dispatch slot has already been spent")
        index = json.loads((self.home/PROFILE/"profile-index.json").read_bytes())
        require(self.generation == self.home/PROFILE/"generations"/index["active"] and self.generation.resolve()==self.generation
                and self.generation.name == str(uuid.UUID(index["active"])) and owns_profile(host["pid"],self.home/PROFILE),
                "candidate and isolated generation writer are not bound")
        self.request = self.home/"p0-host-one-shot.json"
        self.response = self.home/"p0-host-one-shot-response.json"
        require(not any(os.path.lexists(p) for p in (self.request,self.response)), "this isolated profile already has a diagnostic request")

    def capabilities(self,kit):
        before=time.monotonic()
        for attempt in range(2):
            try:
                nonce=subprocess.check_output([kit/"metrics",str(self.host["pid"]),"--diagnostic-space-probe"],text=True,timeout=8).strip()
                break
            except (subprocess.CalledProcessError,subprocess.TimeoutExpired):
                if attempt: raise
                # The profile lock can precede the normal Host notification receiver at startup.
                time.sleep(.2)
        operation=str(uuid.UUID(nonce)).upper()
        proof_path=self.home/("p0-probe-"+operation+".json")
        require(proof_path.resolve(strict=True)==proof_path and proof_path.stat().st_uid==os.getuid()
                and proof_path.stat().st_nlink==1 and proof_path.stat().st_size<=4096, "untrusted probe receipt")
        proof=json.loads(proof_path.read_bytes())
        require(proof["nonce"]==proof["operation"]==operation and proof["action"]=="probe" and proof["state"]=="ready"
                and proof["canSwitch"] is False and proof["submittedSteps"]==0 and proof["issued"] is False
                and proof["pid"]==self.host["pid"] and proof["birth"]==self.host["birth"] and proof["generation"]==self.generation.name
                and proof["revision"]==self.revision and before<=proof["at"]<=time.monotonic()
                and type(proof["stageManagerOwnsDispatch"]) is bool and owns_profile(self.host["pid"],self.home/PROFILE),
                "nonce-matched signed Host and native worker did not confirm closed, zero-dispatch capability")
        return dict(ready=True,**proof)

    def enroll(self, window, space, topology):
        ident = {k:window[k] for k in ("pid","birth","number","executable","identifier","hash")}
        row = next(r for r in topology["records"] if r["id"]==space and r["type"]==0)
        require(len(self.endpoints)<2 and all(e["window"]["pid"]!=window["pid"] and e["space"]!=space for e in self.endpoints),
                "duplicate diagnostic document enrollment")
        self.endpoints.append(dict(window=ident,display=topology["display"],space=space,spaceUUID=row["uuid"]))
        now = time.monotonic()
        record = dict(intent="retain-fixture-originals",revision=self.revision,home=str(self.home),generation=self.generation.name,
                      hostPID=self.host["pid"],hostBirth=self.host["birth"],hostHash=self.host["hash"],issued=now,expires=now+240,
                      endpoints=self.endpoints)
        envelope=signed_request(self.program,self.key,record)
        with tempfile.NamedTemporaryFile(dir=self.home,delete=False,mode="w") as tmp:
            json.dump(envelope,tmp,separators=(",",":"))
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp.name,self.home/"p0-host-observe.json")

    def submit(self, pair, checkpoint, observer, workspace, keeper, folder, cmd):
        require(not self.published and not os.path.lexists(self.spend) and keeper is not None, "one-shot already used or fixture keeper unavailable")
        require(set(workspace.ids()) == {pair["topology"]["current"],pair["target"]} and len(workspace.ids()) == 2,
                "a source or destination is not owned by this run")
        top = workspace.check(workspace.read())
        require(top["current"] == pair["topology"]["current"] and top["records"] == pair["topology"]["records"]
                and top["scope"].upper() == pair["topology"]["display"].upper(), "complete owned display topology changed")
        claims = keeper.call("windows",[pair["sourceWindow"],pair["targetWindow"]]).get("windows",[])
        require(len(claims)==2 and all(row.get("standard") is True and row.get("forward") is True and row.get("reverse")==[space]
                for row,space in zip(claims,[pair["topology"]["current"],pair["target"]])), "fixture originals or membership changed")
        active = json.loads((observer.directory/"active.json").read_bytes())
        require(checkpoint.get("dispatchAuthorized") is False and matches_source(checkpoint,pair) and active.get("open") is True
                and active["session"]==checkpoint["session"]==observer.session and active["binding"]==checkpoint["binding"]
                and active["revision"]==checkpoint["revision"] and active["hid"]==pair["hid"] and active.get("spaceStable") is True
                and active["writer"]==observer.process.pid and 0 <= time.monotonic()-active["uptime"] <= .45,
                "independent admission no longer covers the exact focused source")
        monitor = cmd(workspace.kit/"p0-card","process",active["reader"])
        require(monitor.get("pid")==active["reader"] and Path(monitor["executable"]).name=="p0-drift-reader","reader generation unavailable")
        keys = ("pid","birth","number","identifier","executable","hash")
        stamp = time.monotonic()
        payload = dict(operation=self.operation,generation=self.generation.name,observerSession=observer.session,
                       observerPID=monitor["pid"],observerBirth=monitor["birth"],observerExecutable=monitor["executable"],observerHash=monitor["hash"],revision=self.revision,home=str(self.home),
                       hostPID=pair["hostPID"],hostBirth=pair["hostBirth"],hostHash=pair["hostHash"],issued=stamp,expires=stamp+7.5,
                       topology=pair["topology"],target=pair["target"],hid=pair["hid"],additionalHID=active["additionalHID"],
                       **{k:{field:pair[k][field] for field in keys} for k in ("sourceWindow","targetWindow")})
        envelope = signed_request(self.program,self.key,payload)
        raw = (json.dumps(envelope,separators=(",",":"))+"\n").encode()
        (folder/"signed-request.json").write_bytes(raw)
        (folder/"signed-fields.json").write_text(json.dumps(payload,indent=2)+"\n")
        # Rename-excl supplies an atomic, non-overwriting handoff. Pending means unknown after a crash.
        with tempfile.NamedTemporaryFile(dir=self.home,delete=False) as draft:
            name = draft.name
            draft.write(raw)
            draft.flush()
            os.fsync(draft.fileno())
        try:
            self.published = True
            os.link(name,self.request)
        finally:
            os.unlink(name)
        deadline = time.monotonic()+9
        while time.monotonic()<deadline:
            if self.response.is_file():
                result = json.loads(self.response.read_bytes())
                require(result["scope"]==SCOPE and str(uuid.UUID(result["operation"]))==self.operation
                        and result["hostPID"]==self.host["pid"] and stamp<=result["uptime"]<=time.monotonic(),
                        "response does not identify the signed request or current Host")
                accepted = result["state"]=="accepted-by-installed-host"
                return {"scope":SCOPE,"issued":accepted,"uptime":result["uptime"],"response":result,"error":None if accepted else result["state"],
                        "operation":self.operation}
            time.sleep(.045)
        return {"scope":SCOPE,"issued":None,"uptime":stamp,"operation":self.operation,
                "error":"signed request published; installed Host acknowledgement unavailable"}
