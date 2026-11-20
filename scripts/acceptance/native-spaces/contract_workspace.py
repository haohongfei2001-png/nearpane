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
    require(s["scope"] == o["displays"][0]["uuid"] and len({r["id"] for r in s["records"]}) == len({r["uuid"] for r in s["records"]}) == len(s["records"])
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
    def __init__(self, kit, output, record, resume=False, previous_archive=None, install_receipt=None):
        self.kit, self.output, self.record = kit, output, record
        self.recovering = resume
        self.boot = checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip()
        self.ledgers = []
        self.closed = []
        live = self.read()
        self.original = live
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
        # A recovered inactive lease must not override a newer user-selected original Space.
        self.cleanup_current = self.home
        self.cleanup_focus = self.original
        self.protected = s["records"]
        if resume:
            self.bind_protected_order(live)
            current = row(live)["current"]
            if current in {r["id"] for r in self.protected}:
                self.cleanup_current = current
                self.cleanup_focus = live
        require(any(r["id"] == self.home and r["type"] in (0, 4) for r in s["records"]), "original active Space identity unavailable")
        require(self.original.get("observerAX") is True and self.original.get("host") and self.original.get("installedHostCount") == 1,
                "installed Host and observer AX required")
        self.host = live.get("host") or {}
        require(live.get("installedHostCount") == 1 and self.host.get("codeHash"), "cannot identify the installed Host")
        old_hash=self.original["host"].get("codeHash")
        if self.host["codeHash"] != old_hash:
            require(resume, "installed Host changed during test admission")
            from contract_signing import continuity
            proof=continuity(previous_archive,install_receipt,old_hash,self.host["codeHash"])
            self.record("signed-install-continuity",**proof)
        if resume:
            checked(["/usr/bin/codesign", "--verify", "--strict", "/Applications/Nearpane.app"])
            self.record("cleanup-host-bound", original=self.original["host"], current=self.host)
        self.host_birth = int(checked([str(self.kit/"system-workspace"),"birth",str(self.host["pid"])]).strip())
        self.hid = self.hardware()
        if resume:
            self.reconcile_removed(live)
        self.check(self.read())

    def bind_protected_order(self, observation):
        live = row(observation)["records"]
        original = row(self.original)["records"]
        leases = {int(made["target"]): made["after"]["spaceUUIDs"][made["target"]]
                  for made in (json.loads(private_file(p)) for p in self.ledgers)}
        require(all(r in live for r in original), "a pre-existing Space ID, UUID or type changed")
        require(all(r["type"]==0 and r["uuid"]==leases[r["id"]] and r["id"] not in self.closed
                    for r in live if r["id"] in leases), "a leased Space ID was reused")
        self.protected = [r for r in live if r["id"] not in leases]
        self.record("recovery-protected-order",ids=[r["id"] for r in self.protected],
                    originalOrderMatches=self.protected==original)

    def hardware(self):
        return [int(x) for x in checked([str(self.kit/"system-workspace"),"hid"]).strip().split(",")]

    def read(self):
        env=os.environ.copy()
        if self.ledgers and self.ids():env["NEARPANE_CONTRACT_SPACE_IDS"]=",".join(map(str,self.ids()))
        return json.loads(checked([str(self.kit/"observe")], timeout=8, env=env))

    def ids(self):
        created = (int(json.loads(private_file(p))["target"]) for p in self.ledgers)
        return [n for n in created if n not in self.closed]

    def check(self, o, *, check_current=True):
        require(o["host"] == self.host and o["displays"] == self.original["displays"], "installed Host or physical displays changed")
        s = row(o)
        existing = self.protected
        leased = {int(v["target"]):v["after"]["spaceUUIDs"][v["target"]]
                  for v in (json.loads(private_file(p)) for p in self.ledgers) if int(v["target"]) not in self.closed}
        require([r for r in s["records"] if r["id"] not in leased] == existing
                and {r["id"]:r["uuid"] for r in s["records"] if r["id"] in leased and r["type"] == 0} == leased,
                "existing desktop order, original identities or leased desktop membership changed")
        if check_current:
            require(s["current"] in (self.home, self.cleanup_current) or s["current"] in leased, "unrelated desktop became current")
        return s

    def command(self, name, snapshot, target=None, other=None, *, before_send=None, after_reply=None):
        s = self.check(snapshot)
        # Each independent system operation binds its own quiet interval and positively
        # identified source; a change during that interval suspends dispatch.
        self.hid = self.hardware()
        fresh = self.read()
        require(self.check(fresh) == s and (snapshot.get("frontmostPID"),snapshot.get("focusedNumber")) ==
                (fresh.get("frontmostPID"),fresh.get("focusedNumber")) and self.hardware() == self.hid,
                "physical input, focus or Space changed before system dispatch")
        req = dict(command=name, display=self.display, records=s["records"], current=s["current"], original=self.cleanup_current,
                   owned=self.ids(), target=target, other=other, hostPID=self.host["pid"], hostHash=self.host["codeHash"], hostBirth=self.host_birth, hid=self.hid)
        self.record("system-fixture-intent", operation=name, current=s["current"], target=target, other=other)
        if before_send: before_send()
        call = subprocess.run([str(self.kit/"system-workspace")], input=json.dumps(req), text=True, capture_output=True, timeout=20)
        try:
            out = json.loads(call.stdout)
        except ValueError as exc:
            raise ScopeError(f"{name}: system operator did not return an input receipt") from exc
        if after_reply: after_reply(out)
        self.record("system-fixture-result", operation=name, target=target, **out)
        require(call.returncode == 0 and out.get("acknowledged") and out.get("issued"), f'{name}: {out.get("reason","native input not acknowledged")}')

    def settled(self, condition, description, duration=5):
        last = None; count = 0
        end = time.monotonic()+duration
        while time.monotonic() < end:
            o = self.read()
            require(o["host"] == self.host and o["displays"] == self.original["displays"], "observer lost installed Host/display")
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
        self.check(after,check_current=False)
        if current["current"] not in {self.home,self.cleanup_current,*self.ids()}:
            # Closing native Mission Control over a fullscreen app can briefly show
            # an existing ordinary desktop. Observe its return before sending more input.
            permitted = {self.home,self.cleanup_current,*self.ids()}
            self.settled(lambda o: self.check(o,check_current=False)["records"]==current["records"]
                         and row(o)["current"] in permitted, "system overview did not settle on its origin or a created desktop",8)
        return new["id"]

    def select(self,n):
        before = self.read(); s = self.check(before)
        require(n in (self.home, self.cleanup_current) or n in self.ids(), "system selection outside fixture")
        if s["current"] != n:
            self.command("select",before,n)
        return self.settled(lambda o: self.check(o,check_current=False)["current"] == n and row(o)["records"]==s["records"], "system selection did not arrive")

    def swap(self,a,b):
        before = self.read(); s = self.check(before); order=s["records"].copy()
        ids=[r["id"] for r in order]; left,right=ids.index(a),ids.index(b)
        require(a in self.ids() and b in self.ids() and abs(left-right)==1,"only adjacent owned desktops may be reordered")
        order[left],order[right]=order[right],order[left]
        self.command("swap",before,a,b)
        return self.settled(lambda o: self.check(o)["records"]==order and row(o)["current"]==s["current"], "native drag did not exchange only the two enrolled desktops")

    def reconcile_removed(self, snapshot):
        """An already-issued removal may have completed after its caller exited."""
        current = row(snapshot)
        for receipt in reversed(self.ledgers):
            pending = receipt.with_name("remove-intent.json")
            if not pending.exists() or receipt.with_name("removed.json").exists():
                continue
            n = int(json.loads(private_file(receipt))["target"])
            intent = json.loads(private_file(pending))
            require(intent["target"] == n and intent.get("boot") == self.boot,
                    "unrecognized previous removal")
            if any(r["id"] == n for r in current["records"]):
                continue
            require(current["records"] == intent["expected"] and current["current"] == self.cleanup_current,
                    "pending removal cannot be reconciled with current topology")
            self.closed.append(n)
            self.check(snapshot)
            write_owned(receipt.with_name("removed.json"), dict(target=n,confirmed=True,recovered=True))
            self.record("system-fixture-removal-reconciled", target=n)

    def bind_quiet_cleanup(self):
        """Wait for a quiet pre-dispatch interval and preserve the user's actual foreground."""
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            counters = self.hardware()
            first = self.read()
            time.sleep(.35)
            second = self.read()
            if self.hardware() != counters or row(first) != row(second):
                continue
            self.bind_protected_order(second)
            original_ids = {r["id"] for r in self.protected}
            current = row(second)["current"]
            if current in original_ids:
                self.cleanup_current, self.cleanup_focus = current, second
            self.check(second)
            self.hid = counters
            return
        raise ScopeError("No quiet interval available to recycle the inactive desktop")

    def cleanup(self):
        failures = []
        try:
            self.reconcile_removed(self.read())
            if self.ids():
                if self.recovering:
                    self.bind_quiet_cleanup()
                if row(self.read())["current"] != self.cleanup_current:
                    self.select(self.cleanup_current)
            for receipt in reversed(self.ledgers):
                if receipt.with_name("removed.json").exists():
                    continue
                n = int(json.loads(private_file(receipt))["target"])
                before = self.read()
                state = self.check(before)
                require(state["current"] == self.cleanup_current, "original Space has not been restored")
                report = before.get("scopedMembers") or {}
                occupancy = report.get(str(n), {})
                require(occupancy.get("unresolved") == 0 and occupancy.get("otherMembers") == 0 and occupancy.get("ordinary") == [],
                        f"independent inventory does not establish empty desktop {n}: {occupancy or report}")
                expected = [r for r in state["records"] if r["id"] != n]
                pending = receipt.with_name("remove-intent.json")
                if pending.exists():
                    previous = json.loads(private_file(pending))
                    reply = receipt.with_name("remove-reply-" + previous["operation"] + ".json")
                    require(reply.exists() and json.loads(private_file(reply)).get("issued") is False,
                            "previous removal has an unknown delivery; retaining its journal and desktop")
                    pending.rename(receipt.with_name("remove-refused-" + previous["operation"] + ".json"))
                operation = str(uuid.uuid4())
                intent = dict(operation=operation, boot=self.boot, target=n, expected=expected)
                self.command("remove", before, n,
                             before_send=lambda: write_owned(pending,intent),
                             after_reply=lambda data: write_owned(receipt.with_name("remove-reply-"+operation+".json"),data))
                after = self.settled(lambda o: row(o)["records"] == expected and row(o)["current"] == self.cleanup_current,
                                     "removal not independently confirmed")
                self.reconcile_removed(after)
                self.record("system-fixture-removed",target=n)
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:
            failures.append(str(exc))
        end=self.read()
        preserved = row(end)["records"] == self.protected
        original_order = row(end)["records"] == row(self.original)["records"]
        ok = preserved and row(end)["current"] == self.cleanup_current and self.original["displays"] == end["displays"]
        focus = (self.cleanup_focus.get("frontmostPID"),self.cleanup_focus.get("focusedNumber"))==(end.get("frontmostPID"),end.get("focusedNumber"))
        return dict(topologyRestored=ok, focusRestored=focus, originalCurrent=self.home, cleanupCurrent=self.cleanup_current,
                    originalOrderRestored=original_order, preservedLatestOrder=preserved,
                    retainedUserSelectedSpace=self.cleanup_current != self.home, created=len(self.ledgers), removed=len(self.closed),
                    outstanding=self.ids(),errors=failures)

if __name__ == "__main__":
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit",required=True,type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--previous-archive",type=Path)
    parser.add_argument("--install-receipt",type=Path)
    parser.add_argument("--cleanup",action="store_true",help="reconcile a saved run instead of creating a test desktop")
    args=parser.parse_args()
    os.umask(0o077)
    if not args.cleanup:args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    with (args.output/"workspace-actions.jsonl").open("a") as stream:
        def event(kind, **detail):
            stream.write(json.dumps(dict(event=kind,monotonic=time.monotonic(),**detail))+"\n")
            stream.flush();os.fsync(stream.fileno())
        try:
            work=Workspace(args.kit.resolve(),args.output.resolve(),event,resume=args.cleanup,
                           previous_archive=args.previous_archive,install_receipt=args.install_receipt)
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
            event("workspace-refused",status="BLOCKED",reason=str(error),systemInputs=0)
            raise
        try:
            if not args.cleanup:work.create()
        finally:
            receipt=work.cleanup()
            event("workspace-cleanup",**receipt)
            write_owned(args.output/("cleanup-"+str(uuid.uuid4())+".json"),receipt)
            (args.output/"workspace-cleanup.json").write_text(encode(receipt))
            print(encode(receipt))
            if receipt["outstanding"] or not receipt["topologyRestored"]:raise SystemExit(2)
