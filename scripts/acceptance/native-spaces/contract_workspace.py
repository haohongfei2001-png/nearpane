"""Prepare disposable ordinary desktops via Mission Control and recover only journalled creations."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from acceptance import checked, encode
from space_scope import LEDGERS, ScopeError, private_file, require


def write_owned(path, obj):
    data = encode(obj).encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def row(o):
    require(len(o["scopes"] or []) == len(o["displays"]) == 1, "contract fixture needs one physical display")
    s = o["scopes"][0]
    require(s["scope"] == o["displays"][0]["uuid"] and len({r["id"] for r in s["records"]}) == len(s["records"])
            and all(r.get("uuid") and r["type"] in (0, 4) for r in s["records"]), "incomplete real display/Space identity")
    return s


def addition(old, new):
    ids = {r["id"] for r in old}
    extra = [r for r in new if r["id"] not in ids]
    require(len(extra) == 1 and extra[0]["type"] == 0 and extra[0]["uuid"] not in {r["uuid"] for r in old}
            and [r for r in new if r != extra[0]] == old, "new topology does not prove exactly one ordinary Space insertion")
    return extra[0]


def stats(s, display):
    b = display["bounds"]
    geometry = f'{display["uuid"]}:{{{{{b[0]}, {b[1]}}}, {{{b[2]}, {b[3]}}}}}:{display["rotation"]}:{display["scale"]}'
    return dict(primaryScope=None, geometry=[geometry], sideOrder=[str(r["id"]) for r in s["records"]],
                spaceUUIDs={str(r["id"]):r["uuid"] for r in s["records"]}, fullscreenIDs=[str(r["id"]) for r in s["records"] if r["type"] == 4])


class Workspace:
    def __init__(self, kit, output, record, resume=False):
        self.kit, self.output, self.record = kit, output, record
        self.boot = checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip()
        self.ledgers = []
        self.closed = []
        self.original = self.read()
        if resume:
            self.original = json.loads(private_file((output/"original.json").resolve()))
            require(self.boot == self.original["boot"], "a different boot cannot resume desktop cleanup")
            for entry in sorted(output.glob("desktop-*.json")):
                ref = json.loads(private_file(entry.resolve()))
                p = Path(ref["receipt"]); raw = private_file(p)
                require(LEDGERS == p.parent.parent.parent and p.name == "created.json" and p.parent.name == "provision"
                        and hashlib.sha256(raw).hexdigest() == ref["sha256"], "unrecognized cleanup journal")
                self.ledgers.append(p)
                if (p.parent/"removed.json").exists():
                    self.closed.append(int(json.loads(raw)["target"]))
        else:
            self.original["boot"] = self.boot
            write_owned(output/"original.json", self.original)
        s = row(self.original)
        self.home, self.display = s["current"], s["scope"]
        require(any(r["id"] == self.home and r["type"] in (0, 4) for r in s["records"]), "original active Space identity unavailable")
        require(self.original.get("observerAX") is True and self.original.get("host") and self.original.get("installedHostCount") == 1,
                "installed Host and observer AX required")
        self.hid = self.hardware()
        self.check(self.read())

    def hardware(self):
        return [int(x) for x in checked([str(self.kit/"system-workspace"),"hid"]).strip().split(",")]

    def read(self):
        env=os.environ.copy()
        if self.ledgers and self.ids():env["NEARPANE_CONTRACT_SPACE_IDS"]=",".join(map(str,self.ids()))
        return json.loads(checked([str(self.kit/"observe")], timeout=8, env=env))

    def ids(self):
        created = (int(json.loads(private_file(p))["target"]) for p in self.ledgers)
        return [n for n in created if n not in self.closed]

    def check(self, o):
        require(o["host"] == self.original["host"] and o["displays"] == self.original["displays"], "installed Host or physical displays changed")
        s = row(o)
        existing = row(self.original)["records"]
        leased = {int(v["target"]):v["after"]["spaceUUIDs"][v["target"]]
                  for v in (json.loads(private_file(p)) for p in self.ledgers) if int(v["target"]) not in self.closed}
        require([r for r in s["records"] if r["id"] not in leased] == existing
                and {r["id"]:r["uuid"] for r in s["records"] if r["id"] in leased and r["type"] == 0} == leased,
                "existing desktop order, original identities or leased desktop membership changed")
        require(s["current"] == self.home or s["current"] in leased, "unrelated desktop became current")
        return s

    def command(self, name, snapshot, target=None, other=None):
        s = self.check(snapshot)
        require(self.hardware() == self.hid, "physical input changed; further workspace input suspended")
        req = dict(command=name, display=self.display, records=s["records"], current=s["current"], original=self.home,
                   owned=self.ids(), target=target, other=other, hostPID=self.original["host"]["pid"], hid=self.hid)
        self.record("system-fixture-intent", operation=name, current=s["current"], target=target, other=other)
        call = subprocess.run([str(self.kit/"system-workspace")], input=json.dumps(req), text=True, capture_output=True, timeout=20)
        try:
            out = json.loads(call.stdout)
        except ValueError as exc:
            raise ScopeError(f"{name}: system operator did not return an input receipt") from exc
        self.record("system-fixture-result", operation=name, target=target, **out)
        require(call.returncode == 0 and out.get("acknowledged") and out.get("issued"), f'{name}: {out.get("reason","native input not acknowledged")}')

    def settled(self, condition, description, duration=5):
        last = None; count = 0
        end = time.monotonic()+duration
        while time.monotonic() < end:
            o = self.read()
            require(o["host"] == self.original["host"] and o["displays"] == self.original["displays"], "observer lost installed Host/display")
            s = row(o)
            if condition(o) and s == last:
                count += 1
                if count >= 1: return o
            else:count = 0
            last = s
            time.sleep(.1)
        raise ScopeError(description)

    def create(self):
        before = self.read(); s = self.check(before)
        folder = LEDGERS / str(uuid.uuid4()) / "provision"
        folder.mkdir(mode=0o700, parents=True)
        intent = dict(operation=str(uuid.uuid4()), display=self.display, boot=self.boot, source=str(s["current"]),
                      initial=stats(s,before["displays"][0]), issuedUptime=before["uptime"])
        write_owned(folder/"create-intent.json",intent)
        self.record("creation-ledger", path=str(folder), operation=intent["operation"])
        self.command("add",before)
        after = self.settled(lambda o: len(row(o)["records"]) == len(s["records"])+1, "no stable one-Space creation delta")
        current = row(after); new = addition(s["records"],current["records"]); n = str(new["id"])
        made = dict(intent=intent,target=n,after=stats(current,after["displays"][0]))
        p = folder/"created.json"; write_owned(p,made)
        self.ledgers.append(p)
        write_owned(self.output/f"desktop-{len(self.ledgers)}.json",dict(receipt=str(p),sha256=hashlib.sha256(private_file(p)).hexdigest()))
        self.record("system-fixture-created", desktop=new, oldCurrent=s["current"], newCurrent=current["current"])
        self.check(after)
        return new["id"]

    def select(self,n):
        before = self.read(); s = self.check(before)
        require(n == self.home or n in self.ids(), "system selection outside fixture")
        if s["current"] != n:
            self.command("select",before,n)
        return self.settled(lambda o: self.check(o)["current"] == n and row(o)["records"]==s["records"], "system selection did not arrive")

    def swap(self,a,b):
        before = self.read(); s = self.check(before); order=s["records"].copy()
        ids=[r["id"] for r in order]; left,right=ids.index(a),ids.index(b)
        require(a in self.ids() and b in self.ids() and abs(left-right)==1,"only adjacent owned desktops may be reordered")
        order[left],order[right]=order[right],order[left]
        self.command("swap",before,a,b)
        return self.settled(lambda o: self.check(o)["records"]==order and row(o)["current"]==s["current"], "native drag did not exchange only the two enrolled desktops")

    def cleanup(self):
        failures=[]
        if self.ids():
            try:self.select(self.home)
            except (ValueError,OSError,subprocess.SubprocessError) as exc:failures.append(str(exc))
        for p in reversed(self.ledgers):
            if (p.parent/"removed.json").exists():continue
            try:
                n=int(json.loads(private_file(p))["target"])
                before=self.read();s=self.check(before)
                require(s["current"]==self.home, "cannot remove a desktop before origin is restored")
                occ=before.get("scopedMembers",{}).get(str(n),{})
                require(occ.get("unresolved")==0 and occ.get("otherMembers")==0 and occ.get("ordinary")==[],
                        f"independent inventory does not establish empty desktop {n}: {occ}")
                require(not (p.parent/"remove-intent.json").exists(),"prior removal pending; stop for independent reconciliation")
                expected=[r for r in s["records"] if r["id"]!=n]
                # A pre-dispatch refusal is retryable. Only a positively dispatched or uncertain removal is spent.
                self.command("remove",before,n)
                write_owned(p.parent/"remove-intent.json",dict(issued=True,target=n))
                self.settled(lambda o: row(o)["records"]==expected and row(o)["current"]==self.home,"removal not independently confirmed")
                self.closed.append(n);write_owned(p.parent/"removed.json",dict(target=n,confirmed=True))
                self.record("system-fixture-removed",target=n)
            except (OSError,ValueError,subprocess.SubprocessError) as exc:
                failures.append(str(exc))
                break
        end=self.read()
        ok = row(end)==row(self.original) and self.original["displays"]==end["displays"]
        focus = (self.original.get("frontmostPID"),self.original.get("focusedNumber"))==(end.get("frontmostPID"),end.get("focusedNumber"))
        return dict(topologyRestored=ok, focusRestored=focus, created=len(self.ledgers), removed=len(self.closed),
                    outstanding=self.ids(),errors=failures)

if __name__ == "__main__":
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit",required=True,type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--cleanup",action="store_true",help="reconcile a saved run instead of creating a test desktop")
    args=parser.parse_args()
    os.umask(0o077)
    if not args.cleanup:args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    with (args.output/"workspace-actions.jsonl").open("a") as stream:
        def event(kind, **detail):
            stream.write(json.dumps(dict(event=kind,monotonic=time.monotonic(),**detail))+"\n")
            stream.flush();os.fsync(stream.fileno())
        work=Workspace(args.kit.resolve(),args.output.resolve(),event,resume=args.cleanup)
        try:
            if not args.cleanup:work.create()
        finally:
            receipt=work.cleanup()
            (args.output/"workspace-cleanup.json").write_text(encode(receipt))
            print(encode(receipt))
            if receipt["outstanding"] or not receipt["topologyRestored"]:raise SystemExit(2)
