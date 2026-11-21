#!/usr/bin/env python3
"""Temporarily validate a signed candidate at the registered path; recover never replays a trial."""
import argparse
from contextlib import ExitStack, contextmanager
import ctypes
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import installed_profile as profile
import private_spaces_trials as spaces_trials
from acceptance import host_current_permissions, identity

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))
from private_notary import gate, publisher, read_json, require, sha

HOST = Path("Contents/MacOS/NearpaneHost")
ROOT = Path.home() / "Library/Application Support/Nearpane Acceptance Install"
LOCK_FILE = "writer.lock"


def inode(path):
    info = path.lstat()
    return [info.st_dev, info.st_ino]


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def persist(path, record):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        temp = Path(out.name)
        try:
            out.write((json.dumps(record, ensure_ascii=False, indent=2) + "\n").encode())
            out.flush()
            os.fsync(out.fileno())
            if hasattr(fcntl, "F_FULLFSYNC"):
                fcntl.fcntl(out, fcntl.F_FULLFSYNC)
        except BaseException:
            temp.unlink()
            raise
    try:
        os.replace(temp, path)
        fsync_dir(path.parent)
    finally:
        temp.unlink(missing_ok=True)


def owned_dir(path, create=False):
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    s = path.lstat()
    require(path == path.resolve() and stat.S_ISDIR(s.st_mode)
            and s.st_uid == os.getuid() and not s.st_mode & 0o077, "Untrusted private directory: " + str(path))


def public_tree(path):
    """Bind file names, modes, symlink destinations and the bytes of every regular file."""
    digest = hashlib.sha256()
    for folder, dirs, names in os.walk(path):
        dirs.sort()
        for name in sorted(dirs + names):
            item = Path(folder) / name
            s = item.lstat()
            entry = [str(item.relative_to(path)), s.st_mode]
            if stat.S_ISREG(s.st_mode):
                entry.append(sha(item))
            elif stat.S_ISLNK(s.st_mode):
                require(path in item.resolve(strict=True).parents, "Bundle symlink leaves root")
                entry.append(os.readlink(item))
            else:
                require(stat.S_ISDIR(s.st_mode), "Bundle contains a special file")
            digest.update(json.dumps(entry, ensure_ascii=True).encode() + b"\n")
    return digest.hexdigest()


def bundle(path, expected):
    require(path == path.resolve(strict=True) and path.is_dir(), "Unexpected bundle path")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    require(tuple(info.get(k) for k in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                                        "CFBundleVersion", "NearpaneSourceState", "NearpaneSourceRevision"))
            == ("com.holdsnow.nearpane.alpha", "NearpaneHost", "5.22", "90", "clean", expected["source"]),
            "Signed source/version/build differs from admitted 5.22 (90)")
    gate.verify_install_identity(path)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--all-architectures", str(path)],
                   capture_output=True, check=True, timeout=60)
    stamp = identity(path)
    require(stamp["TeamIdentifier"] == gate.PRODUCT_SIGNING_TEAM and stamp["CDHash"] == expected["cdhash"],
            "Host signature does not match admitted CDHash/team")
    return dict(expected, version="5.22", build="90", tree=public_tree(path), root=inode(path), host=inode(path/HOST))


def expect_pair(previous, incoming):
    for item in (previous, incoming):
        require(all(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value)
                    for value in (item["source"], item["cdhash"])), "Expected full lowercase source SHA and CDHash")
    require(previous["source"] != incoming["source"] and previous["cdhash"] != incoming["cdhash"], "Identical revisions or signatures")


def apfs(path):
    device = subprocess.check_output(["/bin/df", "-P", str(path)], text=True).splitlines()[-1].split()[0]
    require(device.startswith("/dev/"), "Cannot verify APFS device")
    metadata = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", device], timeout=10))
    require(metadata.get("FilesystemType", "").lower() == "apfs", "Atomic installation session requires APFS")


def process_stamp(pid):
    # Darwin PROC_PIDTBSDINFO from sys/proc_info.h. Reject partial kernel reads or PID reuse.
    class BSDInfo(ctypes.Structure):
        _fields_ = [("head", ctypes.c_uint32 * 12), ("command", ctypes.c_char * 48),
                    ("group", ctypes.c_uint32 * 6), ("sec", ctypes.c_uint64), ("usec", ctypes.c_uint64)]
    record = BSDInfo()
    size = ctypes.sizeof(record)
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    count = proc.proc_pidinfo(pid, 3, 0, ctypes.byref(record), size)
    require(count == size and record.head[3] == pid and record.head[5] == os.getuid() and record.sec,
            "Cannot confirm exact process generation")
    return [pid, record.sec, record.usec]


def lock_fd(path):
    require(path == path.resolve(strict=True), "Symlinked profile lock")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    s = os.fstat(fd)
    if (not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid()
            or inode(path) != [s.st_dev, s.st_ino]):
        os.close(fd)
        raise ValueError("Untrusted profile lock")
    return fd


def holders(path):
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", str(path)], capture_output=True, text=True, timeout=8)
    lines = result.stdout.splitlines()
    require(result.returncode in (0, 1) and not result.stderr.strip() and all(x.isdecimal() for x in lines)
            and (result.returncode == 0) == bool(lines), "Cannot determine profile lock owners")
    return {int(x) for x in lines}


def owner(pid, lock):
    if not pid or not lock.is_file() or holders(lock) != {pid}:
        return False
    fd = lock_fd(lock)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(fd)


@contextmanager
def free_lock(path, create=False):
    if create:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        s = os.fstat(fd)
        require(stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid() and s.st_nlink == 1
                and not s.st_mode & 0o077, "Untrusted transaction lock")
    else:
        fd = lock_fd(path)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
    finally:
        os.close(fd)


class Mac:
    canonical = profile.APP
    daily = Path.home() / profile.PROFILE
    root = ROOT

    def new_home(self):
        base = Path(tempfile.mkdtemp(prefix="nearpane-native-acceptance.", dir=profile.CACHES))
        home = base / "home"
        profile.validate_home(home)
        return home

    def verify_home(self, home):
        # Recovery may only use a pre-existing private acceptance home.
        owned_dir(home.parent)
        owned_dir(home)
        profile.validate_home(home)

    def inspect(self, path, expected):
        return bundle(path, expected)

    def stage(self, source, slot):
        apfs(self.canonical.parent)
        subprocess.run(["/usr/bin/ditto", "--rsrc", "--extattr", str(source), str(slot)], check=True, timeout=180)

    def config(self):
        value = profile.daily_state()
        require(value is not None, "Cannot bind the existing daily configuration")
        return value

    def pid(self):
        return profile.installed_pid()

    def bound(self, pid, root, expected):
        if self.pid() != pid or not pid:
            raise ValueError("Installed Host changed")
        before = process_stamp(pid)
        require(inode(self.canonical/HOST) == expected["host"], "Different Host executable inode")
        row = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-t",
                              str(self.canonical/HOST)], capture_output=True, timeout=8, text=True)
        require(row.returncode == 0 and row.stdout.strip() == str(pid) and owner(pid, root/LOCK_FILE)
                and process_stamp(pid) == before and self.pid() == pid, "Host executable/generation or exclusive profile ownership differs")
        self.last_binding = before,root,expected
        return before

    def quit(self, stamp):
        before,root,expected = self.last_binding
        require(before == stamp and self.bound(stamp[0],root,expected) == stamp, "Host generation changed before quit")
        subprocess.run(["/usr/bin/swift",HERE/"private-installed-quit.swift",*(str(item) for item in stamp),
                        expected["cdhash"]],check=True,capture_output=True,timeout=30)
        deadline = time.monotonic()+20
        while self.pid() == stamp[0] and time.monotonic() < deadline:
            time.sleep(.15)
        require(self.pid() is None,"Normal quit did not produce an empty installed Host slot")

    def wait_stopped(self, paths):
        deadline = time.monotonic() + 15
        while True:
            require(self.pid() is None, "Unexpected live installed Host")
            try:
                publisher.require_stopped(*paths)
                return
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.2)

    def clear(self, lock, allowed):
        if lock.exists():
            require(holders(lock) == allowed, "An unexpected process holds a profile file")
        else:
            require(not allowed and not lock.is_symlink(), "Expected profile lock is missing")

    def isolated(self, home):
        return profile.launch_isolated(home)

    def open_daily(self):
        require(not any(k in os.environ for k in ("CFFIXED_USER_HOME", "NEARPANE_TEST_HOME", "NEARPANE_TEST_GENERATION",
                                                    "NEARPANE_PREVIEW_DIAGNOSTICS", "NEARPANE_ACCEPTANCE_SESSION")),
                "Run the supervisor outside an acceptance environment")
        subprocess.run(["/usr/bin/open", "-g", str(self.canonical)], check=True, timeout=8)

    def wait_launch_resolution(self, root):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            pid = self.pid()
            if pid and profile.owns_profile(pid, root):
                return pid
            time.sleep(.2)
        return self.pid()

    def wait_owner(self, root, expected):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            pid = self.pid()
            if pid and profile.owns_profile(pid, root):
                return self.bound(pid, root, expected)
            time.sleep(.2)
        raise RuntimeError("Expected normal Host launch did not acquire its profile lock")

    def verify_generation(self, home, generation):
        root = home/profile.PROFILE
        active = json.loads((root/"profile-index.json").read_bytes())["active"]
        require(active == str(uuid.UUID(active)) and generation == root/"generations"/active
                and generation == generation.resolve(strict=True), "Isolated profile generation changed")

    def permissions(self, stamp, root, expected, metrics):
        require(self.bound(stamp[0],root,expected)==stamp,"Host changed before permission sampling")
        subprocess.run(["/usr/bin/codesign","--verify","--strict",metrics],check=True,capture_output=True,timeout=8)
        facts=host_current_permissions({"pid":stamp[0],"launch":stamp[1]+stamp[2]/1_000_000},metrics)
        require(self.bound(stamp[0],root,expected)==stamp,"Host changed during permission sampling")
        if not facts or not all(isinstance(facts.get(k),bool) for k in ("screen","accessibility","postEvent")):
            return dict(status="UNKNOWN",reason="No unique nonce-matched installed Host response")
        return dict(status="OBSERVED",**facts)

    def pre_visit_shortcut(self, rec, shortcut):
        # Stage ownership and a global reservation can be measured before visiting any Space.
        sample = {"status": "UNKNOWN", "scope": "pre-visit Stage Manager", "keyEventsSent": 0}
        try:
            kit = Path(shortcut)
            require(kit == kit.resolve(strict=True) and kit.parent == Path("/private/tmp")
                    and kit.name.startswith("nearpane-overview-chord.") and kit.stat().st_uid == os.getuid()
                    and not kit.stat().st_mode & 0o077, "Unqualified overview shortcut kit")
            for tool in ("metrics", "overview-shortcut-claim"):
                rule = f'anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB" and identifier "com.holdsnow.nearpane.acceptance.{tool}"'
                subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R="+rule, kit/tool],
                               check=True, capture_output=True, timeout=6)
            stage_kit = Path(rec["focusLease"]["stageKit"])
            preview = importlib.import_module("preview-workspace")
            read_login = lambda: preview.states(stage_kit)
            if read_login()[-1]["state"] is True:
                stamp = rec["isolatedHost"]
                hardware = lambda: subprocess.check_output([stage_kit/"system-workspace", "hid"], timeout=5)
                initial = hardware()
                def bound():
                    return (self.bound(stamp[0], Path(rec["home"])/profile.PROFILE, rec["candidate"]) == stamp
                            and hardware() == initial)
                sample.update(preview.sample_overview_shortcut(kit, True, stamp[0], bound, read_login))
            else:
                sample.update(status="NOT_RUN", reason="StageManagerAlreadyOff")
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as exc:
            sample["reason"] = "preVisitReadUnavailable:" + type(exc).__name__
        return sample

    def trial(self, name, rec, context, leases):
        out = Path(rec["output"])
        source = rec["candidate"]["source"]
        chain = None
        if name in ("P0-diagnostic","P2") and "focusLease" in rec:
            original = self.canonical.parent/(".nearpane-installed-trials." + str(os.getuid()))/rec["transaction"]/"bundle.slot"
            chain = spaces_trials.extend_focus_chain(rec, self.canonical, original, out, gate, persist)
        if name == "P2" and chain is not None and context.get("NP_OVERVIEW_SHORTCUT_KIT"):
            persist(out/"pre-visit-stage-shortcut.json", self.pre_visit_shortcut(rec, context["NP_OVERVIEW_SHORTCUT_KIT"]))
        if name == "P2":
            context = dict(context)
            context.pop("NP_P2_FOCUS_SCOPE_PREFLIGHT", None)
            if rec.get("focusScopePreflight") is True:
                require(rec.get("focusScenario") in ("pair-focus","pair-pointer","pair-drag"),
                        "Scope probe belongs to the same-application pair")
                context["NP_P2_FOCUS_SCOPE_PREFLIGHT"] = "1"
            cmd = spaces_trials.focus_command(HERE, rec, out, chain, context)
            result = out/"p2/result.json"
        elif name == "P0-diagnostic":
            cmd = spaces_trials.diagnostic_command(HERE, rec, out, chain)
            result = out/"p0/results.json"
        elif name == "P3":
            result = out/"p3.json"
            cmd = [sys.executable, HERE/"p3-installed-qualification.py", "--expected-source", source,
                   "--output", result, "--metrics", rec["metrics"], "--sessions", rec["sessions"]]
        elif name == "P4":
            result = out/"p4/result.json"
            cmd = [sys.executable, HERE/"p4-service-cycle.py", rec["kit"], out/"p4", "--expected-source", source]
        else:
            result = out/"p4-wordbook/result.json"
            cmd = [sys.executable, rec["wordbookDriver"], rec["wordbookKit"], out/"p4-wordbook", "--expected-source", source]
        # Descendants cannot outlive a killed supervisor and race a recovery while this child still drives the Host.
        with open(out/(name.lower()+".log"), "xb") as log:
            child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=context,
                                     start_new_session=True, pass_fds=leases)
            # These acceptance programs independently bound each external operation. On SIGTERM let their
            # current operation and fixture cleanup finish; the supervisor will skip the next trial and restore.
            code = child.wait(timeout=900 if name == "P0-diagnostic" else 300)
        if result.is_file() and result.resolve() == result:
            record = read_json(result)
            if name == "P0-diagnostic":
                require(record.get("scope") == "DIAGNOSTIC_ONLY" and record.get("officialGateEligible") is False,
                        "Single-run diagnostic did not preserve its evidence scope")
                outcome = record.get("diagnosticOutcome", "UNKNOWN")
                require(outcome in {"PASS","FAIL","UNKNOWN","BLOCKED","NOT_RUN"}, "Unrecognized diagnostic outcome")
                return dict(status=outcome, scope="DIAGNOSTIC_ONLY", officialGateEligible=False,
                            exit=code, receipt=result.relative_to(out).as_posix(), sha256=sha(result))
            return dict(status=record["status"], exit=code, receipt=result.relative_to(out).as_posix(), sha256=sha(result))
        return dict(status="UNKNOWN", exit=code, reason="missingTrialReceipt")


class Transaction:
    def __init__(self, mac, receipt):
        self.mac, self.rec = mac, receipt
        self.id = str(uuid.UUID(receipt["transaction"]))
        require(self.id == receipt["transaction"], "Invalid transaction ID")
        self.app = mac.canonical
        self.slot_parent = self.app.parent/(".nearpane-installed-trials." + str(os.getuid()))/self.id
        self.slot = self.slot_parent/"bundle.slot"
        self.home = Path(receipt["home"])
        self.out = Path(receipt["output"])
        self.record = mac.root/"active.json"
        self.guards = ExitStack()
        self.daily_reserved = False
        self.daily_lock = mac.daily/LOCK_FILE
        self.test_root = self.home/profile.PROFILE
        self.test_lock = self.test_root/LOCK_FILE
        self.wordbook_home = Path(receipt["wordbookHome"]) if receipt.get("wordbookHome") else None

    def test_roots(self):
        return [home/profile.PROFILE for home in (self.home,self.wordbook_home) if home is not None]

    def clear_isolated(self, except_root=None):
        for root in self.test_roots():
            if root != except_root:
                self.mac.clear(root/LOCK_FILE,set())

    def isolated_owner(self, pid):
        matches = []
        for root in self.test_roots():
            try:
                matches.append((root,self.mac.bound(pid,root,self.rec["candidate"])))
            except (ValueError,RuntimeError,subprocess.SubprocessError):
                continue
        require(len(matches) == 1,"Candidate does not exclusively own a registered isolated profile")
        root,stamp = matches[0]
        self.clear_isolated(except_root=root)
        return stamp

    def save(self, stage, **facts):
        self.rec.update(facts)
        self.rec["stage"] = stage
        self.rec["events"].append(dict(stage=stage, utc=datetime.now(timezone.utc).isoformat(), uptime=time.monotonic()))
        # The private journal is authoritative even if the independent evidence volume disappears.
        mirror = self.out.is_dir() and self.out == self.out.resolve() and inode(self.out) == self.rec["outputIdentity"]
        self.rec["outputMirror"] = "AVAILABLE" if mirror else "UNAVAILABLE"
        persist(self.record,self.rec)
        if mirror:
            try:
                owned_dir(self.out)
                persist(self.out/"installation.json",self.rec)
            except (ValueError,OSError):
                self.rec["outputMirror"] = "UNAVAILABLE"
                persist(self.record,self.rec)

    def check_context(self, require_output=True):
        owned_dir(self.slot_parent.parent)
        owned_dir(self.slot_parent)
        if require_output:
            owned_dir(self.out)
            require(inode(self.out) == self.rec["outputIdentity"],"Independent evidence directory changed")
        self.mac.verify_home(self.home)
        if self.wordbook_home:
            self.mac.verify_home(self.wordbook_home)
            require(self.wordbook_home != self.home and inode(self.wordbook_home) == self.rec["wordbookHomeIdentity"],
                    "Second registered isolated home identity changed")
        require(self.rec["schema"] == 1 and inode(self.daily_lock) == self.rec["dailyLock"]
                and self.mac.config() == self.rec["dailyConfiguration"]
                and inode(self.slot_parent) == self.rec["slotParent"]
                and inode(self.home) == self.rec["homeIdentity"], "Journal paths, daily generation or config changed")
        expect_pair(self.rec["original"], self.rec["candidate"])

    def orientation(self):
        old, new = self.rec["original"], self.rec["candidate"]
        observed = [inode(self.app), inode(self.slot)]
        if observed == [old["root"], new["root"]]:
            a, b, side = old, new, "original"
        elif observed == [new["root"], old["root"]]:
            a, b, side = new, old, "candidate"
        else:
            raise RuntimeError("Unknown bundle identity or exchange arrangement; preserving both entries")
        for at, expected in ((self.app, a), (self.slot, b)):
            pin = {k:expected[k] for k in ("source","cdhash")}
            require(self.mac.inspect(at,pin) == expected, "Admitted bundle bytes, inode or signature changed")
        return side

    def exchange(self, source_side):
        require(self.orientation() == source_side, "Refusing an unexpected exchange direction")
        self.mac.wait_stopped([self.app, self.slot])
        self.mac.clear(self.daily_lock, {os.getpid()})
        self.clear_isolated()
        require(inode(self.daily_lock) == self.rec["dailyLock"] and self.mac.config() == self.rec["dailyConfiguration"],
                "Daily configuration changed before bundle exchange")
        # Both paths are pre-existing entries on one APFS device. No copy, deletion or fallback during exchange.
        publisher.rename(self.app, self.slot, 2)
        fsync_dir(self.app.parent)
        fsync_dir(self.slot_parent)
        require(self.orientation() != source_side, "Bundle exchange could not be verified")

    @contextmanager
    def guarded_daily(self):
        require(inode(self.daily_lock) == self.rec["dailyLock"], "Daily lock was replaced")
        if not self.daily_reserved:
            self.daily_fd = self.guards.enter_context(free_lock(self.daily_lock))
            self.daily_reserved = True
        self.mac.clear(self.daily_lock,{os.getpid()})
        # The FD stays held across trial exit, errors and the reverse exchange.
        yield

    def release_daily(self):
        self.guards.close()
        self.daily_reserved = False

    def forward(self, cancelled):
        self.check_context()
        require(self.orientation() == "original", "Candidate is already installed")
        self.clear_isolated()
        stamp = self.mac.bound(self.mac.pid(), self.mac.daily, self.rec["original"])
        require(stamp == self.rec["initialDailyHost"], "Enrolled daily Host generation changed")
        if cancelled():
            return
        self.save("quitting-original")
        self.mac.quit(stamp)
        with self.guarded_daily():
            if cancelled():
                return
            self.save("swapping-to-candidate")
            self.exchange("original")
            if cancelled():
                return
            home = self.home
            generation = self.start_home(home)
            if self.rec.get("trialScope") in ("p4-service","p3,p4","p2,p4-service"):
                stamp=self.mac.bound(self.mac.pid(),home/profile.PROFILE,self.rec["candidate"])
                perms=dict(status="UNKNOWN",pid=stamp[0],birth=stamp[1]*1_000_000+stamp[2],
                           sourceRevision=self.rec["candidate"]["source"],cdhash=self.rec["candidate"]["cdhash"],
                           generation=generation.name,method="installed Host nonce-bound nonprompting preflight")
                self.save("sampling-installed-host-permissions")
                try:
                    perms.update(self.mac.permissions(stamp,home/profile.PROFILE,self.rec["candidate"],self.rec["metrics"]))
                except (ValueError,OSError,RuntimeError,subprocess.SubprocessError) as error:
                    perms["reason"]=type(error).__name__+": "+str(error)[:180]
                self.rec["hostPermissions"]=perms
                persist(self.out/"host-permissions.json",perms)
                self.save("sampled-installed-host-permissions")
            for name in self.rec["trials"]:
                if cancelled():
                    break
                if name == "P4-wordbook":
                    if not self.wordbook_home:
                        continue
                    stamp = self.isolated_owner(self.mac.pid())
                    self.save("quitting-first-isolated-for-wordbook",firstIsolatedExit=stamp)
                    self.mac.quit(stamp)
                    self.clear_isolated()
                    if cancelled():
                        break
                    home = self.wordbook_home
                    generation = self.start_home(home)
                self.mac.bound(self.mac.pid(),home/profile.PROFILE,self.rec["candidate"])
                self.mac.verify_generation(home,generation)
                self.mac.clear(self.daily_lock,{os.getpid()})
                self.clear_isolated(except_root=home/profile.PROFILE)
                self.check_context()
                context = dict(os.environ, NEARPANE_TEST_HOME=str(home), NEARPANE_TEST_GENERATION=str(generation),
                               NEARPANE_ACCEPTANCE_CHECKOUT=str(HERE.parents[2]))
                self.rec["trials"][name] = dict(status="UNKNOWN", reason="startedWithoutFinalReceipt")
                self.save("running-"+name)
                with free_lock(self.slot_parent/"trial.lock", create=True) as guard:
                    try:
                        leases = (guard,self.daily_fd,self.mac.publisher_fd)
                        result = self.mac.trial(name,self.rec,context,leases)
                    except subprocess.TimeoutExpired:
                        # The direct child continues to hold all leases. Do not dispatch another trial.
                        self.rec["trials"][name] = dict(status="UNKNOWN",reason="trialStillHoldsLease")
                        self.save("trial-timeout-"+name)
                        raise
                    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as err:
                        result = dict(status="UNKNOWN",reason=type(err).__name__+": "+str(err)[:240])
                self.rec["trials"][name] = result
                self.save("finished-"+name)
                self.mac.bound(self.mac.pid(),home/profile.PROFILE,self.rec["candidate"])
                self.mac.verify_generation(home,generation)

    def start_home(self,home):
        self.save("launching-isolated",pendingIsolatedHome=str(home))
        pid,generation = self.mac.isolated(home)
        stamp = self.mac.bound(pid,home/profile.PROFILE,self.rec["candidate"])
        self.mac.verify_generation(home,generation)
        key = "isolatedHost" if home == self.home else "wordbookHost"
        self.save("isolated-running",pendingIsolatedHome=None,**{key:stamp,key+"Generation":str(generation)})
        return generation

    def restore(self):
        self.check_context(require_output=False)
        with free_lock(self.slot_parent/"trial.lock",create=True):
            side = self.orientation()
            if side == "candidate":
                with self.guarded_daily():
                    self.mac.clear(self.daily_lock,{os.getpid()})
                    pid = self.mac.pid()
                    if pid is None and self.rec.get("pendingIsolatedHome"):
                        root = Path(self.rec["pendingIsolatedHome"])/profile.PROFILE
                        require(root in self.test_roots(),"Unknown pending isolated launch")
                        pid = self.mac.wait_launch_resolution(root)
                    if pid is not None:
                        stamp = self.isolated_owner(pid)
                        self.save("quitting-isolated",lastIsolatedHost=stamp)
                        self.mac.quit(stamp)
                    self.save("restoring-original-bundle")
                    self.exchange("candidate")
            self.clear_isolated()
            pid = self.mac.pid()
            if pid is None:
                with self.guarded_daily():
                    self.mac.clear(self.daily_lock,{os.getpid()})
                    self.check_context(require_output=False)
                    self.mac.wait_stopped([self.app,self.slot])
                    require(inode(self.app) == self.rec["original"]["root"], "Original bundle moved before daily launch")
                self.release_daily()
                if self.rec.get("dailyLaunchIntended"):
                    # Reconcile an accepted open or a crash just before open. The original bundle
                    # prohibits multiple instances. This recovery only launches its ordinary profile.
                    pid = self.mac.wait_launch_resolution(self.mac.daily)
                if pid is None:
                    self.mac.clear(self.daily_lock,set())
                    self.clear_isolated()
                    self.save("launching-original",dailyLaunchIntended=True)
                    self.mac.open_daily()
                restored = self.mac.wait_owner(self.mac.daily,self.rec["original"])
            else:
                restored = self.mac.bound(pid,self.mac.daily,self.rec["original"])
            self.check_context(require_output=False)
            require(self.orientation() == "original", "Cannot prove exact original bundle restoration")
            require(self.mac.bound(restored[0],self.mac.daily,self.rec["original"]) == restored,
                    "Restored daily Host or lock generation changed")
            self.save("restored",restoration="PASS",restoredDailyHost=restored,cleanup="PENDING")
            # The daily app is already restored. Only discard data created for this transaction.
            try:
                self.clear_isolated()
                retired = self.slot_parent/"tested-candidate.retired"
                require(inode(self.app) == self.rec["original"]["root"] and inode(self.slot) == self.rec["candidate"]["root"],
                        "Candidate staging identity changed at cleanup")
                publisher.rename(self.slot,retired,4)
                require(inode(retired) == self.rec["candidate"]["root"],"Retired copy identity changed")
                shutil.rmtree(retired)
                for home in (self.home,self.wordbook_home):
                    if home is None:
                        continue
                    self.mac.verify_home(home)
                    expected = self.rec["homeIdentity"] if home == self.home else self.rec["wordbookHomeIdentity"]
                    require(inode(home) == expected,"Private test home changed before cleanup")
                    shutil.rmtree(home)
                    if not any(home.parent.iterdir()):
                        home.parent.rmdir()
                self.save("restored",cleanup="PASS")
            except (ValueError,OSError,RuntimeError,subprocess.SubprocessError) as err:
                self.save("restored",cleanup="UNKNOWN",cleanupError=type(err).__name__+": "+str(err)[:240])
            persist(self.mac.root/(self.id+".json"),self.rec)

    @classmethod
    def prepare(cls, mac, args):
        previous = dict(source=args.original_source,cdhash=args.original_cdhash)
        incoming = dict(source=args.candidate_source,cdhash=args.candidate_cdhash)
        expect_pair(previous,incoming)
        source = args.candidate.resolve(strict=True)
        output = args.output.absolute()
        require(output.parent == output.parent.resolve(strict=True) and source.name == "Nearpane.app"
                and source != mac.canonical and mac.canonical not in source.parents,
                "Expected an independent candidate and a fresh output under an existing parent")
        for protected in (mac.canonical, mac.daily, source, mac.root, mac.canonical.parent):
            require(output != protected and protected not in output.parents,
                    "Acceptance output cannot be inside the bundle, installation or profile directories")
        require(not any(k in os.environ for k in ("CFFIXED_USER_HOME","NEARPANE_TEST_HOME","NEARPANE_TEST_GENERATION",
                                                   "NEARPANE_PREVIEW_DIAGNOSTICS","NEARPANE_ACCEPTANCE_SESSION")),
                "Run the supervisor outside an acceptance environment")
        only=getattr(args,"only",None)
        focus_mode = getattr(args, "focus_scenario", "controlled-window")
        require(focus_mode == "controlled-window" or args.only == "p2", "Pointer scenarios require --only p2")
        require(not getattr(args, "pair_kit", None) or focus_mode in ("pair-focus", "pair-pointer", "pair-drag", "pair-cross"), "Select a pointer scenario for --pair-kit")
        choices = {"p0-diagnostic":("P0-diagnostic",), "p2":("P2",), "p4-service":("P4",), "p2,p4-service":("P2","P4"),
                   "p3,p4":("P3","P4"), None:("P3","P4","P4-wordbook")}
        require(only in choices and not (only and args.wordbook_driver), "Invalid protected trial selection")
        inputs = {}
        if getattr(args, "focus_scope_preflight", False):
            require(only == "p2" and focus_mode in ("pair-focus","pair-pointer","pair-drag"),
                    "Focus scope preflight requires a same-application registered pair scenario")
            inputs["focusScopePreflight"] = True
        if only == "p0-diagnostic":
            require((HERE/"p0-host-diagnostic.py").is_file() and args.issuer_key and args.issuer_key.is_file()
                    and (args.kit/"system-workspace").is_file(), "Missing single-run diagnostic kit or issuer")
            inputs["issuerKey"] = str(args.issuer_key.resolve(strict=True))
            if args.drift_kit:
                inputs["driftKit"] = str(args.drift_kit.resolve(strict=True))
            if args.focus_lease:
                lease = spaces_trials.focus_lease(args.focus_lease.resolve(strict=True))
                stage_kit = Path(lease["stageKit"])
                require(stage_kit == stage_kit.resolve(strict=True) and (stage_kit/"preview-stage-control").is_file(),
                        "The enrolled desktop lacks its Stage Manager verification kit")
                inputs["focusLease"] = lease
        elif only == "p2":
            require(args.focus_lease and (args.kit/"system-workspace").is_file(), "Missing focus kit or enrolled Space lease")
            inputs["focusLease"] = spaces_trials.focus_lease(args.focus_lease.resolve(strict=True))
            if getattr(args, "focus_scenario", "controlled-window") != "controlled-window":
                from p2_documents import static_part
                require(args.pair_kit, "The pointer scenario requires its signed registered-documents kit")
                pair_kit = args.pair_kit.resolve(strict=True)
                require(pair_kit == args.pair_kit and pair_kit.parent == Path("/private/tmp") and
                        pair_kit.name.startswith("nearpane-d01.") and not pair_kit.stat().st_mode & 0o077 and
                        pair_kit.stat().st_uid == os.getuid(), "Unqualified pointer kit")
                if focus_mode == "pair-cross":
                    from cross_app_pair import signed_kit
                    signed_kit(pair_kit)
                else:
                    static_part(pair_kit/"observe", "net.example.nearpane.p2-observer")
                    static_part(pair_kit/"Field Notes.app", "net.example.spaces-document")
                inputs.update(focusScenario=args.focus_scenario, pairKit=str(pair_kit))
        else:
            require(args.metrics and args.metrics.is_file() and os.access(args.metrics,os.X_OK) and
                    (args.kit/"tool-selection").is_file() and (args.kit/"Nearpane Tool Fixture.app").is_dir(),
                    "Missing P3/P4 tools")
            inputs["metrics"] = str(args.metrics.resolve(strict=True))
            if only == "p2,p4-service":
                require(args.focus_lease, "Missing enrolled ordinary desktop")
                lease = spaces_trials.focus_lease(args.focus_lease.resolve(strict=True))
                stage_kit = Path(lease["stageKit"])
                require(stage_kit == stage_kit.resolve(strict=True) and (stage_kit/"system-workspace").is_file(),
                        "Missing enrolled focus kit")
                inputs["focusLease"] = lease
        require(bool(args.wordbook_driver) == bool(args.wordbook_kit), "Supply both independent wordbook inputs")
        if args.wordbook_driver:
            require(args.wordbook_driver.name == "p4-wordbook-recovery.py" and args.wordbook_driver.is_file()
                    and args.wordbook_kit.is_dir(), "Missing independent wordbook driver or kit")
        # Finish all source/signature preflight and staging while the known original stays running.
        old = mac.inspect(mac.canonical,previous)
        fresh = mac.inspect(source,incoming)
        baseline = mac.config()
        original_pid = mac.bound(mac.pid(),mac.daily,old)
        output.mkdir(mode=0o700)
        owned_dir(output)
        home = mac.new_home()
        chosen_trials=choices[only]
        tx = cls(mac,dict(schema=1,transaction=str(uuid.uuid4()),home=str(home),output=str(output),
                          kit=str(args.kit.resolve(strict=True)),**inputs,
                          sessions=str(args.sessions.resolve()),restoration="PENDING",trialScope=only or "all",
                          trials={k:dict(status="NOT_RUN") for k in chosen_trials},events=[]))
        if args.wordbook_driver:
            tx.wordbook_home = mac.new_home()
            tx.rec.update(wordbookHome=str(tx.wordbook_home), wordbookHomeIdentity=inode(tx.wordbook_home),
                          wordbookDriver=str(args.wordbook_driver.resolve(strict=True)),
                          wordbookKit=str(args.wordbook_kit.resolve(strict=True)))
        elif not only:
            tx.rec["trials"]["P4-wordbook"]["reason"] = "optionalDriverUnavailable"
        owned_dir(tx.slot_parent.parent,create=True)
        tx.slot_parent.mkdir(mode=0o700)
        owned_dir(tx.slot_parent)
        require(inode(tx.app)[0] == inode(tx.slot_parent)[0], "Candidate slot is not on the installed app volume")
        mac.stage(source,tx.slot)
        staged = mac.inspect(tx.slot,incoming)
        require(fresh["tree"] == staged["tree"] and old["root"] != staged["root"] and old["host"] != staged["host"],
                "Candidate copy does not match signed source/original identities")
        tx.rec.update(original=old,candidate=staged,dailyLock=inode(tx.daily_lock),dailyConfiguration=baseline,
                      initialDailyHost=original_pid,slotParent=inode(tx.slot_parent),outputIdentity=inode(output),homeIdentity=inode(home))
        tx.check_context()
        tx.save("enrolled")
        return tx


@contextmanager
def session_lock(mac):
    owned_dir(mac.root,create=True)
    with free_lock(mac.root/"supervisor.lock",create=True):
        # The existing distribution publisher serializes on this exact directory inode.
        fd = os.open(mac.canonical.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            mac.publisher_fd = fd
            yield
        finally:
            os.close(fd)


def supervise(mac, args, cancelled):
    active = mac.root/"active.json"
    if args.action == "status":
        if mac.root.exists():
            owned_dir(mac.root)
        return read_json(active) if active.exists() else dict(stage="none")
    with session_lock(mac):
        last = read_json(active) if active.exists() else None
        if args.action == "run":
            require(not last or last.get("restoration") == "PASS", "An installation session still needs recovery")
            tx = Transaction.prepare(mac,args)
            try:
                tx.forward(cancelled)
            except Exception as err:
                tx.rec["operationError"] = type(err).__name__+": "+str(err)[:240]
            finally:
                tx.rec["terminationSignal"] = cancelled() or None
                try:
                    recover(tx)
                finally:
                    tx.release_daily()
        else:
            require(last is not None,"No enrolled transaction")
            if last.get("restoration") == "PASS":
                return last
            tx = Transaction(mac,last)
            try:
                recover(tx)
            finally:
                tx.release_daily()
        return tx.rec


def recover(tx):
    try:
        tx.restore()
    except Exception as err:
        tx.rec["recoveryError"] = type(err).__name__+": "+str(err)[:240]
        durable = read_json(tx.record)
        if durable.get("restoration") == "PASS":
            tx.save("restored",restoration="PASS",postRestoreError=tx.rec["recoveryError"])
            return
        tx.save("recovery-withheld",restoration="UNKNOWN")
        raise


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action",required=True)
    run = commands.add_parser("run")
    run.add_argument("candidate",type=Path)
    for subject in ("original","candidate"):
        for field in ("source","cdhash"):
            run.add_argument("--"+subject+"-"+field,required=True)
    run.add_argument("--output",required=True,type=Path)
    run.add_argument("--metrics",type=Path)
    run.add_argument("--kit",required=True,type=Path)
    run.add_argument("--sessions",type=Path,default=HERE.parents[2]/"build/native-acceptance")
    run.add_argument("--only",type=str.lower,choices=("p4-service","p3,p4","p2","p0-diagnostic","p2,p4-service"))
    run.add_argument("--focus-scenario", choices=("controlled-window", "pair-focus", "pair-pointer", "pair-drag", "pair-cross"), default="controlled-window",
                     help="with --only p2, measure pointer selection alone or selection plus three actual card drags")
    run.add_argument("--focus-scope-preflight", action="store_true",
                     help="require read-only installed Host scope evidence for both registered same-app documents before any pointer action")
    run.add_argument("--pair-kit", type=Path, help="signed --pair-pointer kit, leaving the enrolled lease immutable")
    run.add_argument("--focus-lease",type=Path, help="owned lease and archive chain for a registered two-document test")
    run.add_argument("--issuer-key",type=Path, help="one-run issuer for the separately compiled isolated diagnostic")
    run.add_argument("--drift-kit",type=Path)
    run.add_argument("--wordbook-driver",type=Path)
    run.add_argument("--wordbook-kit",type=Path)
    commands.add_parser("recover")
    commands.add_parser("status")
    args = parser.parse_args()
    caught = []
    def stop(number, frame):
        if not caught:
            caught.append(number)
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):
        signal.signal(sig,stop)
    try:
        report = supervise(Mac(),args,lambda: caught[0] if caught else 0)
        print(json.dumps({k:report.get(k) for k in ("transaction","stage","restoration","cleanup","trials","hostPermissions","operationError","output")},
                         ensure_ascii=False,indent=2))
        missing_permissions = report.get("trialScope") in ("p4-service","p3,p4","p2,p4-service") and report.get("hostPermissions",{}).get("status") != "OBSERVED"
        if args.action == "run" and (missing_permissions or any(x["status"] != "PASS" for x in report["trials"].values())):
            return 128+caught[0] if caught else 2
        return 128+caught[0] if caught else 0
    except (KeyError,ValueError,OSError,RuntimeError,subprocess.SubprocessError) as err:
        print(type(err).__name__+": "+str(err)+"\nTransaction journal: "+str(ROOT/"active.json"),file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
