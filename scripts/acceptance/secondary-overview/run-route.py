#!/usr/bin/env python3
"""Run the authorized secondary-only device trial. All captures are metadata about the enrolled fixtures."""
import argparse
import base64
import contextlib
import fcntl
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import subprocess as sp
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "scripts/acceptance"
VERIFY = runpy.run_path(str(SCRIPTS / "verify-secondary-provision.py"))["verify"]
STAMP = "%Y-%m-%dT%H:%M:%SZ"
UTC = dt.timezone.utc
WITNESS_MANIFEST = "35ad31052d8e3ce196924f307548209609e4e9ea3d5073bc89e224ebec723add"
MIN_ROUTE_SECONDS = 65
CLEANUP_SECONDS = 45
# Two independent six-second Reader calls and their spacing, after the create helper exits.
ADDED_READBACK_SECONDS = 14


class RouteNotStarted(ValueError):
    """Raised only before opening the route log or spawning the witness."""


def need(test, reason):
    if not test:
        raise ValueError(reason)


def verify_leg(intent, posted, confirmed, run, source, target):
    # Swift's Codable Attempt stores UInt64 as a number. The completion dictionary
    # has String values and stores the independent Reader revision as decimal text.
    before, after = intent["beforeRevision"], confirmed["afterRevision"]
    need(type(before) is int and 0 < before < 2**64 and
         isinstance(after, str) and 0 < len(after) <= 20 and after.isascii() and after.isdecimal() and
         str(int(after)) == after and before < int(after) < 2**64, "invalid route revision sequence")
    operation = intent["operation"]
    need(isinstance(operation, str) and str(uuid.UUID(operation)).upper() == operation and
         intent["run"] == run and intent["source"]["record"] == source and intent["target"]["record"] == target and
         operation == posted["operation"] == confirmed["operation"], "unbound system receipt")


def read(file):
    return json.loads(file.read_bytes())


def save(file, value):
    with file.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())


def utcnow():
    return dt.datetime.now(UTC)


@contextlib.contextmanager
def exclusive_trial(folder):
    fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        state = os.fstat(fd)
        need(state.st_uid == os.getuid() and stat.S_IMODE(state.st_mode) == 0o700, "unsafe trial directory")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def creation_returned(folder):
    rows = [json.loads(line) for line in (folder / "create.jsonl").read_text().splitlines()]
    def only(event):
        matches = [row for row in rows if row.get("event") == event]
        need(len(matches) == 1, "missing or ambiguous " + event)
        return matches[0]
    armed, cleanup, exited = [only(k) for k in ("externalFocusArmed", "cleanup", "externalAfterExit")]
    need(exited.get("run") == armed.get("run") and armed.get("run") and
         exited.get("observer") == armed.get("observer") and
         exited.get("originalWindow") == armed.get("originalWindow") == cleanup.get("originalWindow") and
         exited.get("originalPID") == armed.get("originalPID") and
         all(exited.get(k) is True for k in ("childExited","sameAXObjectFocusedAfterExit","originalIdentityAndGeometry")) and
         all(cleanup.get(k) is True for k in ("windowAbsent","originalPointer","overviewDismissed","scopesMatchVerifiedOperation")) and
         cleanup.get("verifiedSpaceMutations") == 1, "creation cleanup or post-exit focus return unconfirmed")


def require_safe_route_stop(folder):
    witness = folder / "witness"
    stopped, done = witness / "stopped.json", witness / "completed.json"
    need(stopped.is_file() != done.is_file(), "uncertain route outcome before cleanup")
    if stopped.is_file():
        proof = read(stopped)
        need(proof.get("scopeReturn") == proof.get("focusReturn") == proof.get("cleanup") == "verified" and
             proof.get("pendingInput") == "none", "route did not prove a safe stop")
    else:
        need(read(done).get("observedRoundTrips") == 3 and (witness / "after-cleanup.json").is_file() and
             read(witness / "restored-focus.json").get("sameAXFocus") == "true", "route completion or return unverified")
    # stopped.pendingInput covers the witness's own six chords. The separate
    # calibration process journals its two possible inputs before posting.
    for step in ("enroll-B", "return-A"):
        files = [witness / f"external-{step}-{kind}.json" for kind in ("intent", "posted", "confirmed")]
        if any(path.exists() for path in files):
            need(all(path.is_file() for path in files), "external calibration outcome unconfirmed")
            intent, posted, confirmed = map(read, files)
            attested = read(witness / f"attested-{step}.json")
            need(posted == intent and intent["checkpoint"] == step and
                 intent["run"] == attested["run"] and intent["target"] == attested["endpoint"] and
                 attested["checkpoint"] == step and all(confirmed.get(k) == v for k, v in intent.items()) and
                 confirmed["attestationToken"] == attested["token"], "external calibration receipts disagree")
    pointer = read(folder / "pointer-exit.json")
    need(pointer.get("returned") is True and pointer.get("exit") == 0, "pointer return not verified")


class Session:
    def __init__(self, args):
        self.args = args
        self.start = dt.datetime.strptime(args.starts, STAMP).replace(tzinfo=UTC)
        self.end = dt.datetime.strptime(args.ends, STAMP).replace(tzinfo=UTC)
        need(self.start <= utcnow() < self.end and (self.end - self.start).total_seconds() <= 900, "no current owner time window")
        self.out = (ROOT / "build/verification/secondary-route-followup" / str(uuid.uuid4())).resolve()
        self.out.mkdir(mode=0o700, parents=True)
        self.ledger = self.out / "provision"
        self.ledger.mkdir(mode=0o700)
        self.run = str(uuid.uuid4()).upper()
        self.revision = 0
        self.reader = args.witness / "NearpaneSpaceWitness.app/Contents/Helpers/NearpaneDesktopReader"
        self.witness = args.witness / "NearpaneSpaceWitness.app/Contents/MacOS/NearpaneSpaceWitness"
        self.primary = self.secondary = self.a = self.b = None
        print(self.out, flush=True)

    def pair(self, tag):
        values = []
        for i in (1, 2):
            self.revision += 1
            request = dict(version=1, session=self.run, revision=self.revision, parentPID=os.getpid(),
                           fixtureWindows=[], anchors=[], experimentalSpaces=True)
            r = sp.run([self.reader, "--read-enrolled-console", base64.b64encode(json.dumps(request).encode()).decode()],
                       capture_output=True, timeout=6, check=True)
            sample = json.loads(r.stdout)
            need(sample["sessionID"] == self.run and sample["revision"] == self.revision and sample["windows"] == [] and
                 sample["topologyConsistent"] and sample["separateSpaces"] and sample["freshness"] == "fresh" and
                 sample["native"]["spaces"] == "observed" and sample["native"]["population"] == "markedFixture",
                 "invalid scope-only snapshot")
            save(self.out / f"{tag}-{i}.json", sample)
            values.append(sample)
            if i == 1:
                time.sleep(0.28)
        need(all(values[0][k] == values[1][k] for k in ("topologyFingerprint", "scopes", "ordinaryRecordsByDisplay", "displays")),
             "topology not stable")
        return values

    def verify_kit(self):
        witness, kit = self.args.witness, self.args.kit
        need(hashlib.sha256((witness / "SHA256SUMS").read_bytes()).hexdigest() == WITNESS_MANIFEST, "wrong frozen witness")
        for root in (witness, kit):
            sp.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=root, check=True, stdout=sp.DEVNULL)
        for app in (self.witness.parents[2], kit / "Nearpane Secondary Overview.app"):
            sp.run(["codesign", "--verify", "--deep", "--strict", app], check=True)

    def setup(self):
        self.verify_kit()
        self.origin = self.pair("origin")
        s = self.origin[1]
        self.secondary = str(uuid.UUID(self.args.display)).upper()
        self.primary, = [d["id"] for d in s["displays"] if d["id"] != self.secondary and (d["frame"]["x"],d["frame"]["y"]) == (0,0)]
        side, = [d for d in s["scopes"] if d["displayID"] == self.secondary]
        self.a, = [r["id"] for r in side["records"] if r["isCurrent"]]
        need(self.a == self.args.source and self.a in s["ordinaryRecordsByDisplay"][self.secondary], "designated source is not current")
        order = [r["id"] for r in side["records"]]
        need(order == s["ordinaryRecordsByDisplay"][self.secondary] and len(order) in (1,2),
             "two endpoints must be identifiable in the complete ordinary order")
        if len(order) == 2:
            self.b, = [r for r in order if r != self.a]
            need(self.b == self.args.existing_target, "existing destination must be the designated test desktop")
        else:
            need(self.args.existing_target is None, "designated existing destination absent")

    def panel_environment(self, ends=None):
        env = os.environ.copy()
        env.pop("NEARPANE_PRIMARY_OVERVIEW_UNTIL", None)
        if self.args.allow_primary_overview:
            env["NEARPANE_PRIMARY_OVERVIEW_UNTIL"] = ends or self.args.ends
        return env

    def panel(self, operation):
        deadline = self.end
        if operation == "create":
            deadline -= dt.timedelta(seconds=MIN_ROUTE_SECONDS + CLEANUP_SECONDS + ADDED_READBACK_SECONDS)
        need((deadline-utcnow()).total_seconds() > 30, "insufficient time for setup, route and return")
        ends = deadline.strftime(STAMP)
        with (self.out / (operation+".jsonl")).open("xb") as log, (self.out/(operation+"-stderr.log")).open("xb") as err:
            sp.run([self.args.kit/"focus-return", self.secondary,self.a,self.args.starts,ends,operation,self.ledger],
                   stdout=log, stderr=err, check=True, env=self.panel_environment(ends))

    def rounds(self):
        now = utcnow()
        end = min(now + dt.timedelta(seconds=120), self.end-dt.timedelta(seconds=CLEANUP_SECONDS))
        if (end-now).total_seconds() <= MIN_ROUTE_SECONDS:
            raise RouteNotStarted("insufficient time for route and separate cleanup")
        log = self.out/"witness.log"
        def wait_until(child, condition, limit, reason):
            while not condition():
                need(child.poll() is None, "witness exited: "+reason)
                need(time.monotonic()<limit, reason)
                time.sleep(.04)
        with log.open("xb") as stream:
            child = sp.Popen([self.witness,"--three-rounds-console"], stdout=stream, stderr=sp.STDOUT)
            pointer = None
            cache = None
            try:
                wait_until(child,lambda: any(line.startswith("RUN ") for line in log.read_text().splitlines()),
                           time.monotonic()+10,"missing run identity")
                cache = Path(next(line[4:] for line in log.read_text().splitlines() if line.startswith("RUN "))).resolve()
                key = str(uuid.UUID(cache.name.removeprefix("Nearpane-P431-"))).upper()
                need(cache == Path.home()/"Library"/"Caches"/("Nearpane-P431-"+key), "unexpected run cache")
                wait_until(child,lambda:(cache/"request-unattended-consent.json").exists(),time.monotonic()+15,"no consent request")
                ptrlog=(self.out/"pointer.log").open("xb")
                try:
                    pointer = sp.Popen([self.args.kit/"route-pointer",str(child.pid),key,self.witness,self.secondary,end.strftime(STAMP)],stdout=ptrlog,stderr=ptrlog)
                finally:
                    ptrlog.close()
                sp.run([self.args.witness/"space-checkpoint.py",key,"consent","--source",self.a,"--target",self.b,
                        "--starts",now.strftime(STAMP),"--ends",end.strftime(STAMP),"--allow-temporary-focus"],check=True)
                for step in ("enroll-B","return-A"):
                    wait_until(child,lambda:(cache/("request-"+step+".json")).exists(),time.monotonic()+35,"no "+step+" request")
                    with (self.out/(step+"-calibration.log")).open("xb") as c:
                        sp.run([self.args.kit/"calibrate-route",self.args.witness,key,step],stdout=c,stderr=c,check=True)
                child.wait(timeout=max(1,(end-utcnow()).total_seconds()+10))
                need(child.returncode==0 and read(cache/"completed.json").get("observedRoundTrips")==3, "three round trips not confirmed")
                for i in range(1,4):
                    for target in ("B","A"):
                        prefix="round-"+str(i)+"-"+target
                        intent, posted, confirmed = [read(cache/(prefix+"-"+suffix+".json")) for suffix in ("intent","posted","confirmed")]
                        source_id, target_id = (self.a,self.b) if target == "B" else (self.b,self.a)
                        verify_leg(intent, posted, confirmed, key, source_id, target_id)
                        need(read(cache/(prefix+".json"))["record"] == target_id, "wrong endpoint")
                need(read(cache/"restored-focus.json")["sameAXFocus"] == "true","original focus not confirmed")
            finally:
                # An uncertain transition is never reversed by this supervisor. Let a granted
                # witness reach its own deadline, close its enrolled windows and record the outcome.
                if child.poll() is None:
                    if cache is None or not (cache/"unattended-consent.ready").exists():
                        child.terminate()   # The witness cannot create a window before a grant.
                    child.wait(timeout=max(10,(end-utcnow()).total_seconds()+10))
                if cache and cache.is_dir():
                    shutil.copytree(cache,self.out/"witness",dirs_exist_ok=False)
                if pointer is not None:
                    rc = pointer.wait(timeout=8)
                    lines = (self.out / "pointer.log").read_text().splitlines()
                    no_loan = rc == 0 and lines[-1:] == ["original pointer unchanged; no loan"]
                    restored = rc == 0 and lines[-1:] == ["original pointer restored"]
                    save(self.out / "pointer-exit.json", dict(exit=rc, returned=restored or no_loan, noLoan=no_loan))
                    need(restored or no_loan,"pointer restoration unconfirmed")

    def execute(self):
        self.setup()
        created = self.b is None
        if created:
            self.panel("create")
            self.provisioned = self.pair("added")
            proof = VERIFY(self.primary,self.secondary,self.origin,self.provisioned)
            self.b = str(read(self.ledger/"created.json")["target"])
            need(self.b==proof["target"],"AX creation receipt and independent Reader disagree")
        else:
            self.provisioned = self.origin
        route_error = None
        try:
            self.rounds()
        except RouteNotStarted as e:
            # The typed pre-spawn refusal proves this invocation created no route process.
            # Independent creation, focus and live scope receipts are still mandatory.
            need(not (self.out / "witness.log").exists(), "unexpected witness launch evidence")
            save(self.out / "route-not-started.json", dict(reason=str(e), source=self.a, target=self.b))
            if not created:
                raise
            creation_returned(self.out)
            current = VERIFY(self.primary, self.secondary, self.origin, self.pair("before-remove"))
            need((current["source"], current["target"]) == (self.a, self.b), "created desktop changed before cleanup")
            route_error = str(e)
        except (ValueError,KeyError,TypeError,OSError,sp.SubprocessError) as e:
            route_error = str(e)
            if created:
                require_safe_route_stop(self.out)
        if created:
            # Stop inputs on focus escape or uncertain return. A simple route refusal may be
            # cleaned only with an explicit witness receipt for scopes, focus and fixture cleanup.
            self.panel("remove")
            reset = VERIFY(self.primary,self.secondary,self.origin,self.provisioned,self.pair("restored"))
            need(reset["originalScopesRestored"],"original inventory not restored")
        need(route_error is None,route_error or "route failed")
        save(self.out/"complete.json",dict(roundTrips=3,source=self.a,target=self.b,createdAndRemoved=created))

    def capture_added_if_missing(self):
        # This is a fresh read only, even when a preceding API call reported an error.
        if self.args.cleanup_run or not (self.ledger / "created.json").exists():
            return
        if (self.out / "added-2.json").exists():
            return
        self.pair("creation-readback")

    def recover_prepared(self, prior):
        self.verify_kit()
        root = ROOT / "build/verification/secondary-route-followup"
        need(prior.parent == root and str(uuid.UUID(prior.name)) == prior.name, "expected an original route trial")
        need(self.args.existing_target is None, "an existing desktop is outside preparation cleanup")
        with exclusive_trial(prior):
            need((prior / "stopped.json").is_file() and not (prior / "complete.json").exists(),
                 "original trial did not stop or already completed")
            self.ledger = prior / "provision"
            need(not os.path.lexists(prior / "recovery-attempt.json"), "explicit cleanup already attempted")
            need(not any(os.path.lexists(self.ledger / n) for n in ("remove-intent.json","removed.json"))
                 and not (prior / "remove.jsonl").exists(), "original removal already attempted")
            creation_returned(prior)
            if (prior / "witness.log").exists():
                require_safe_route_stop(prior)
            state = read(self.ledger / "created.json")
            intent = read(self.ledger / "create-intent.json")
            need(intent == state["intent"] and intent["display"] == self.args.display.upper() and
                 intent["source"] == self.args.source, "original creation identity mismatch")
            self.secondary, self.a, self.b = intent["display"], intent["source"], state["target"]
            def stored(tag):
                return [read(prior / f"{tag}-{n}.json") for n in (1,2)]
            self.origin = stored("origin")
            protected, = [d["id"] for d in self.origin[0]["displays"]
                          if d["id"] != self.secondary and d["frame"]["x"] == d["frame"]["y"] == 0]
            self.primary = protected
            tag = "added" if (prior / "added-2.json").exists() else "creation-readback"
            self.provisioned = stored(tag)
            # Validate the two original samples *and* a fresh pair from this distinct invocation.
            for pair in (self.provisioned, self.pair("current")):
                proof = VERIFY(self.primary, self.secondary, self.origin, pair)
                need(proof["source"] == self.a and proof["target"] == self.b, "adjacent created desktop not confirmed")
            # The signed controller rechecks boot, Dock birth, creation lifetime, original AX tiles,
            # positive A witness and live target occupancy before its exclusive remove-intent.
            save(prior / "recovery-attempt.json",dict(trial=self.out.name,target=self.b))
            self.panel("remove")
            restored = VERIFY(self.primary,self.secondary,self.origin,self.provisioned,self.pair("restored"))
            need(restored["originalScopesRestored"], "original topology not restored")
            save(self.out / "cleanup-complete.json",dict(originalTrial=prior.name,source=self.a,target=self.b,
                                                         restored=True,roundTripsPerformed=0))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ("kit","witness"):
        parser.add_argument("--"+key,type=lambda s:Path(s).resolve(strict=True),required=True)
    for key in ("starts","ends","display","source"):
        parser.add_argument("--"+key, required=True)
    parser.add_argument("--allow-primary-overview", action="store_true", help="owner permits transient system overview presentation on the primary during this timed trial")
    parser.add_argument("--existing-target")
    parser.add_argument("--cleanup-run", type=lambda value:Path(value).resolve(strict=True),
                        help="within a current loan, remove only the evidenced new B from this stopped trial")
    s=Session(parser.parse_args())
    try:
        with exclusive_trial(s.out):
            if s.args.cleanup_run:
                s.recover_prepared(s.args.cleanup_run)
            else:
                s.execute()
    except (ValueError,TypeError,KeyError,OSError,sp.SubprocessError) as e:
        # Preserve corroborating post-create samples even if a later step refused.
        try:
            s.capture_added_if_missing()
        except (ValueError, TypeError, KeyError, OSError, sp.SubprocessError) as evidence_error:
            save(s.out / "creation-readback-refused.json",dict(reason=str(evidence_error)))
        save(s.out/"stopped.json",dict(reason=str(e),createdReceipt=(s.ledger/"created.json").exists(),removeReceipt=(s.ledger/"removed.json").exists()))
        raise SystemExit(str(e))


if __name__=="__main__":
    main()
