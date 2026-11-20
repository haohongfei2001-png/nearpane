"""W01 against the signed, Launch Services-registered two-document fixture on the current lease."""
import hashlib
import json
import os
import shutil
import secrets
import subprocess
import struct
import tempfile
import time
import uuid
import zlib
from pathlib import Path

from acceptance import identity
from field_marker_witness import MarkerWatch
from installed_profile import PROFILE, owns_profile
from p2_stage_surfaces import fresh_ordinary_reader
from space_scope import ScopeError, private_file


class TrialStop(ValueError):
    def __init__(self, reason, status="BLOCKED"):
        self.reason, self.status = reason, status
        super().__init__(reason)


class Superseded(TrialStop):
    def __init__(self):
        super().__init__("userSuperseded")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, reason, status="BLOCKED"):
    if not condition:
        raise TrialStop(reason, status)


def static_part(path, identifier):
    requirement = (f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "ZB9D4T66QB" '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    require(path.resolve(strict=True) == path and subprocess.run(
        ["/usr/bin/codesign","--verify","--strict","--deep","-R="+requirement,path], capture_output=True, timeout=5).returncode == 0,
        "fixtureOrObserverDeveloperIDInvalid")
    signed = identity(path)
    require(signed["Identifier"] == identifier and signed["TeamIdentifier"] == "ZB9D4T66QB" and
            len(signed.get("CDHash") or "") == 40, "stableSigningIdentityUnavailable")
    return signed


def open_documents(app, folder, authorize):
    home = folder / "home"
    home.mkdir(mode=0o700)
    for name in ("A","B"):
        fd = os.open(folder/(name+".txt"), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd,"wb") as f:
            f.write(f"Field Notes {name} {folder.name}\n".encode())
    admission=authorize()
    return subprocess.Popen(["/usr/bin/open","-n","-W","-a",str(app),"--env","HOME="+str(home),
                             "--env","NP_P2_LAUNCH_ADMISSION="+json.dumps(admission,separators=(",",":")),
                             "--env","CFFIXED_USER_HOME="+str(home),"--env","NP_FIXTURE_PRESENTATION=p2-documents",
                             "--env","NP_W01_MARKER_WITNESS=1","--args",str(folder),"2"],
                            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


def check_hid(proof, baseline):
    if proof.get("reason") == "userSuperseded" or proof.get("userSuperseded") or (
            baseline is not None and proof.get("hidAfter", proof.get("hid")) is not None and proof.get("hidAfter", proof.get("hid")) != baseline):
        raise Superseded()


def coherent(q, state, disk):
    return (q.get("status") == "READ" and state.get("pid") == q["registration"]["pid"]
            and state.get("birth") == q["registration"]["birth"] and state.get("numbers") == q["numbers"]
            and state.get("filesSaved") == [True, True] and q["axSHA256"] == state.get("sha256") == disk)


def capture_dimensions(raw):
    if not 45<=len(raw)<=8_000_000 or not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("singleWindowPNGUnavailable")
    pos=8
    size=None
    image_data=False
    while pos+12<=len(raw):
        length,kind=struct.unpack(">I4s",raw[pos:pos+8])
        end=pos+8+length
        if end+4>len(raw) or zlib.crc32(raw[pos+4:end])!=int.from_bytes(raw[end:end+4],"big"):
            break
        if pos==8:
            if kind!=b"IHDR" or length!=13:break
            size=struct.unpack(">II",raw[pos+8:pos+16])
        if kind==b"IDAT" and length>0:image_data=True
        if kind==b"IEND" and length==0 and end+4==len(raw) and image_data and size:
            if 80<=size[0]<=2048 and 60<=size[1]<=2048:return size
            raise ValueError("fixtureImageDimensionsUnexpected")
        pos=end+4
    raise ValueError("incompleteSingleWindowPNG")


def classify_read(q, state, disk, target, hashes, expect_focus):
    if not coherent(q, state, disk) or disk != hashes:
        return False
    if not expect_focus:
        return True
    if target is None:
        target=q.get("focused")
    if target not in q["numbers"]:
        return False
    index = q["numbers"].index(target)
    return (q.get("focused") == q.get("main") == state.get("key") == state.get("main") == target
            and q.get("editorFocused") is True and state.get("editorsFocused",[])[index:index+1] == [True])


class RegisteredRun:
    def __init__(self, observer, initial, rec, lease_hid, lease_workspace=None, lease_admission=None):
        override = os.environ.get("NP_P2_DOCUMENT_KIT") or os.environ.get("NP_W01_MARKER_KIT")
        self.kit = Path(override) if override else observer.parent
        self.observer = self.kit/"observe"
        self.app = self.kit/"Field Notes.app"
        self.folder = self.kit/str(uuid.uuid4())
        self.rec, self.initial, self.lease_hid = rec, initial, lease_hid
        self.workspace=lease_workspace
        self.lease_admission=lease_admission
        scope = initial["scopes"][0]
        self.binding = dict(hostPID=initial["host"]["pid"],hostHash=initial["host"]["codeHash"],display=scope["scope"],space=scope["current"],allowedFront=initial.get("frontmostPID"))
        self.baseline = None
        self.launcher = None
        self.folder_created=False
        self.watch = None
        self.trial = 0
        self.attempt = None
        self.samples = []
        self.out = dict(status="BLOCKED",reason="notStarted",passes=0,launch="foreground Launch Services open -n -W -a",
                        registration=None,superseded=False,focusRestoreRequested=False,attempts=[],cleanup={"status":"NOT_RUN"},
                        firstDocumentCapture={"status":"NOT_RUN","reason":"firstIndependentlyVerifiedInputUnavailable"},
                        fixturePreparation={"status":"NOT_RUN","issued":False,"productAction":False})

    def call(self, mode, extra=None, env=None, timeout=6):
        request = {**self.binding, **(extra or {}), "mode":mode}
        proc = subprocess.run([self.observer,"p2-document"],input=json.dumps(request),capture_output=True,text=True,timeout=timeout,env=env)
        require(proc.returncode == 0, "witnessProcessFailed","UNKNOWN")
        q = json.loads(proc.stdout)
        require(isinstance(q,dict), "invalidWitnessReply","UNKNOWN")
        return q

    def opened(self):
        until = time.monotonic()+8
        while time.monotonic()<until:
            check_hid(self.call("baseline"),self.baseline)
            try:
                startup=json.loads(private_file(self.folder/"startup.json"))
                if (startup.get("session")==self.folder.name and startup.get("bundle")=="net.example.spaces-document" and
                        startup.get("policy")==0 and type(startup.get("pid")) is int and startup["pid"]>1 and
                        type(startup.get("birth")) is int and startup["birth"]>0 and startup["pid"]!=self.launcher.pid):
                    self.binding.update(pid=startup["pid"],birth=startup["birth"])
                    s=json.loads(private_file(self.folder/"windows.json"))
                    numbers=s.get("numbers")
                    if (s.get("session")==self.folder.name and s.get("pid")==startup["pid"] and s.get("birth")==startup["birth"] and
                            isinstance(numbers,list) and len(numbers)==2 and all(type(n) is int and n>0 for n in numbers) and
                            numbers[0]!=numbers[1] and s.get("presentation")=="p2-documents"):
                        self.binding["numbers"]=numbers
                        return
            except (OSError,ValueError):
                pass
            if self.launcher.poll() is not None:
                break
            time.sleep(.06)
        raise TrialStop("noFreshLaunchServicesFixtureEnrollment")

    def read_until(self, target, hashes, stage, *, focus=False, ready=False, seconds=4):
        deadline=time.monotonic()+seconds
        good=0
        last, mismatch, consistent_mismatches = {}, None, 0
        recent = []
        observed_issues=set()
        front_counts={"fixture":0,"other":0}
        while (remaining:=deadline-time.monotonic())>=.12:
            try:
                q=self.call("read",timeout=remaining)
                check_hid(q,self.baseline)
                last = {k:q[k] for k in ("status","reason","clock","hostBirth","reportedWindows","copiedWindows","enrolledAXMatches","ownedLayerZero","enrolledMemberships","slot",
                                            "urlMatches","roleMatches","identifierMatches","editorCount","registrationStage",
                                            "frontIsFixture","frontMatchesOriginal","knownIssueMessages") if k in q}
                observed_issues.update(q.get("knownIssueMessages",[]))
                if type(q.get("frontIsFixture")) is bool:
                    front_counts["fixture" if q["frontIsFixture"] else "other"]+=1
                if q.get("registration"):
                    self.out["registration"]=q["registration"]
                if q.get("status")=="READ":
                    state=json.loads(private_file(self.folder/"windows.json"))
                    disk=[digest(private_file(self.folder/(x+".txt"),limit=4096)) for x in ("A","B")]
                    require(state.get("session")==self.folder.name,"fixtureFileGenerationChanged")
                    ok=classify_read(q,state,disk,target,hashes,focus) and (not ready or q.get("cards")==[True,True])
                    last.update(axSHA256=q["axSHA256"],fixtureSHA256=state.get("sha256"),fileSHA256=disk,
                                focused=q.get("focused"),main=q.get("main"),editorFocused=q.get("editorFocused"),
                                localKey=state.get("key"),localMain=state.get("main"),cards=q.get("cards"))
                    recent = (recent+[last])[-2:]
                    if not ok and coherent(q,state,disk):
                        observed=(tuple(disk), q.get("focused"), q.get("main"), q.get("editorFocused"),state.get("key"),state.get("main"))
                        consistent_mismatches=consistent_mismatches+1 if observed==mismatch else 1
                        mismatch=observed
                    else:
                        mismatch,consistent_mismatches=None,0
                    good=good+1 if ok else 0
                    if good>=2:
                        self.rec.log("P2-independent-document-read",trial=self.trial,stage=stage,confirmed=True,expectedSHA256=hashes,reads=recent)
                        return q
                else:
                    good=0
                    mismatch,consistent_mismatches=None,0
                    if q.get("reason") in ("installedHostOrLeasedSpaceChanged","kernelExecutableIdentityChanged",
                                          "generationChangedAtReadback","wrongFixtureOrSession","unsupportedFixtureKit"):
                        raise TrialStop(q["reason"],"UNKNOWN")
            except TrialStop:
                raise
            except (OSError,ValueError,subprocess.SubprocessError) as e:
                good=0
                mismatch,consistent_mismatches=None,0
                if not last: last={"reason":type(e).__name__}
            time.sleep(max(0,min(.09,deadline-time.monotonic())))
        self.rec.log("P2-independent-document-read",trial=self.trial,stage=stage,confirmed=False,expectedSHA256=hashes,reads=recent,last=last,
                     observedKnownIssueMessages=sorted(observed_issues),frontmostCounts=front_counts)
        raise TrialStop("independent"+stage+"Unconfirmed","FAIL" if consistent_mismatches>=2 and focus else "UNKNOWN" if self.attempt else "BLOCKED")

    def partial_readback(self, texts, marker):
        lookups=[{digest((text+marker[:n]).encode()):n for n in range(len(marker)+1)} for text in texts]
        samples=[]
        for _ in range(2):
            q=self.call("read")
            check_hid(q,self.baseline)
            state=json.loads(private_file(self.folder/"windows.json"))
            files=[digest(private_file(self.folder/(s+".txt"),limit=4096)) for s in "AB"]
            exact=state.get("session")==self.folder.name and coherent(q,state,files)
            prefixes=[positions.get(d) for positions,d in zip(lookups,files)] if exact else [None,None]
            samples.append(dict(clock=q.get("clock"),coherent=exact,fileSHA256=files,axSHA256=q.get("axSHA256"),
                                selected=q.get("focused"),main=q.get("main"),editorFocused=q.get("editorFocused"),committedDigits=prefixes))
            if len(samples)==1:time.sleep(.08)
        self.rec.log("P2-partial-marker-readback",trial=self.trial,samples=samples)
        stable=samples[0]["committedDigits"]==samples[1]["committedDigits"] and all(s["coherent"] for s in samples)
        return "FAIL" if stable and None not in samples[0]["committedDigits"] else "UNKNOWN"

    def capture_first(self,target,hashes):
        proof={"status":"NOT_RUN","scope":"sole enrolled document window","target":target}
        self.out["firstDocumentCapture"]=proof
        def bound():
            q=self.call("read",timeout=1.2)
            check_hid(q,self.baseline)
            state=json.loads(private_file(self.folder/"windows.json"))
            files=[digest(private_file(self.folder/(s+".txt"),limit=4096)) for s in "AB"]
            if not (q.get("screenRead") and state.get("session")==self.folder.name and classify_read(q,state,files,target,hashes,True)):
                raise ValueError("exactSourceOrCapturePermissionUnavailable")
            return dict(clock=q["clock"],pid=q["registration"]["pid"],birth=q["registration"]["birth"],
                        hostBirth=q["hostBirth"],window=target,hid=q["hid"],fileSHA256=files)
        try:
            if not self.initial.get("observerScreenRead"):
                raise ValueError("screenRecordingPreflightUnavailable")
            before=bound()
            with tempfile.TemporaryDirectory(prefix=".doc-crop.",dir=self.folder) as tmp:
                png=Path(tmp)/"source.png"
                delivery=subprocess.run(["/usr/sbin/screencapture","-x","-o","-t","png","-l"+str(target),str(png)],
                                        capture_output=True,timeout=1.2)
                after=bound()
                if delivery.returncode or not png.is_file() or any(before[k]!=after[k] for k in before if k!="clock"):
                    raise ValueError("captureOrIndependentRecheckUnavailable")
                raw=png.read_bytes()
                width,height=capture_dimensions(raw)
                filename="first-registered-document.png"
                with (self.rec.output/filename).open("xb") as out:out.write(raw)
                proof.update(status="CAPTURED",file=filename,sha256=digest(raw),width=width,height=height,before=before,after=after)
        except Superseded:
            proof["reason"]="userSuperseded"
            raise
        except (ValueError,OSError,KeyError,subprocess.SubprocessError) as ex:
            proof["reason"]=str(ex)[:120] if isinstance(ex,ValueError) else type(ex).__name__

    def seal(self):
        if self.watch is None:
            return
        watch=self.watch
        self.watch=None
        result=watch.seal()
        self.rec.write(f"marker-witness-{self.trial:02}.json",result)
        self.rec.log("P2-fixture-event-closure",trial=self.trial,intent=watch.identity["intent"],status=result["status"],
                     closureConfirmed=result["closureConfirmed"],receiverDisposition=result.get("receiverDisposition"),steps=[v["step"] for v in result["events"]])
        return result

    def admit_foreground_launch(self):
        from contract_workspace import empty_system_desktop
        ws=self.workspace
        prep=self.out["fixturePreparation"]
        require(ws is not None and prep["status"]=="NOT_RUN" and self.launcher is None and not self.out["attempts"],
                "foregroundLaunchNotFreshOrUnleased")
        space=self.binding["space"]
        require(space in ws.ids() and ws.host["pid"]==self.binding["hostPID"] and ws.host["codeHash"]==self.binding["hostHash"]
                and ws.host_birth==self.binding["hostBirth"],"foregroundLaunchHostGenerationOrLeaseChanged")
        try:
            checker=fresh_ordinary_reader(ws, self.binding, self.lease_admission, self.observer, self.rec.log)
            empty=empty_system_desktop(ws,space,check_ordinary=checker)
            require(len(empty)==2 and empty[1]["uptime"]>empty[0]["uptime"],"independentEmptyLeaseReadsUnavailable")
        except ScopeError as error:
            raise TrialStop("emptyOrdinaryLeaseUnconfirmed:"+str(error)) from error
        proof=self.call("launch-admission",timeout=2)
        check_hid(proof,self.baseline)
        require(proof.get("status")=="LAUNCH_ADMITTED" and proof.get("frontMatchesOriginal") is True and
                proof.get("protectedFrontBirth")==self.binding["allowedFrontBirth"] and proof.get("hid")==self.baseline,
                "foregroundLaunchAdmissionUnconfirmed")
        prep.update(status="INTENT",productAction=False,issued=None,id=str(uuid.uuid4()),emptyLeaseReads=empty,
                    originalForegroundBirth=proof["protectedFrontBirth"],checkedAt=proof["clock"],spaceUUID=proof["spaceUUID"],
                    method="singleForegroundLaunchServicesOpen")
        self.rec.log("P2-foreground-launch-admitted",**prep)
        return dict(session=self.folder.name,originalFront=self.binding["allowedFront"],hardware=self.baseline,admittedAt=proof["clock"])

    def prepare_front(self, hashes):
        prep=self.out["fixturePreparation"]
        require(self.trial==0 and prep["status"]=="REQUESTED" and not self.out["attempts"],"foregroundLaunchNotAdmitted")
        try:
            ready=self.read_until(None,hashes,"InitialForegroundDocument",ready=True,focus=True,seconds=6)
        except Superseded:
            prep.update(status="SUPERSEDED",reason="userSuperseded")
            raise
        except TrialStop as error:
            prep.update(status="BLOCKED",reason=error.reason)
            raise TrialStop("foregroundLaunchEditorUnconfirmed:"+error.reason,"BLOCKED") from error
        require(ready.get("frontIsFixture") is True and ready.get("focused") in self.binding["numbers"],"independentInitialFixtureFocusUnavailable")
        prep.update(status="VERIFIED",focused=ready["focused"])
        self.rec.log("P2-foreground-launch-readback",productAction=False,focused=ready["focused"],id=prep["id"])
        return ready["focused"]

    def select_document(self, target, intent, attempt):
        click=self.call("press",target)
        self.rec.log("sidebar-press",intent=intent,result=click)
        attempt["pressIssued"]=click.get("issued")
        attempt["pressGateReason"]=click.get("reason","exactInstalledSidebarControlAdmitted")
        check_hid(click,self.baseline)
        require(click.get("issued") is True,"installedSidebarPressRefused","BLOCKED" if click.get("issued") is False else "UNKNOWN")
        require(type(click.get("axError")) is int and click["axError"]==0,"installedSidebarRejectedAXPress","FAIL")

    def trials(self, reader):
        texts=[f"Field Notes {n} {self.folder.name}\n" for n in ("A","B")]
        hashes=[digest(t.encode()) for t in texts]
        initial_focus=self.prepare_front(hashes)
        return self.selection_trials(reader, texts, hashes, initial_focus)

    def selection_trials(self, reader, texts, hashes, initial_focus):
        numbers=self.binding["numbers"]
        first_slot=1 if initial_focus==numbers[0] else 0
        unique_tokens=secrets.SystemRandom().sample(range(10**12),10)
        for turn in range(10):
            self.trial=turn+1; self.attempt=None
            slot=(first_slot+turn)%2; n=numbers[slot]
            before=self.read_until(numbers[1-slot],hashes,"BeforeSelection",ready=True,focus=True)
            require(before.get("focused")==numbers[1-slot],"siblingLostFocusBeforeNewSelection")
            target={"target":n,"digests":hashes,"allowedFront":self.binding["pid"]}
            intent=str(uuid.uuid4()); marker=f"{unique_tokens[turn]:012d}"
            self.watch=MarkerWatch(self.folder,self.folder.name,intent,self.binding["pid"],self.binding["birth"],numbers,n,marker,reader,transport="pidNumericKeypad")
            require(self.watch.arm(),"postReceiverEnrollmentUnavailable")
            attempt=dict(id=intent,kind="window",trial=self.trial,target=n,sibling=numbers[1-slot],status="UNKNOWN",markerIssued=None)
            self.attempt=attempt; self.rec.attempts.append(attempt);self.out["attempts"].append(attempt)
            self.rec.log("P2-window-intent",**attempt)
            self.select_document(target, intent, attempt)
            self.read_until(n,hashes,"Focus",focus=True)
            env=dict(os.environ,NP_W01_MARKER_WITNESS="1",NP_TRIAL_MARKER=marker,NP_TRIAL_MARKER_TAG=str(self.watch.grant["tag"]),
                     NP_TRIAL_MARKER_SESSION=self.folder.name,NP_TRIAL_MARKER_INTENT=intent,NP_TRIAL_MARKER_READER=reader)
            require(time.monotonic()<self.watch.grant["expires"],"markerEnrollmentExpired")
            self.watch.submitted()
            sent=self.call("marker",target,env,timeout=min(11,max(0.1,self.watch.grant["expires"]-time.monotonic())))
            tagged=self.watch.dispatched(sent)
            attempt["markerIssued"]=sent.get("issued")
            attempt["markerGateReason"]=sent.get("reason")
            self.rec.log("pid-targeted-marker",intent=intent,result=sent)
            check_hid(sent,self.baseline)
            require(sent.get("issued") is True,"targetedMarkerNotAdmitted","UNKNOWN")
            if sent.get("complete") is not True:
                partial=self.partial_readback(texts,marker)
                receipt=self.seal()
                attempt["receiverDisposition"]=receipt.get("receiverDisposition")
                raise TrialStop("ordinaryKeyDeliveryIncomplete:"+str(sent.get("reason")),partial)
            texts[slot]+=marker
            hashes=[digest(t.encode()) for t in texts]
            self.read_until(n,hashes,"Input",focus=True,seconds=2.5)
            receipt=self.seal()
            require(tagged and receipt.get("receiverDisposition")=="COMPLETE_REGISTERED_SEQUENCE" and receipt["closureConfirmed"] and not receipt["truncated"],"fixtureMarkerProvenanceIncomplete","UNKNOWN")
            attempt.update(status="PASS",siblingUnchanged=True)
            self.out["passes"]+=1
            if self.trial==1:self.capture_first(n,hashes)
        self.out.update(status="PASS",reason="tenExactAlternatingWindowsAndInputs")
        return hashes

    def cleanup(self):
        if self.launcher is None:
            if self.folder_created and self.folder.parent==self.kit and self.folder.name==self.binding.get("session") and self.folder.resolve()==self.folder:
                if self.out["fixturePreparation"]["status"]=="NOT_RUN":
                    shutil.rmtree(self.folder)
                    self.out["cleanup"]={"status":"PASS","ownedSessionRemoved":not self.folder.exists(),"launchIssued":False}
                else:
                    self.out["cleanup"]={"status":"UNKNOWN","reason":"foregroundLaunchReceiptUnavailable"}
            return
        # Closing an active fixture after real input would change the user's new focus.
        token="close-when-inactive" if self.out["superseded"] else "close"
        (self.folder/token).touch(mode=0o600,exist_ok=True)
        if "numbers" not in self.binding:
            self.out["cleanup"]={"status":"UNKNOWN","signal":token,"reason":"fixtureGenerationNotFullyEnrolled"}
            return
        end=time.monotonic()+2.5
        latest={}
        while time.monotonic()<end:
            latest=self.call("exit",timeout=2)
            if (self.folder/"p2-user-superseded").is_file():
                self.out.update(superseded=True,status="BLOCKED",reason="userSuperseded")
            if latest.get("status")=="EXITED":break
            if self.out["superseded"] and latest.get("frontIsFixture"):break
            time.sleep(.12)
        self.out["cleanup"]={"status":"PASS" if latest.get("status")=="EXITED" else
                             "DEFERRED_UNTIL_INACTIVE" if self.out["superseded"] and latest.get("frontIsFixture") else "UNKNOWN",
                             "signal":token,"readback":latest,"launcherExit":self.launcher.poll()}
        if (latest.get("status")=="EXITED" and self.folder.parent==self.kit
                and self.folder.name==self.binding.get("session") and self.folder.resolve()==self.folder):
            shutil.rmtree(self.folder)
            self.out["cleanup"]["ownedSessionRemoved"]=not self.folder.exists()

    def run(self):
        try:
            require(isinstance(self.lease_hid,list) and len(self.lease_hid)==5 and all(type(v) is int for v in self.lease_hid),
                    "verifiedExistingOrdinarySpaceLeaseRequired")
            require(self.kit.resolve(strict=True)==self.kit and self.kit.parent==Path("/private/tmp") and self.kit.name.startswith("nearpane-d01.")
                    and self.kit.stat().st_uid==os.getuid() and not self.kit.stat().st_mode & 0o077,"unqualifiedRegisteredFixtureKit")
            home=os.environ.get("NEARPANE_TEST_HOME")
            require(home and owns_profile(self.binding["hostPID"],Path(home)/PROFILE),"formalHostIsolatedProfileUnavailable")
            fixture=static_part(self.app,"net.example.spaces-document")
            reader=static_part(self.observer,"net.example.nearpane.p2-observer")
            self.out["fixtureSigning"]=fixture;self.out["observerSigning"]=reader
            base=self.call("baseline")
            check_hid(base,None)
            require(base.get("status")=="READY" and len(base.get("hid",[]))==13,"hardwareOrHostBaselineUnavailable")
            self.baseline=base["hid"]
            if self.baseline[:5]!=self.lease_hid:raise Superseded()
            uuid_value=next((r.get("uuid") for r in self.initial["scopes"][0]["records"] if r["id"]==self.binding["space"]),None)
            require(isinstance(uuid_value,str) and str(uuid.UUID(uuid_value))==uuid_value.lower() and
                    isinstance(base.get("protectedFrontBirth"),int) and base["protectedFrontBirth"]>0,
                    "originalForegroundGenerationOrLeaseUUIDUnavailable")
            self.binding.update(allowedFrontBirth=base["protectedFrontBirth"],spaceUUID=uuid_value)
            self.out["scope"]={**self.binding,"hostBirth":base["hostBirth"],"leaseHardwareCounters":self.lease_hid}
            self.binding.update(hostBirth=base["hostBirth"],hid=self.baseline,folder=str(self.folder),app=str(self.app),hash=fixture["CDHash"],session=self.folder.name)
            self.folder.mkdir(mode=0o700)
            self.folder_created=True
            self.launcher=open_documents(self.app,self.folder,self.admit_foreground_launch)
            self.out["fixturePreparation"].update(status="REQUESTED",issued=True,launcherPID=self.launcher.pid)
            self.rec.log("P2-launch-services-open",session=self.folder.name,launcherPID=self.launcher.pid,background=False,productAction=False)
            self.opened()
            self.rec.log("P2-fixture-app-bound",session=self.folder.name,launcherPID=self.launcher.pid,fixturePID=self.binding["pid"],
                         birth=self.binding["birth"],numbers=self.binding["numbers"])
            self.trials(reader["CDHash"])
        except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:
            self.out.update(status=e.status if isinstance(e,TrialStop) else "UNKNOWN",reason=e.reason if isinstance(e,TrialStop) else type(e).__name__)
            self.out["superseded"]=isinstance(e,Superseded)
            if self.attempt is not None and self.attempt["status"]!="PASS": self.attempt.update(status=self.out["status"],reason=self.out["reason"])
        finally:
            if self.baseline is not None:
                try:check_hid(self.call("baseline"),self.baseline)
                except Superseded:self.out.update(superseded=True,status="BLOCKED",reason="userSuperseded")
                except (OSError,ValueError,subprocess.SubprocessError):pass
            try:self.seal()
            except (OSError,ValueError,subprocess.SubprocessError):self.out["witnessClosure"]="UNKNOWN"
            try:self.cleanup()
            except (OSError,ValueError,subprocess.SubprocessError):self.out["cleanup"]={"status":"UNKNOWN","reason":"ownedCleanupReadbackUnavailable"}
            if self.out["superseded"] and os.environ.get("NEARPANE_TEST_HOME"):
                (Path(os.environ["NEARPANE_TEST_HOME"])/"p2-user-superseded").touch(mode=0o600,exist_ok=True)
            self.out["operationStatus"]=self.out["status"] if self.out["attempts"] else "NOT_RUN"
            if self.out["status"]=="PASS" and self.out["cleanup"]["status"]!="PASS":self.out.update(status="UNKNOWN",reason="ownedCleanupUnconfirmed")
            self.publish()
        return self.out["reason"]

    def publish(self):
        self.rec.write("registered-documents.json",self.out)
        self.rec.summary["controlledWindowTrials"]=self.out["passes"]
        self.rec.scenarios["W01"]={"status":self.out["status"],"reason":self.out["reason"]}
        self.rec.summary["registeredDocuments"]={k:self.out[k] for k in ("status","operationStatus","reason","passes","superseded","focusRestoreRequested","fixturePreparation","firstDocumentCapture","cleanup")}
