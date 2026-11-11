#!/usr/bin/env python3
"""Host-owned event loop for the single admitted, signed secondary-display application."""
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import uuid

APP_ID = "org.nearpane.lab.NearpaneFixtureWindows"


def read(path):
    return json.loads(path.read_bytes())


def save(path, value):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temp:
        json.dump(value, temp, sort_keys=True)
        temp.flush()
        os.fsync(temp.fileno())
    os.replace(temp.name, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def require(value, reason):
    if not value:
        raise ValueError(reason)


def allowed(member, policy):
    rules = policy.get("windows", [])
    identity = member["id"]
    for target, rule in zip(rules[::2], rules[1::2]):
        if target == identity:
            return rule == "include"
    for target, rule in zip(rules[::2], rules[1::2]):
        if rule == "exclude" and all(target[k] == identity[k] for k in ("pid", "launch", "number")):
            raise ValueError("已排除窗口的身份发生变化")
    return APP_ID not in policy.get("excludedApps", [])


def plan_key(owner, config, display):
    settings = config.get("displays", {}).get(display, {})
    measures = settings.get("measures", [])
    if isinstance(measures, list):
        measures = dict(zip(measures[::2], measures[1::2]))
    policy = config.get("workspaces", {})
    pairs = [(m, f) for m, f in zip(owner["members"], owner["frames"]) if allowed(m, policy)]
    return (owner["owner"], owner["revision"], pairs, display == config.get("preferredDisplayID"),
            settings.get("edge") or config["edge"], settings.get("placement"),
            measures.get("reservedWidth", measures.get("panelWidth")))


class Manager:
    def __init__(self, profile, bundle):
        require(profile.resolve() == profile and (profile / "profile.version").read_text() == "Nearpane P4.7\n",
                "无法核对 P4.7 隔离资料")
        self.root = profile / "WorkRect"
        self.root.mkdir(mode=0o700, exist_ok=True)
        require(self.root.resolve() == self.root and self.root.stat().st_uid == os.getuid()
                and self.root.stat().st_mode & 0o077 == 0, "管理目录权限不安全")
        self.lease = (self.root / "manager.lock").open("a")
        try:
            fcntl.flock(self.lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lease.close()
            raise ValueError("另一个 Host 正在管理此资料，请等待其安全退出")
        self.config = profile / "Nearpane/host-configuration.json"
        self.apps = bundle / "Helpers"
        self.settings = self.root / "management.json"
        self.prefs = read(self.settings) if self.settings.exists() else dict(mode="off", ratio=.5, swap=False)
        self.mode = self.prefs["mode"]
        require(self.mode in ("off", "active", "paused"), "管理设置损坏")
        self.directory = None
        self.pre = None
        self.last = self.pending = None
        self.error = "上次停止时的窗口恢复尚未完成。请重新核对并恢复。" if self.prefs.get("pendingStop") else None
        self.last_status = None
        self.count = 0
        self.seen_resize = None
        self.recovery_note = ""
        if self.prefs.get("session"):
            self.directory = self.root / str(uuid.UUID(self.prefs["session"]))
            require(self.directory.resolve() == self.directory, "会话路径异常")
            self.run = read(self.directory / "run.json")
            require(self.run["session"] == self.directory.name, "会话不匹配")

    def helper(self, name):
        return self.apps / (name + ".app") / "Contents/MacOS" / name

    def control(self, verb):
        args = [self.helper("NearpaneFrameController"), verb]
        if verb != "preflight":
            args.append(self.directory)
        result = subprocess.run(args, capture_output=True, timeout=24)
        require(result.returncode == 0, result.stderr.decode(errors="replace").strip() or "窗口控制器已停止")
        return json.loads(result.stdout)

    def preflight(self):
        self.pre = self.control("preflight")
        require(self.pre["parent"]["pid"] == os.getpid(), "控制器身份变化")
        require(self.pre["trusted"], "辅助功能未授权给已安装的窗口控制器")
        if self.mode != "off":
            require(self.prefs.get("display") == self.pre["screens"]["secondary"], "已授权的显示器变化")
        if self.directory:
            require(self.pre["screens"] == self.run["screens"], "显示器或登录会话变化，已保留恢复记录")

    def grant(self, mode):
        save(self.directory / "grant.json", dict(session=self.run["session"], display=self.run["screens"]["secondary"],
             writer=self.pre["parent"], mode=mode))

    def status(self, message=None):
        owner = self.owner(optional=True)
        windows = [m["id"] for m in owner["members"]] if owner else []
        value = dict(mode=self.mode, members=self.count, windows=windows, detail=self.error or message or
                     {"off": "尚未授权", "active": "正在观察已授权应用", "paused": "已暂停，保留当前布局"}[self.mode],
                     blocked=bool(self.error), trusted=self.pre and self.pre["trusted"] or False)
        if self.recovery_note:
            value["detail"] += " · " + self.recovery_note
        if value != self.last_status:
            self.last_status = value
            save(self.root / "status.json", value)
            print(json.dumps(value, ensure_ascii=False), flush=True)

    def owner(self, optional=False):
        path = self.directory and self.directory / "owner.json"
        if not path or not path.exists():
            if optional:
                return None
            raise ValueError("等待已登记应用的窗口")
        result = read(path)
        require(result["session"].lower() == self.directory.name, "窗口应用会话变化")
        return result

    def open_window(self):
        if self.pre is None:
            self.preflight()
        if self.directory:
            owner = self.owner(optional=True)
            if owner and time.clock_gettime(time.CLOCK_UPTIME_RAW) - owner["uptime"] >= 2:
                require(self.control("product-retired") == {"retired": True}, "原窗口进程的结束尚未确认")
                save(self.directory / "retired.json", dict(owner=owner["owner"], reason="original process ended"))
                self.directory = None
                self.prefs.pop("session", None)
                save(self.settings, self.prefs)
                self.last = self.pending = self.error = None
                self.preflight()
        if not self.directory:
            sid = str(uuid.uuid4())
            self.directory = self.root / sid
            self.directory.mkdir(mode=0o700)
            self.run = dict(productManagement=True, session=sid, parent=self.pre["parent"],
                            screens=self.pre["screens"], deadline=0)
            save(self.directory / "run.json", self.run)
            self.prefs["session"] = sid
            save(self.settings, self.prefs)
            with (self.directory / "owner.log").open("ab") as log:
                subprocess.Popen([self.helper("NearpaneFixtureWindows"), self.directory], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        deadline = time.monotonic() + 4
        while not self.owner(optional=True) and time.monotonic() < deadline:
            time.sleep(.08)
        state = self.owner()
        occupied = state.get("occupied", [m["index"] for m in state["members"]])
        index = next((i for i in range(1, 33) if i not in occupied), None)
        require(index is not None, "此兼容应用的示例窗口已满")
        self.fixture_command("create", index)

    def fixture_command(self, action, index):
        owner = self.owner()
        require(0 <= time.clock_gettime(time.CLOCK_UPTIME_RAW) - owner["uptime"] < 2, "已登记窗口进程不可用")
        path = self.directory / "command.json"
        require(not path.exists() or read(path)["sequence"] == owner["command"], "窗口命令尚未完成")
        request = dict(sequence=owner["command"] + 1, action=action, index=index)
        if action == "close":
            request["expected"] = next(m["id"] for m in owner["members"] if m["index"] == index)
        save(path, request)

    def snapshot(self):
        owner = self.owner()
        strict = os.environ.get("NEARPANE_MANAGEMENT_ACCEPTANCE") == self.root.parent.parent.name
        require(0 <= time.clock_gettime(time.CLOCK_UPTIME_RAW) - owner["uptime"] < 2 and (not strict or not owner["keyOrMain"]),
                "窗口身份、显示器或焦点无法重新确认")
        config = read(self.config)
        key = plan_key(owner, config, self.run["screens"]["secondary"])
        self.count = len(key[2])
        return owner, config, key

    def issue_ticket(self, owner, key, *, recovery=False):
        pairs = key[2]
        request = dict(owner, members=[m for m, _ in pairs], frames=[f for _, f in pairs])
        save(self.directory / "presentation-request.json", request)
        proof = self.control("product-presentation")
        require(proof["session"].lower() == self.directory.name and proof["revision"] == owner["revision"],
                "窗口呈现回执与当前会话不符")
        save(self.directory / "presentation-result.json", proof)
        observed = proof["confirmed"]
        confirmed = [(o["member"], o["cg"]) for o in observed if o["onScreen"] is True and o["ax"] == o["cg"]]
        require(len(confirmed) == len(observed) and confirmed == [p for p in pairs if p in confirmed],
                "窗口呈现回执身份或几何不符")
        require(confirmed and (confirmed == pairs or recovery), proof.get("refusal") or "窗口呈现尚未确认，暂不可管理")
        current, _, current_key = self.snapshot()
        require(current_key == key and not current.get("editing") and current.get("editTokens") == owner.get("editTokens")
                and current["keyOrMain"] == owner["keyOrMain"], "窗口在呈现核对后发生变化")
        require(0 <= time.clock_gettime(time.CLOCK_UPTIME_RAW) - proof["beganUptime"] <= 3, "窗口呈现观测已过期")
        save(self.directory / "ticket.json", dict(request, members=[m for m, _ in confirmed], frames=[f for _, f in confirmed]))

    def apply(self, verb, approved=None):
        owner, config, key = self.snapshot()
        if approved is not None and (key != approved or owner.get("editing")):
            self.pending = None
            return False
        if not key[2]:
            self.last = key
            return True
        self.issue_ticket(owner, key)
        save(self.directory / "candidate.json", dict(configuration=config, ratio=self.prefs["ratio"],
             swap=self.prefs["swap"], keepIntent=False))
        self.grant("restoring" if verb == "candidate-exit" else "active")
        result = self.control(verb)
        require(result["session"].lower() == self.directory.name and result["snapshotRevision"] == owner["revision"],
                "动作回执与观测不符")
        # Use the independent AX/CG result, never a late owner heartbeat as the committed fingerprint.
        pairs = [(o["member"], o["cg"]) for o in result["observations"]]
        require(all(o["ax"] == o["cg"] and o["onScreen"] for o in result["observations"]), "缺少真实窗口回读")
        self.last = (*key[:2], pairs, *key[3:])
        self.pending = None
        save(self.directory / "last-result.json", result)
        return True

    def recover(self):
        path = self.directory / "journal.json"
        if path.exists() and read(path)["status"] not in ("retained", "restored"):
            owner, config, key = self.snapshot()
            require(key[2], "恢复等待原窗口和权限")
            self.issue_ticket(owner, key, recovery=True)
            save(self.directory / "candidate.json", dict(configuration=config, ratio=self.prefs["ratio"], swap=self.prefs["swap"], keepIntent=False))
            self.grant("restoring")
            result = self.control("recover")
            require(result["journal"]["status"] == "restored", "未完成恢复")
            save(self.directory / "last-recovery.json", result)
            self.recovery_note = "上次异常恢复已核对 %d 扇窗口" % len(result["observations"])

    def tick(self):
        if not self.directory or self.mode != "active" or self.error:
            return
        if self.pre is None:
            self.preflight()
            self.recover()
        owner = self.owner()
        if not owner["members"] and owner["revision"] and time.clock_gettime(time.CLOCK_UPTIME_RAW) - owner["uptime"] >= 2:
            require(self.control("product-retired") == {"retired": True}, "等待原进程退出")
            save(self.directory / "retired.json", dict(owner=owner["owner"], reason="all compatible windows closed"))
            self.prefs.pop("session")
            save(self.settings, self.prefs)
            self.directory = self.last = self.pending = None
            self.count = 0
            return
        owner, _, key = self.snapshot()
        if owner.get("editing"):
            self.pending = None
            return
        if key == self.last:
            self.seen_resize = owner.get("lastResize")
            self.pending = None
        elif key == self.pending:
            resize = owner.get("lastResize")
            changed = [(m, f) for m, f in key[2] if self.last and (m, f) not in self.last[2]]
            explicit = (resize and resize != self.seen_resize and self.count == 2 and len(changed) == 1
                        and changed[0][0]["id"] == owner.get("resizedWindow") and changed[0][1] == owner.get("resizedFrame")
                        and 0 <= time.clock_gettime(time.CLOCK_UPTIME_RAW) - owner.get("resizeUptime", 0) < 2)
            if self.apply("candidate-adopt" if explicit else "candidate-layout", approved=key):
                self.seen_resize = resize
        else:
            self.pending = key

    def stop_management(self, intent, retry=False):
        if self.directory and self.mode != "off":
            # Publish explicit exit intent before recovery or a new frame transaction. A failed
            # orderly quit must not look like an unattended crash restart on the next launch.
            self.prefs["pendingStop"] = intent
            save(self.settings, self.prefs)
            self.preflight()
            self.recover()
            self.apply("candidate-exit")
            self.grant("off")
        if intent == "disable":
            self.mode = "off"
        elif retry:
            self.mode = "paused"
        self.prefs["mode"] = self.mode
        self.prefs.pop("pendingStop", None)
        save(self.settings, self.prefs)
        self.error = self.pending = self.last = None
        self.count = 0

    def command(self, cmd):
        pending = self.prefs.get("pendingStop")
        if pending:
            if cmd == "quit":
                return False
            require(cmd in ("retry", "disable") and pending in ("quit", "disable"), "请先处理上次未完成的恢复")
            self.stop_management("disable" if cmd == "disable" else pending, retry=True)
            return True
        if cmd in ("disable", "quit"):
            self.stop_management(cmd)
            return cmd != "quit"
        if cmd in ("enable", "resume", "retry"):
            require(cmd == "enable" or self.mode != "off", "需要先授权")
            self.preflight()
            if self.directory:
                self.recover()
            self.prefs["display"] = self.pre["screens"]["secondary"]
            self.mode = self.prefs["mode"] = "active"
            save(self.settings, self.prefs)
            self.error = self.last = self.pending = None
        elif cmd == "pause":
            require(self.mode != "off", "尚未授权")
            self.mode = self.prefs["mode"] = "paused"
            save(self.settings, self.prefs)
            if self.directory and self.pre:
                self.grant("paused")
            self.pending = None
        elif cmd == "open":
            self.open_window()
        elif cmd == "close":
            members = self.owner()["members"]
            require(members, "没有兼容窗口")
            self.fixture_command("close", members[-1]["index"])
        elif cmd == "adopt" or cmd.startswith("pair "):
            require(self.mode == "active" and self.directory, "未启用管理")
            self.preflight()
            self.recover()
            if cmd == "adopt":
                self.apply("candidate-adopt")
            else:
                _, percent, order = cmd.split()
                require(20 <= int(percent) <= 80 and order in ("swap", "original"), "双窗比例或槽位无效")
                self.prefs.update(ratio=int(percent)/100, swap=order == "swap")
                self.apply("candidate-pair")
                save(self.settings, self.prefs)
            self.error = None
        else:
            raise ValueError("未知窗口管理命令")
        return True

    def loop(self):
        self.status()
        while True:
            command = None
            try:
                ready, _, _ = select.select([sys.stdin], [], [], .30)
                if ready:
                    line = sys.stdin.readline()
                    if not line:  # Unexpected Host death. Leave the WAL and live app for the next Host.
                        return
                    command = line.strip()
                    if not self.command(command):
                        return
                else:
                    self.tick()
                self.status()
            except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
                self.error = str(error)
                if self.directory and self.pre:
                    self.grant("paused")
                self.status()
                if command == "quit":
                    return


if __name__ == "__main__":
    try:
        Manager(Path(sys.argv[1]), Path(__file__).resolve().parents[2]).loop()
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps(dict(mode="off", members=0, windows=[], detail=str(error), blocked=True, trusted=False)), flush=True)
        sys.exit(1)
