"""Enter an existing empty ordinary Space using Apple's selector and return via an owned AppKit window."""
import hashlib
import importlib
import json
import os
from pathlib import Path
import plistlib
import select
import subprocess
import tempfile
import time
import uuid

from acceptance import identity
from contract_workspace import inactive_empty, row, stats
from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home
from space_scope import ScopeError, private_file, require

HERE = Path(__file__).resolve().parent
PREVIEW = importlib.import_module("preview-workspace")
FOCUS = importlib.import_module("p0-focus")
P0 = importlib.import_module("p0-cards")
REFERENCE = HERE.parents[2]/"engineering/verification/native-spaces/5.22-p0/13-presentation-timing"
ANCHOR_ID = "org.nearpane.acceptance.LifecycleWindow"
READ_ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError)


def safe_reason(error):
    # Some native operator refusals contain raw WindowServer records. Persist only the classification.
    s = str(error)
    if "WindowServer could not establish an empty desktop" in s:
        return "nativeDestinationCensusNotEmpty"
    if "first-list:" in s or "second-list:" in s:
        return "signedAppleDesktopListUnavailable"
    if isinstance(error, ScopeError) and len(s) <= 160 and all(c.isalnum() or c in " .-_" for c in s):
        return s
    return type(error).__name__


def archive_anchor(reference=REFERENCE):
    """Use the identical enrolled fixture binary from the actual independent return to ordinary Space 6."""
    rows = [json.loads(line) for line in (reference/"actions.jsonl").read_text().splitlines()]
    fixture = rows[0]["windows"]
    require(rows[0]["event"] == "fixture-opened" and len(fixture) == 2 and len({w["number"] for w in fixture}) == 2 and
            all(w["identifier"] == ANCHOR_ID and all(w[k] == fixture[0][k] for k in ("pid","birth","executable","hash")) for w in fixture),
            "historicalReturnFixtureUnbound")
    origin = next(r["source"] for r in rows if r["event"] == "owned-ordinary-source")
    previous = next(i for i in reversed(range(len(rows))) if rows[i]["event"] == "system-fixture-command" and rows[i]["action"] == "activate")
    require(any(r["event"] == "independent-setup-arrival" and r["target"] != origin for r in rows[:previous]) and
            next(r for r in rows[previous+1:] if r["event"] == "system-fixture-intent")["current"] == origin,
            "historicalReturnBeforeRemovalMissing")
    clean = json.loads((reference/"results.json").read_bytes())["cleanup"]
    require(all(clean[k] is True for k in ("ownedAppsExited","ownedWindowsGone","originalCurrentRestored","retainedFocusConfirmedTwice")) and
            clean["originalFocusRestoration"]["restored"] is True and not clean["errors"], "historicalReturnIncomplete")
    return Path(fixture[0]["executable"]).parents[2], fixture[0]["hash"]


def qualified_file(path):
    require(path.is_absolute() and path == path.resolve(strict=True) and path.is_file() and path.stat().st_uid == os.getuid()
            and not path.stat().st_mode & 0o022, "unqualifiedLocalInstrument")
    subprocess.run(["/usr/bin/codesign","--verify","--strict",path],capture_output=True,check=True,timeout=5)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def instruments(kit, stage):
    from p2_documents import static_part
    for folder in (kit,stage):
        require(folder.resolve(strict=True) == folder and folder.parent == Path("/private/tmp") and
                folder.name.startswith("nearpane-d01.") and folder.stat().st_uid == os.getuid() and
                not folder.stat().st_mode & 0o077, "unqualifiedPrivateInstrumentDirectory")
    probe = kit/"lease-visit-focus"
    static_part(probe,"net.example.nearpane.lease-visit-focus")
    app, expected_hash = archive_anchor()
    require(app.parent.parent == Path("/private/tmp") and app.parent.name.startswith("nearpane-d01.") and
            app.parent.resolve(strict=True) == app.parent and app.parent.stat().st_uid == os.getuid() and
            not app.parent.stat().st_mode & 0o077, "historicalAnchorKitUnavailable")
    verified = identity(app)
    require(verified["Identifier"] == ANCHOR_ID and verified["CDHash"] == expected_hash, "historicalAnchorSignatureChanged")
    subprocess.run(["/usr/bin/codesign","--verify","--strict","--deep",app],capture_output=True,check=True,timeout=8)
    exe = app/"Contents/MacOS/Lifecycle"
    paths = (exe,probe,stage/"p0-card",stage/"preview-space-select",stage/"system-workspace",stage/"observe")
    return exe, expected_hash, {p:qualified_file(p) for p in paths}


def verify_chain(ws, live, target):
    """Every still-existing creation must extend the previous immutable record by exactly its own ID and UUID."""
    require(not ws.closed and len(ws.ledgers) == 2 and len(set(ws.ids())) == 2, "pairedCreationReceiptsRequired")
    original = row(ws.original)
    before = stats(original,ws.original["displays"][0])
    ids = []
    for path in ws.ledgers:
        made = json.loads(private_file(path))
        intent = made["intent"]
        require(json.loads(private_file(path.with_name("create-intent.json"))) == intent and
                not path.with_name("removed.json").exists() and not path.with_name("remove-intent.json").exists() and
                intent["boot"] == ws.boot and intent["display"] == ws.display and intent["initial"] == before,
                "creationChainBootDisplayOrPredecessorChanged")
        after = made["after"]; n = made["target"]
        require(n not in before["spaceUUIDs"] and uuid.UUID(after["spaceUUIDs"][n]) and after["spaceUUIDs"][n] not in before["spaceUUIDs"].values() and
                after["spaceUUIDs"] == {**before["spaceUUIDs"],n:after["spaceUUIDs"][n]} and
                [x for x in after["sideOrder"] if x != n] == before["sideOrder"] and after["sideOrder"].count(n) == 1 and
                all(after[k] == before[k] for k in ("geometry","fullscreenIDs","primaryScope")), "creationReceiptNotSingleOrdinaryInsertion")
        ids.append(int(n)); before = after
    t = row(live)
    require(len(set(ids)) == 2 and ids[-1] == target and before == stats(t,live["displays"][0]) and
            abs(before["sideOrder"].index(str(ids[0])) - before["sideOrder"].index(str(ids[1]))) == 1,
            "currentPhysicalOrderNotOriginalPairedLease")
    return ids


def ordinary_anchor_rows(rows, generation, numbers, space):
    expected = set(numbers)
    return (len(expected) == len(numbers) == 2 and isinstance(rows,list) and len(rows) == 2 and
            all(isinstance(w,dict) and (w.get("pid"),w.get("birth")) == generation and
                w.get("standard") is True and w.get("forward") is True and w.get("reverse") == [space]
                for w in rows) and {w.get("number") for w in rows} == expected)


class VisitWorkspace(PREVIEW.PreviewWorkspace):
    pinned_hid = None

    def hardware(self):
        fresh = super().hardware()
        require(self.pinned_hid is None or fresh == self.pinned_hid, "newHumanInput")
        return fresh

    def reconcile_removed(self, snapshot):
        require(not self.closed and all(not p.with_name("remove-intent.json").exists() for p in self.ledgers),
                "unfinishedOrRetiredLeaseCannotBeVisited")

    def select(self, n):
        # The generic parent can dispatch a keyboard fallback for fullscreen. This route accepts ordinary only.
        current = self.check(self.read())
        valid = {r["id"] for r in current["records"] if r["type"] == 0}
        require(current["records"] == self.frozen and current["current"] == self.cleanup_current and
                n in self.ids() and n != current["current"] and {n,current["current"]} <= valid,
                "semanticOrdinaryEntryUnavailable")
        return super().select(n)

    def command(self, *args, **kwargs):
        raise ScopeError("onlySemanticAppleTileSelectionPermitted")


class FocusReader:
    def __init__(self, tool):
        self.process = subprocess.Popen([tool],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    def read(self, request=None):
        if request is not None:
            self.process.stdin.write(json.dumps(request)+"\n"); self.process.stdin.flush()
        require(select.select([self.process.stdout],[],[],4)[0], "retainedReaderTimeout")
        result = json.loads(self.process.stdout.readline())
        require(result.get("ready") is True, result.get("reason","retainedReaderUnavailable"))
        return result
    def close(self):
        self.process.stdin.close(); self.process.stdout.close()
        try: self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate(); self.process.wait(timeout=3)


class NativeVisit:
    def __init__(self, record, context, chain, save):
        self.rec, self.context, self.chain, self.save = record, context, chain, save
        self.ws = self.reader = self.original = self.anchor_focus = self.process = self.folder = None
        self.anchor, self.initial, self.observation = None, None, None
        self.anchor_numbers = []
        self.leg = "preflight"
        self.last_proof = None

    def event(self, name, **fields):
        if name == "system-AX-tile-result":
            raw = fields["proof"]
            proof = {k:raw[k] for k in ("issued","acknowledged","setupOnly","productActions","action",
                     "targetConfirmedBeforeOwnedOverviewClosed","overviewDismissed") if k in raw}
            if raw.get("error"): proof["reason"] = safe_reason(ScopeError(raw["error"]))
            self.last_proof = proof
            self.save("appleTileResult",source=fields["source"],target=fields["target"],proof=proof)
        elif name == "system-AX-tile-intent":
            self.save("appleTileIntent",source=fields["source"],target=fields["target"])
        elif name == "signed-install-continuity":
            self.save("signingContinuity",previous=fields["old"],current=fields["new"],bothDirections=fields["bothDirections"])

    def bind_profile(self):
        home = Path(self.context["NEARPANE_TEST_HOME"]); generation = Path(self.context["NEARPANE_TEST_GENERATION"])
        require(home.exists(),"isolatedHomeUnavailable"); validate_home(home)
        root = home/PROFILE
        index = root/"profile-index.json"
        require(index.resolve(strict=True) == index and index.is_file() and index.stat().st_uid == os.getuid() and
                index.stat().st_nlink == 1 and not index.stat().st_mode & 0o022 and index.stat().st_size <= 131072, "invalidProfileIndex")
        gen = json.loads(index.read_bytes())["active"]
        require(str(uuid.UUID(gen)) == gen and generation == root/"generations"/gen and generation.resolve(strict=True) == generation and
                installed_pid() == self.ws.host["pid"] and owns_profile(self.ws.host["pid"],root) and
                self.ws.host["codeHash"] == self.rec["candidate"]["cdhash"] and
                plistlib.loads((APP/"Contents/Info.plist").read_bytes())["NearpaneSourceRevision"] == self.rec["candidate"]["source"],
                "isolatedInstalledGenerationChanged")

    def construct(self):
        daily = self.rec.get("visitDailyOriginal",{})
        require(daily.get("ready") is True,daily.get("reason","dailyReferenceBeforeSwapUnavailable"))
        plan = self.rec["focusLease"]; self.target = plan["expectedSpace"]
        stage = Path(plan["stageKit"]); self.tool = stage/"p0-card"
        self.exe,self.hash,self.digests = instruments(Path(self.rec["visitFocusLeaseKit"]),stage)
        self.ws = VisitWorkspace(stage,Path(plan["workspace"]),self.event,resume=True,previous_archive=Path(plan["originArchive"]),
            install_receipt=self.chain,original_ledgers=Path(plan["originalCheckout"])/"build/verification/secondary-route-followup")
        self.bind_profile()
        self.ws.pinned_hid = self.ws.hardware()
        live = self.ws.read(); t = self.ws.check(live); self.ids = verify_chain(self.ws,live,self.target)
        self.ws.frozen = t["records"]; self.origin = t["current"]
        require(t["current"] in {r["id"] for r in row(self.ws.original)["records"] if r["type"] == 0} and
                self.ws.cleanup_current == self.origin and self.origin not in self.ids, "visitRequiresProtectedOrdinaryOrigin")
        self.reader = FocusReader(Path(self.rec["visitFocusLeaseKit"])/"lease-visit-focus")
        self.initial = self.reader.read()
        require(all(self.initial[k] == daily[k] for k in ("pid","birth","number","topology","hid")),
                "dailyForegroundOrInputChangedDuringHostExchange")
        expect = dict(display=t["scope"],current=self.origin,records=t["records"])
        require(self.initial["topology"] == expect and self.initial["pid"] != self.ws.host["pid"],
                "durableOriginalUserFocusNotBound")
        self.original = FOCUS.OriginalFocus(self.tool); held = self.original.reply()
        require(held.get("held") and all(held[k] == self.initial[k] for k in ("pid","birth","number","topology")) and
                self.paired_sample(self.origin,empty=True)["originExact"], "independentOriginalFocusOrEmptyLeaseUnavailable")
        self.save("enrolled",source=self.origin,target=self.target,owned=self.ids,display=self.ws.display,originalPID=held["pid"],
                  originalBirth=held["birth"],originalNumber=held["number"],boot=self.ws.boot,hostPID=self.ws.host["pid"],
                  hostBirth=self.ws.host_birth,hostCDHash=self.ws.host["codeHash"],generation=Path(self.context["NEARPANE_TEST_GENERATION"]).name)
        return self.origin,self.target

    def sample(self, empty=False):
        self.bind_profile(); self.ws.hardware()
        o = self.ws.read(); t = self.ws.check(o)
        require(t["records"] == self.ws.frozen and o.get("observerAX") is True and o.get("windowListAvailable") is True and
                o.get("privateTitlesRead") is False and o.get("pixelsRequested") == 0, "nativeCensusOrPhysicalScopeUnavailable")
        v = self.reader.read({"command":"sample"})
        require(v["current"] == t["current"] and (o.get("frontmostPID"),o.get("focusedNumber")) ==
                (v["systemFocus"]["pid"],v["systemFocus"]["number"]), "independentForegroundOrCurrentDisagreed")
        if empty:
            require(not o.get("scopedMembers",{}).get("unavailable"), "pairedMembershipUnavailable")
            summary = {}
            for sid in self.ids:
                c = o.get("scopedMembers",{}).get(str(sid),{})
                summary[str(sid)] = dict(ordinary=len(c["ordinary"]) if isinstance(c.get("ordinary"),list) else None,
                                           other=c.get("otherMembers"),unresolved=c.get("unresolved"))
                if c.get("unavailable") or c.get("sessionChanged") or not inactive_empty(c,sid,system_surfaces=True):
                    self.save("emptyAdmissionRefused",space=sid,counts=summary[str(sid)])
                    raise ScopeError("emptyLeaseOccupancyUnproved")
            v["census"] = summary
        self.ws.hardware()
        return v

    def paired_sample(self, sid=None, empty=False):
        samples = [self.sample(empty)]
        time.sleep(.12); samples.append(self.sample(empty))
        a,b = samples
        keys = ("current","originExact","originBound","anchorExact","primaryAnchorExact","systemFocus","appleIdle","anchors","census")
        require((sid is None or b["current"] == sid) and all(a.get(k) == b.get(k) for k in keys) and
                b["uptime"]-a["uptime"] >= .08, "twoIndependentReadbacksDidNotSettle")
        self.observation = b
        return b

    def authenticated(self):
        self.bind_profile()
        require(all(hashlib.sha256(p.read_bytes()).hexdigest() == d for p,d in self.digests.items()), "enrolledInstrumentChanged")

    def make_anchor(self):
        self.authenticated()
        require(self.paired_sample(self.origin,empty=True)["originExact"], "originChangedBeforeAnchor")
        self.folder = Path(tempfile.mkdtemp(prefix="nearpane-ordinary-return-",dir="/private/tmp"))/str(uuid.uuid4())
        self.folder.mkdir(mode=0o700)
        self.save("ownedAnchorLaunchIntent",space=self.origin,hash=self.hash)
        self.process = subprocess.Popen([self.exe,self.folder],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.started = time.monotonic()
        self.save("ownedAnchorStarted",pid=self.process.pid)
        def state():
            p = self.folder/"windows.json"
            if not p.exists(): raise FileNotFoundError
            return json.loads(private_file(p))
        s = P0.until(state,lambda x:x["session"] == self.folder.name and x["pid"] == self.process.pid and len(set(x["numbers"])) == 2,
                     "returnFixtureDidNotOpen",5)
        self.anchor_numbers = s["numbers"]; born = s["birth"]
        actual = P0.cmd(self.tool,"process",self.process.pid)
        require(actual["executable"] == str(self.exe) and actual["hash"] == self.hash and actual["identifier"] == ANCHOR_ID and
                actual["birth"] == born and self.process.poll() is None,"returnFixtureGenerationNotBound")
        binding = [{**actual,"number":number,"ownerFile":None} for number in self.anchor_numbers]
        # An application's assignment may place its new windows somewhere other than the active desktop.
        # Even its first local activation requires both CG/AX identities on the original Space.
        for _ in range(2):
            before = self.paired_sample(self.origin)
            require(before["originExact"] or (before["systemFocus"]["pid"] == self.process.pid and
                    before["systemFocus"]["number"] in self.anchor_numbers),"foregroundSupersededDuringAnchorAdmission")
            rows = P0.cmd(self.tool,"windows",body=binding).get("windows")
            require(ordinary_anchor_rows(rows,(self.process.pid,born),self.anchor_numbers,self.origin),
                    "syntheticAnchorNotExclusivelyOnLiveOrigin")
        self.ws.hardware()
        current = self.reader.read({"command":"sample"})
        require(current["current"] == self.origin and current["systemFocus"] == before["systemFocus"],
                "originChangedBeforeOwnedActivation")
        request = dict(nonce=str(uuid.uuid4()),action="activate",index=0)
        self.save("ownedAnchorActivationIntent",space=self.origin,pid=self.process.pid,number=self.anchor_numbers[0])
        with (self.folder/"request.json").open("x") as f: json.dump(request,f)
        P0.until(state,lambda x:x["lastCommand"] == request["nonce"] and x["key"] == self.anchor_numbers[0],"ownFixtureActivationUnconfirmed",4)
        self.save("ownedAnchorActivationAcknowledged",pid=self.process.pid,number=self.anchor_numbers[0])
        enrolled = self.reader.read(dict(command="enroll",pid=self.process.pid,birth=born,hash=self.hash,
                                        executable=str(self.exe),numbers=self.anchor_numbers))
        require(enrolled["primaryAnchorExact"],"returnFixtureAXNotFocused")
        self.anchor_focus = FOCUS.OriginalFocus(self.tool); held = self.anchor_focus.reply()
        require(held.get("held") and (held["pid"],held["birth"],held["number"],held["topology"]) ==
                (self.process.pid,born,self.anchor_numbers[0],self.initial["topology"]) and
                self.paired_sample(self.origin,empty=True)["primaryAnchorExact"],"retainedReturnAnchorUnavailable")
        self.save("returnAnchorEnrolled",pid=self.process.pid,birth=born,hash=self.hash,numbers=self.anchor_numbers,
                  exclusivelyAssigned=self.origin,retainedAX=True,historicalReturn="13-presentation-timing")

    def enter(self):
        self.authenticated()
        require(self.paired_sample(self.origin,empty=True)["primaryAnchorExact"], "anchorChangedBeforeAppleEntry")
        self.ws.select(self.target)
        state = self.paired_sample(self.target,empty=True)
        require(self.permitted_front(state) and not state["originExact"],"unclassifiedForegroundOnLease")
        self.save("leaseEntered",source=self.origin,target=self.target,counts=state.get("census"))
        require(time.monotonic()-self.started < 35,"anchorLifetimeTooShortForTrial")

    def permitted_front(self, s):
        return s["primaryAnchorExact"] or s["anchorExact"] or s["originExact"] or s["appleIdle"] or (
            s["systemFocus"]["pid"] == self.ws.host["pid"] and s["systemFocus"]["birth"] == self.ws.host_birth)

    def restore(self):
        self.authenticated()
        initial = self.paired_sample(empty=True)
        current = initial["current"]
        require(current in (self.origin,self.target) and self.permitted_front(initial), "unclassifiedSpaceOrNewForegroundPreserved")
        if current == self.target:
            require(self.anchor_focus and self.process.poll() is None and initial["anchors"] == 2,
                    "returnAnchorUnavailableOnLease")
            # The existing keeper validates the retained synthetic AX window, signature, birth, exclusive remote
            # membership and original HID immediately before its one activation. Only this fixture is addressed.
            keeper,self.anchor_focus = self.anchor_focus,None
            result = keeper.finish(True,self.target,expected=initial)
            self.save("returnAnchorAction",issued=result.get("issued"),confirmed=result.get("restored"))
            require(result.get("restored") is True and self.paired_sample(self.origin)["primaryAnchorExact"],
                    "returnToOriginByOwnedAppUnconfirmed")
        here = self.paired_sample(self.origin)
        if not here["originExact"]:
            require(self.process is not None and here["anchorExact"] and here["originBound"] and self.original is not None,
                    "unableToAttributeFocusChangeToOwnedFixture")
            keeper,self.original = self.original,None
            result = keeper.finish(True,expected=here)
            self.save("originalFocusAction",issued=result.get("issued"),confirmed=result.get("restored"))
            require(result.get("restored") is True and self.paired_sample(self.origin)["originExact"], "exactOriginalFocusDidNotReturn")
        self.close_owned()
        # The now-closed anchor must no longer be queried by the reader.
        final = self.paired_sample(self.origin,empty=True)
        require(final["originExact"],"originalFocusNotConfirmedAfterFixtureExit")
        self.save("originRestored",source=self.origin,originalReferenceMatched=True,fixtureExit="PASS" if self.process is not None else "NOT_NEEDED",counts=final.get("census"))

    def close_owned(self):
        if self.process is None: return
        proc = self.process
        if self.reader:
            self.reader.read({"command":"retire"})
        if proc.poll() is None:
            (self.folder/"close").touch(exist_ok=True)
            try: proc.wait(timeout=6)
            except subprocess.TimeoutExpired as e: raise ScopeError("ownedFixtureNormalExitUnconfirmed") from e
        require(proc.returncode == 0,"ownedFixtureExitAbnormal")
        if self.anchor_numbers:
            result = P0.cmd(self.tool,"absence",*self.anchor_numbers)
            require(result.get("absence") == [True]*len(self.anchor_numbers),"ownedWindowNumbersStillPresent")

    def finish_readers(self):
        if self.reader: self.reader.close()
        for keeper in (self.original,self.anchor_focus):
            if keeper: keeper.finish(False)
        if self.folder and self.process and self.process.poll() is not None:
            for name in ("windows.json","request.json","close"):
                (self.folder/name).unlink(missing_ok=True)
            if not any(self.folder.iterdir()): self.folder.rmdir(); self.folder.parent.rmdir()

    def retire_after_refusal(self):
        if self.process is None or self.process.poll() is not None: return
        # When the user took control, do not close the window they are using. An inactive private test
        # process can close its own windows without input or activation. Never use kill as a desktop fallback.
        sampled = P0.cmd(self.tool,"state")
        pid = sampled.get("systemFocus",{}).get("pid") if isinstance(sampled.get("systemFocus"),dict) else None
        if not pid: self.save("ownerExitDeferred",reason="foregroundUnavailable"); return
        if pid == self.process.pid:
            try:
                live = self.reader.read({"command":"sample"})
                require(live["current"] == self.origin and live["systemFocus"]["pid"] == pid,
                        "foregroundCouldBeUsingOwnedFixture")
            except READ_ERRORS:
                self.save("ownerExitDeferred",pid=self.process.pid,reason="foregroundCouldBeUsingOwnedFixture")
                return
        (self.folder/"close").touch(exist_ok=True)
        self.process.wait(timeout=6)
        absent = P0.cmd(self.tool,"absence",*self.anchor_numbers) if self.anchor_numbers else {}
        self.save("backgroundOwnedFixtureClosed",processExited=self.process.poll() is not None,windowsGone=absent.get("absence"))


def journey(native, product, status, persist):
    """An issued or uncertain action is never replayed. Product and two setup legs have independent outcomes."""
    prepared = False
    running_child = False
    try:
        native.construct()
        prepared = True
        native.make_anchor()
        status["entry"] = "UNKNOWN"; persist()
        native.enter()
        status["entry"] = "PASS"; persist()
        status["childStarted"] = True; persist()
        status["childExit"] = product()
    except subprocess.TimeoutExpired:
        if status["childStarted"] and "childExit" not in status:
            running_child = True
            status.update(status="UNKNOWN",restoration="UNKNOWN",reason="runningChildStillOwnsTransaction")
            persist()
            raise
        status["reason"] = "instrumentTimeout"
    except READ_ERRORS as err:
        status["reason"] = safe_reason(err)
        proof = getattr(native,"last_proof",None)
        if status["entry"] == "UNKNOWN" and isinstance(proof,dict) and proof.get("issued") is False:
            status["entry"] = "BLOCKED"
    finally:
        if prepared and not running_child:
            try:
                native.restore()
                status["restoration"] = "PASS"
            except READ_ERRORS as err:
                status.update(restoration="UNKNOWN",returnReason=safe_reason(err))
                try: native.retire_after_refusal()
                except READ_ERRORS as e: status["fixtureCleanupReason"] = safe_reason(e)
        try: native.finish_readers()
        except READ_ERRORS as err: status["readerCloseReason"] = safe_reason(err)
        persist()
    if status.get("childStarted") and status.get("restoration") == "PASS" and "childExit" in status:
        status["status"] = "PASS"
    elif status.get("restoration") == "UNKNOWN":
        status["status"] = "UNKNOWN"
    persist()
    return status


def run(record, context, chain, dest, product):
    from contract_workspace import write_owned
    dest.mkdir(mode=0o700,exist_ok=False)
    status = dict(schema=1,status="BLOCKED",scope="setup-and-restoration-only",entry="NOT_RUN",childStarted=False,
                  restoration="NOT_NEEDED",officialGateEligible=False,productInputsBySetup=0,spacesCreatedOrRemoved=0)
    def persist():
        tmp = dest/"receipt.next"
        write_owned(tmp,status); tmp.replace(dest/"receipt.json")
    def event(kind,**details):
        with (dest/"events.jsonl").open("a") as f:
            f.write(json.dumps(dict(stage=kind,uptime=time.monotonic(),**details))+"\n"); f.flush(); os.fsync(f.fileno())
    persist()
    return journey(NativeVisit(record,context,chain,event),product,status,persist)


def daily_reference(kit, daily_pid):
    reader = None
    try:
        reader = FocusReader(Path(kit)/"lease-visit-focus")
        held = reader.read()
        require(held["pid"] != daily_pid, "dailyHostWindowWillChangeProcessGeneration")
        require(reader.read({"command":"sample"})["originExact"] is True, "dailyFocusNotCoherent")
        return reader,{k:held[k] for k in ("ready","pid","birth","number","topology","hid")}
    except READ_ERRORS as err:
        if reader: reader.close()
        return None,dict(ready=False,reason=safe_reason(err))


def after_daily(reader):
    if reader is None: return dict(status="UNKNOWN",reason="initialDailyReferenceUnavailable")
    try:
        a = reader.read({"command":"sample"}); time.sleep(.12); b = reader.read({"command":"sample"})
        require(a["originExact"] and b["originExact"] and a["current"] == b["current"] and b["uptime"] > a["uptime"],
                "originalWindowNotFocusedAfterDailyHostReturn")
        return dict(status="PASS",originalReferenceMatchedTwice=True,source=a["current"],uptimes=[a["uptime"],b["uptime"]])
    except READ_ERRORS as err:
        return dict(status="UNKNOWN",reason=safe_reason(err))
    finally:
        reader.close()
