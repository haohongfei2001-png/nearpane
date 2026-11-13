#!/usr/bin/env python3
"""Run the authorized secondary-only device trial. All captures are metadata about the enrolled fixtures."""
import argparse
import base64
import contextlib
import fcntl
import datetime as dt
import errno
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
_provision = runpy.run_path(str(SCRIPTS / "verify-secondary-provision.py"))
VERIFY = _provision["verify"]
STAMP = "%Y-%m-%dT%H:%M:%SZ"
UTC = dt.timezone.utc
WITNESS_MANIFEST = "35ad31052d8e3ce196924f307548209609e4e9ea3d5073bc89e224ebec723add"
WITNESS_INPUTS = {
    "SessionProbe", "protected.json", "space-checkpoint.py",
    "NearpaneSpaceWitness.app/Contents/Info.plist",
    "NearpaneSpaceWitness.app/Contents/MacOS/NearpaneSpaceWitness",
    "NearpaneSpaceWitness.app/Contents/Helpers/NearpaneDesktopReader",
    "NearpaneSpaceWitness.app/Contents/_CodeSignature/CodeResources",
}
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


def check_display_binding(frozen, sample, expected_count):
    displays = [item["id"] for item in sample["displays"]]
    need(len(displays) == len(set(displays)) == expected_count and
         all(str(uuid.UUID(item)).upper() == item for item in displays),
         "frozen topology requires the designated displays")
    observed = sorted(hashlib.sha256(item.encode("ascii")).hexdigest() for item in displays)
    need(isinstance(frozen, list) and sorted(frozen) == observed,
         "Reader display identities differ from the signed-off witness baseline")


def frozen_witness_displays(folder, expected_digest):
    manifest = (folder / "SHA256SUMS").read_bytes()
    need(hashlib.sha256(manifest).hexdigest() == expected_digest, "wrong frozen witness")
    entries = {}
    for line in manifest.decode("ascii").splitlines():
        checksum, separator, name = line.partition("  ")
        need(separator and name in WITNESS_INPUTS and name not in entries and
             len(checksum) == 64 and all(c in "0123456789abcdef" for c in checksum),
             "unexpected frozen witness manifest entry")
        entries[name] = checksum
    need(entries.keys() == WITNESS_INPUTS, "frozen witness manifest is incomplete")
    baseline = (folder / "protected.json").read_bytes()
    need(hashlib.sha256(baseline).hexdigest() == entries["protected.json"], "display baseline checksum changed")
    return json.loads(baseline)["displays"]


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


@contextlib.contextmanager
def exclusive_console(trials):
    # All entry points for this checkout share the same graphical console.
    fd = os.open(trials / ".console.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
             and stat.S_IMODE(info.st_mode) == 0o600, "untrusted console lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EACCES):
                raise ValueError("another Native Spaces trial is using this console") from error
            raise
        yield
    finally:
        os.close(fd)


def overview_returned(folder, operation, expected_mutations):
    rows = [json.loads(line) for line in (folder / (operation + ".jsonl")).read_text().splitlines()]
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
         type(cleanup.get("verifiedSpaceMutations")) is int and cleanup["verifiedSpaceMutations"] == expected_mutations,
         "overview cleanup or post-exit focus return unconfirmed")
    return armed


def creation_returned(folder):
    overview_returned(folder, "create", 1)


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
    @property
    def current_display(self):
        return getattr(self.args, "current_display", False)

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
        manifest = self.args.witness_manifest or WITNESS_MANIFEST
        displays = frozen_witness_displays(witness, manifest)
        for root in (witness, kit):
            sp.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=root, check=True, stdout=sp.DEVNULL)
        for app in (self.witness.parents[2], kit / "Nearpane Secondary Overview.app"):
            sp.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
        return displays

    def setup(self):
        frozen = self.verify_kit()
        self.origin = self.pair("origin")
        s = self.origin[1]
        self.secondary = str(uuid.UUID(self.args.display)).upper()
        if self.current_display:
            need((self.args.existing_target or self.args.provision_current) and not self.args.cleanup_run and not self.args.allow_primary_overview,
                 "current display route only supports existing designated desktops")
            need([d["id"] for d in s["displays"]] == [self.secondary] and
                 [d["displayID"] for d in s["scopes"]] == [self.secondary], "selected display must be the sole live display")
        else:
            self.primary, = [d["id"] for d in s["displays"] if d["id"] != self.secondary and (d["frame"]["x"],d["frame"]["y"]) == (0,0)]
            _provision["scope_state"](s, self.primary, self.secondary)
        check_display_binding(frozen, s, 1 if self.current_display else 2)
        side, = [d for d in s["scopes"] if d["displayID"] == self.secondary]
        self.a, = [r["id"] for r in side["records"] if r["isCurrent"]]
        from_live_right_edge = (self.current_display and getattr(self.args, "provision_current", False) and
                                getattr(self.args, "check_overview_first", False) and self.args.source == "rightmost-current")
        need((self.a == self.args.source or from_live_right_edge) and self.a in s["ordinaryRecordsByDisplay"][self.secondary],
             "designated source is not current")
        order = [r["id"] for r in side["records"]]
        if self.current_display:
            if self.args.provision_current:
                need(order[-1] == self.a and order == s["ordinaryRecordsByDisplay"][self.secondary],
                     "new desktop requires a rightmost ordinary source and complete ordinary inventory")
                return
            self.b = self.args.existing_target
            need(len(order) == len(set(order)) and self.b in s["ordinaryRecordsByDisplay"][self.secondary]
                 and self.b in order and abs(order.index(self.a) - order.index(self.b)) == 1,
                 "designated existing desktop is not adjacent in the complete order")
            return
        need(order == s["ordinaryRecordsByDisplay"][self.secondary] and len(order) in (1,2),
             "two endpoints must be identifiable in the complete ordinary order")
        if getattr(self.args, "check_overview_first", False):
            need(order == [self.a] and self.args.existing_target is None,
                 "secondary creation rehearsal requires one ordinary source and no existing target")
        if len(order) == 2:
            self.b, = [r for r in order if r != self.a]
            need(self.b == self.args.existing_target, "existing destination must be the designated test desktop")
        else:
            need(self.args.existing_target is None, "designated existing destination absent")

    def panel_environment(self, ends=None):
        env = os.environ.copy()
        env.pop("NEARPANE_PRIMARY_OVERVIEW_UNTIL", None)
        if self.args.allow_primary_overview or getattr(self.args,"provision_current",False) or (self.current_display and self.args.cleanup_run):
            env["NEARPANE_PRIMARY_OVERVIEW_UNTIL"] = ends or self.args.ends
        return env

    def panel(self, operation):
        if self.current_display:
            if self.args.cleanup_run:
                need(operation == "remove" and self.ledger == self.args.cleanup_run / "provision",
                     "recovery may only remove the provisioned desktop from the selected trial")
            else:
                need(self.args.provision_current, "existing endpoints cannot be created or removed")
        deadline = self.end
        if operation == "create":
            deadline -= dt.timedelta(seconds=MIN_ROUTE_SECONDS + CLEANUP_SECONDS + ADDED_READBACK_SECONDS)
        need((deadline-utcnow()).total_seconds() > 30, "insufficient time for setup, route and return")
        ends = deadline.strftime(STAMP)
        with (self.out / (operation+".jsonl")).open("xb") as log, (self.out/(operation+"-stderr.log")).open("xb") as err:
            selector = ["--current-display"] if self.current_display else []
            action = [] if operation == "observe" else [operation, self.ledger]
            env = self.panel_environment(ends)
            if operation == "create" and getattr(self.args, "check_overview_first", False):
                anchor = overview_returned(self.out, "observe", 0)
                env["NEARPANE_REHEARSED_WINDOW"] = str(anchor["originalWindow"])
                env["NEARPANE_REHEARSED_PID"] = str(anchor["originalPID"])
                env["NEARPANE_REHEARSED_BIRTH"] = str(anchor["originalProcessStart"])
            sp.run([self.args.kit/"focus-return", *selector, self.secondary,self.a,self.args.starts,ends,*action],
                   stdout=log, stderr=err, check=True, env=env)

    def calibrate(self, step, cache, run, child):
        if step == "enroll-B":
            enrollment = read(cache / "enrolled-A.json")
            source = read(cache / "origin-A.json")
            window = source["number"]
            need(child.poll() is None and type(window) is int and 0 < window < 2**32 and
                 enrollment["run"] == run and enrollment["label"] == "A" and
                 enrollment["method"] == "appkit-key-window" and enrollment["window"] == str(window) and
                 enrollment["frontPID"] == str(child.pid) and source["frontPID"] == child.pid and
                 source["record"] == source["currents"][self.secondary] == self.a, "unbound occupancy fixture")
            if self.current_display:
                created_target = getattr(self.args, "provision_current", False)
                if created_target:
                    issuance = read(self.ledger / "created.json")
                    claim = read(self.ledger / "create-intent.json")
                    proof = self.check_added(self.origin, self.provisioned)
                    need(issuance["intent"] == claim and claim["display"] == self.secondary
                         and claim["source"] == proof["source"] == self.a and issuance["target"] == proof["target"] == self.b,
                         "new desktop not attributable to this trial")
                occupancy_args = ["--removal-current" if created_target else "--scoped-current", str(child.pid), str(window), self.secondary, self.a, self.b]
                display_proof = dict(occupancy="NO_RELOCATION_OBSERVED" if created_target else "OBSERVED_EMPTY", display=self.secondary)
            else:
                primary_current = source["currents"][self.primary]
                occupancy_args = ["--scoped", str(child.pid), str(window), self.primary, self.secondary,
                                  primary_current, self.a, self.b]
                display_proof = dict(occupancy="NO_RELOCATION_OBSERVED", primary=self.primary,
                                     secondary=self.secondary, primaryCurrent=primary_current)
            sample = sp.run([self.args.kit / "occupancy", *occupancy_args], capture_output=True, timeout=6)
            proof = json.loads(sample.stdout)
            save(self.out / "target-occupancy.json", dict(run=run, exit=sample.returncode, sample=proof))
            # The removal helper allows shared non-desktop windows since removal would not
            # relocate them. An initially blank test B cannot make that exemption.
            required = dict(**display_proof, source=self.a, target=self.b,
                            sourcePID=child.pid, sourceWindow=window, scopeSamples=2,
                            blockingWindows=0)
            if not (self.current_display and getattr(self.args, "provision_current", False)):
                required["corroboratedShared"] = 0
            need(sample.returncode == 0 and child.poll() is None and all(
                type(proof.get(k)) is type(v) and proof[k] == v for k, v in required.items()
            ), "blank secondary B not verified; no calibration input")
        with (self.out / (step + "-calibration.log")).open("xb") as log:
            selector = []
            if self.current_display:
                selector = ["--current-display", self.secondary, self.args.witness_manifest]
            elif getattr(self.args, "witness_manifest", None):
                selector = ["--witness-manifest", self.args.witness_manifest]
            sp.run([self.args.kit / "calibrate-route", self.args.witness, run, step, *selector],
                   stdout=log, stderr=log, check=True)

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
            witness_args = ["--three-rounds-current-display", self.secondary] if self.current_display else ["--three-rounds-console"]
            child = sp.Popen([self.witness,*witness_args], stdout=stream, stderr=sp.STDOUT)
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
                    pointer_args = ["--current-display"] if self.current_display else []
                    pointer = sp.Popen([self.args.kit/"route-pointer",str(child.pid),key,self.witness,self.secondary,
                                        end.strftime(STAMP),*pointer_args],stdout=ptrlog,stderr=ptrlog)
                finally:
                    ptrlog.close()
                grant_args = ["--current-display", self.secondary] if self.current_display else []
                sp.run([self.args.witness/"space-checkpoint.py",key,"consent","--source",self.a,"--target",self.b,
                        "--starts",now.strftime(STAMP),"--ends",end.strftime(STAMP),"--allow-temporary-focus",*grant_args],check=True)
                for step in ("enroll-B","return-A"):
                    wait_until(child,lambda:(cache/("request-"+step+".json")).exists(),time.monotonic()+35,"no "+step+" request")
                    self.calibrate(step, cache, key, child)
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

    def check_added(self, before, after, restored=None):
        if self.current_display:
            return VERIFY(self.primary,self.secondary,before,after,restored,current_display=True)
        return VERIFY(self.primary,self.secondary,before,after,restored)

    def execute(self):
        self.setup()
        created = self.b is None
        if created:
            if getattr(self.args, "check_overview_first", False):
                self.panel("observe")
                overview_returned(self.out, "observe", 0)
                fresh = self.pair("after-observe")
                keys = ("displays", "scopes", "topologyFingerprint", "ordinaryRecordsByDisplay")
                need(all(fresh[1][k] == self.origin[1][k] for k in keys),
                     "desktop changed during the focus rehearsal")
            self.panel("create")
            self.provisioned = self.pair("added")
            proof = self.check_added(self.origin,self.provisioned)
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
            current = self.check_added(self.origin,self.pair("before-remove"))
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
            reset = self.check_added(self.origin,self.provisioned,self.pair("restored"))
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
        frozen = self.verify_kit()
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
            if not self.current_display:
                self.primary, = [d["id"] for d in self.origin[0]["displays"]
                                 if d["id"] != self.secondary and d["frame"]["x"] == d["frame"]["y"] == 0]
            tag = "added" if (prior / "added-2.json").exists() else "creation-readback"
            self.provisioned = stored(tag)
            # Validate the two original samples *and* a fresh pair from this distinct invocation.
            current = self.pair("current")
            for pair in (self.provisioned, current):
                proof = self.check_added(self.origin, pair)
                need(proof["source"] == self.a and proof["target"] == self.b, "adjacent created desktop not confirmed")
            check_display_binding(frozen, current[1], 1 if self.current_display else 2)
            # The signed controller rechecks boot, Dock birth, creation lifetime, original AX tiles,
            # positive A witness and live target occupancy before its exclusive remove-intent.
            save(prior / "recovery-attempt.json",dict(trial=self.out.name,target=self.b))
            self.panel("remove")
            restored = self.check_added(self.origin,self.provisioned,self.pair("restored"))
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
    parser.add_argument("--current-display", action="store_true", help="bind the requested route, provision, or cleanup to the named sole display")
    parser.add_argument("--provision-current", action="store_true", help="create and remove only a new adjacent desktop on the explicitly designated sole display")
    parser.add_argument("--check-overview-first", action="store_true",
                        help="require a successful real overview and passive focus return before creating a desktop")
    parser.add_argument("--witness-manifest", help="SHA-256 of the independently frozen witness manifest for the observed displays")
    parser.add_argument("--cleanup-run", type=lambda value:Path(value).resolve(strict=True),
                        help="within a current loan, remove only the evidenced new B from this stopped trial")
    args = parser.parse_args()
    if args.check_overview_first and (args.existing_target is not None or args.cleanup_run or
                                      (args.current_display and not args.provision_current)):
        parser.error("--check-overview-first requires a new desktop provisioning trial")
    if args.current_display:
        modes = (args.existing_target is not None, args.provision_current, args.cleanup_run is not None)
        if sum(modes) != 1 or args.allow_primary_overview or not args.witness_manifest:
            parser.error("--current-display needs a frozen witness manifest and exactly one of --existing-target, --provision-current or --cleanup-run")
    elif args.provision_current:
        parser.error("--provision-current requires --current-display")
    s=Session(args)
    try:
        with exclusive_console(s.out.parent), exclusive_trial(s.out):
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
