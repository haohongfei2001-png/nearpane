"""One passive recorder around the existing right drag and its two native geometry readbacks."""
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import uuid


class PairDragFilm:
    def __init__(self):
        self.proc = self.folder = self.run = None
        self.row = {"status": "NOT_RUN", "scope": "two enrolled fixture windows over an opaque matte",
                    "gesture": "first existing right drag", "cursor": False, "sidebar": False, "audio": False}

    def _signal(self, name, data):
        dest = self.folder / name
        with os.fdopen(os.open(str(dest) + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            json.dump(data, f)
        temp=dest.with_name(dest.name + ".tmp")
        os.link(temp,dest)
        temp.unlink()

    @classmethod
    def start(cls, run, entry, before, hashes):
        film = cls()
        film.run = run
        try:
            kit = run.kit.resolve(strict=True)
            binary = kit / "pair-drag-film"
            if not binary.exists():
                film.row["reason"] = "independentRecorderNotInKit"
                return film
            if (kit != run.kit or kit.parent != Path("/private/tmp") or not kit.name.startswith("nearpane-d01.")
                    or not run.folder.is_dir() or run.folder.resolve() != run.folder or run.folder.parent != kit
                    or run.folder.name != str(uuid.UUID(run.binding["session"]))
                    or binary.resolve(strict=True) != binary or binary.stat().st_uid != os.getuid()
                    or not binary.is_file() or binary.stat().st_mode & 0o022):
                raise ValueError("unboundPrivateRecorderKit")
            req = 'identifier "net.example.nearpane.pair-drag-film" and anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB"'
            subprocess.run(["/usr/bin/codesign","--verify","--strict","-R="+req,str(binary)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2, check=True)
            token = str(uuid.UUID(entry["id"]))
            if (entry.get("source") != run.binding["numbers"][0] or entry.get("destination") != run.binding["numbers"][1]
                    or len(before["ax"]) != 2 or len(before["cg"]) != 2 or before["members"] != run.binding["numbers"]
                    or not all(len(a)==len(b)==4 and all(abs(x-y)<=1 for x,y in zip(a,b)) for a,b in zip(before["ax"],before["cg"]))):
                raise ValueError("originalTwoDocumentGeometryUnconfirmed")
            created = run.folder / ("right-drag-film-" + token)
            created.mkdir(mode=0o700)
            film.folder = created
            film._signal("start.json", {**run.binding, "attempt":token,"hashes":hashes,"geometry":before,"expected":entry["expected"]})
            film.proc = subprocess.Popen([binary, film.folder],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
            if not select.select([film.proc.stdout],[],[],2.5)[0]:
                raise ValueError("recorderDidNotArmBeforeDeadline")
            ready = json.loads(film.proc.stdout.readline(32_768))
            if ready.get("status") != "READY" or ready.get("attempt") != token:
                raise ValueError(ready.get("reason") or "registeredSourceFrameUnavailable")
            film.row.update(status="ARMED", attempt=token, sourceDisplayUptime=ready["sourceDisplayUptime"])
        except Exception as error:
            film.row.update(status="UNKNOWN",reason=str(error)[:120] if isinstance(error,ValueError) else type(error).__name__)
            film._close()
        return film

    def _close(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                self.proc.terminate()
                try: self.proc.wait(timeout=0.35)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=1)
            self.proc.stdout.close()
            self.proc = None
        if self.folder is not None:
            for name in ("start.json", "end.json", "start.json.tmp", "end.json.tmp", "verified.mp4", "encoding.mp4"):
                (self.folder / name).unlink(missing_ok=True)
            try: self.folder.rmdir()
            except (OSError, FileNotFoundError): pass
            self.folder = None

    def finish(self, entry):
        if self.row["status"] != "ARMED":
            return self.row
        try:
            after, events = entry.get("after", []), entry.get("events", [])
            if entry.get("status") != "PASS" or entry.get("issued") is not True or len(after) != 2:
                raise ValueError("rightDragLacksTwoSuccessfulNativeLayoutReads")
            if len(events)<5 or events[0]["type"]!=1 or events[-1]["type"]!=2 or any(e["type"]!=6 for e in events[1:-1]):
                raise ValueError("actualPointerDragSequenceUnavailable")
            self._signal("end.json", {"attempt":entry["id"],"events":events,"after":after})
            reply = json.loads(self.proc.communicate(timeout=4)[0])
            if self.proc.returncode != 0 or reply.get("status") != "CAPTURED" or reply.get("attempt") != entry["id"]:
                raise ValueError(reply.get("reason") or "recorderDidNotSealTwoWindows")
            movie = self.folder / "verified.mp4"
            with os.fdopen(os.open(movie,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW), "rb") as f:
                info = os.fstat(f.fileno())
                if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 10_000_000 or info.st_uid != os.getuid():
                    raise ValueError("unqualifiedVideo")
                data = f.read()
            if hashlib.sha256(data).hexdigest() != reply.get("sha256"):
                raise ValueError("verifiedVideoDigestChanged")
            name = "right-drag-fixture-windows.mp4"
            receipt=self.run.rec.output/"right-drag-film.json"
            dest=self.run.rec.output/name
            with receipt.open("x",encoding="utf-8") as f:
                try:
                    json.dump(reply,f,sort_keys=True)
                    with dest.open("xb") as movie_file:
                        try: movie_file.write(data)
                        except OSError:
                            dest.unlink(missing_ok=True)
                            raise
                except (OSError,TypeError,ValueError):
                    receipt.unlink(missing_ok=True)
                    raise
            self.row.update(status="CAPTURED", file=name, receipt="right-drag-film.json", sha256=reply["sha256"],
                            encodedFrames=reply["encoding"]["encodedFrames"], duration=reply["encoding"]["duration"])
        except Exception as error:
            self.row.update(status="UNKNOWN", reason=str(error)[:120] if isinstance(error,ValueError) else type(error).__name__)
        finally:
            self._close()
        return self.row
