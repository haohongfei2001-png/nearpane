"""Native fullscreen, zoom, Split View and relaunch observations of two synthetic real windows."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

from acceptance import encode
from installed_profile import APP, PROFILE, installed_pid, launch_isolated, owns_profile, quit_host


def until(read, predicate, seconds=6):
    end = time.monotonic()+seconds
    last = None
    while time.monotonic()<end:
        try:
            last = read()
            if predicate(last): return last
        except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError): pass
        time.sleep(.12)
    raise RuntimeError("Independent or fixture state did not reach the requested checkpoint")


def run(kit, output):
    output.mkdir(parents=True, exist_ok=False)
    home = Path(os.environ["NEARPANE_TEST_HOME"])
    generation = Path(os.environ["NEARPANE_TEST_GENERATION"])
    host = installed_pid()
    if not owns_profile(host, home/PROFILE): raise RuntimeError("An ordinary installed Host with the test profile is required")
    out = {"M01":"BLOCKED", "R02":"NOT_RUN", "F01":"NOT_RUN", "splitView":"NOT_RUN", "checkpoints": {}}
    log = (output/"actions.jsonl").open("x")
    def record(label, **data):
        log.write(json.dumps(dict(event=label, monotonic=time.monotonic(), **data))+"\n");log.flush();os.fsync(log.fileno())
    def save(): (output/"results.json").write_text(encode(out))
    with tempfile.TemporaryDirectory(prefix="np-lifecycle-",dir="/private/tmp") as tmp:
        root=Path(tmp)
        binary=kit/"Lifecycle Window.app/Contents/MacOS/Lifecycle"
        proc=None; movie=None; folder=None
        def start():
            nonlocal folder,proc
            folder=root/str(uuid.uuid4());folder.mkdir(mode=0o700)
            proc=subprocess.Popen([binary,folder],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            first=until(state,lambda d:d.get("pid")==proc.pid and len(set(d["numbers"]))==2)
            return first["numbers"]
        def state(): return json.loads((folder/"windows.json").read_text())
        def stop():
            if proc and proc.poll() is None:
                (folder/"close").touch()
                proc.wait(timeout=8)
        def send(action,index=0):
            nonce=str(uuid.uuid4());f=folder/"next.json";f.write_text(json.dumps(dict(nonce=nonce,action=action,index=index)))
            f.replace(folder/"request.json")
            until(state,lambda d:d["lastCommand"]==nonce)
        def observe(command="read",*args):
            data=json.loads(subprocess.check_output([kit/"lifecycle-read",command,str(proc.pid),*map(str,numbers),*map(str,args)],timeout=7))
            # Keep only system identities, counts and flags. The two fixture documents contain generated content.
            return {k:v for k,v in data.items() if k!="sidebarRows"}
        def checkpoint(name):
            sample=observe();metrics=json.loads(subprocess.check_output([kit/"metrics",str(host)]))
            out["checkpoints"][name]={"system":sample,"fixture":state(),"hostMetrics":metrics}
            record("checkpoint",name=name,current=sample["current"],membership=sample["memberships"]);save()
            return sample
        try:
            numbers=start();send("activate",0)
            start_sample=until(observe,lambda o:o["frontmostFixture"] and o["memberships"][0]==[o["current"]] and
                                        any(s["id"]==o["current"] and s["type"]==0 for s in o["scopes"]))
            ordinary=start_sample["current"];base=checkpoint("ordinary")
            send("zoom")
            until(state,lambda d:d["zoomed"][0]);zoom=checkpoint("standardZoom")
            out["zoomInOrdinarySpace"] = (zoom["current"]==ordinary and not state()["fullscreen"][0] and
                                         state()["frames"][0] != out["checkpoints"]["ordinary"]["fixture"]["frames"][0])
            send("unzoom")
            film=output/"owned-window.mp4"
            movie=subprocess.Popen([kit/"film",str(proc.pid),str(numbers[0]),"6",film],
                                   stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            until(lambda:film.with_suffix(".mp4.ready").exists() or movie.poll() is not None,bool)
            send("fullscreen")
            fs=until(observe,lambda o:o["current"]!=ordinary and o["memberships"][0]==[o["current"]] and
                     any(s["id"]==o["current"] and s["type"]==4 for s in o["scopes"]),10)
            full=fs["current"];checkpoint("nativeFullscreen")
            subprocess.run(["/usr/sbin/screencapture","-x","-o","-l",str(numbers[0]),output/"owned-fullscreen.png"],
                           check=True,timeout=5)
            stdout,stderr=movie.communicate(timeout=12)
            if movie.returncode==0:
                out["movie"]=json.loads(stdout);film.with_suffix(".mp4.ready").unlink(missing_ok=True)
            else: out["movieError"]=stderr.strip()
            # B is an ordinary owned document. Asking the fixture to bring it forward
            # is setup. Only the subsequent production sidebar press counts for F01.
            send("activate",1)
            try:
                until(observe,lambda o:o["current"]==ordinary,4)
                response=observe("row",full);record("installed-fullscreen-row",response=response)
                if response.get("issued"):
                    until(observe,lambda o:o["current"]==full and o["memberships"][0]==[full],5)
                    out["installedFullscreenArrival"]=True
                    back=observe("row",ordinary); record("installed-return-row",response=back)
                    if back.get("issued"):
                        until(observe,lambda o:o["current"]==ordinary,5);out["installedReturn"]=True
            except (RuntimeError, subprocess.SubprocessError) as error:
                out["fullscreenRouteIssue"]=str(error)
            finally:
                send("ordinary",0)
                until(state,lambda d:not d["fullscreen"][0],8)
            restored=checkpoint("returned")
            out["F01"]="PASS" if (out.get("installedFullscreenArrival") and out.get("installedReturn") and
                                  out.get("zoomInOrdinarySpace") and restored["memberships"][0]==[ordinary] and
                                  out["checkpoints"]["nativeFullscreen"]["hostMetrics"]["visibleDisplays"]==0 and
                                  out["checkpoints"]["returned"]["hostMetrics"]["visibleDisplays"]>0) else "PARTIAL"
            send("activate",0);until(observe,lambda o:o["frontmostFixture"])
            menu=observe("tile");record("owned-window-system-tiling-menu",response=menu)
            if menu.get("issued"):
                time.sleep(.9);pair=observe("pair");record("native-pair-picker",response=pair)
                if pair.get("issued"):
                    try:
                        split=until(observe,lambda o:o["current"]!=ordinary and all(m==[o["current"]] for m in o["memberships"]),6)
                        frames=state()["frames"];bounds=sorted(frames,key=lambda f:f[0])
                        joined=abs((bounds[0][0]+bounds[0][2])-bounds[1][0])<30 and abs(bounds[0][3]-bounds[1][3])<40
                        out["splitView"]="PASS" if joined and any(r["id"]==split["current"] and r["type"]==4 for r in split["scopes"]) else "FAIL"
                        checkpoint("splitView")
                    except RuntimeError as error:out["splitView"]="UNKNOWN";out["splitReason"]=str(error)
                else:out.update(splitView="BLOCKED",splitReason="System picker did not expose a unique owned second document")
            else:out.update(splitView="BLOCKED",splitReason="Window menu did not expose an enabled full-screen-left action for this document")
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
            out["issue"]=str(error);record("stopped",reason=str(error))
        finally:
            if movie and movie.poll() is None:
                try:movie.communicate(timeout=12)
                except subprocess.TimeoutExpired:movie.terminate();movie.wait(timeout=5)
            try:
                if proc and proc.poll() is None and folder and (folder/"windows.json").is_file():
                    oldpid=proc.pid; oldnumbers=state()["numbers"]; stop()
                    numbers=start()
                    restarted=checkpoint("documentRelaunch")
                    independent=not set(oldnumbers)&set(numbers) and oldpid!=proc.pid and bool(restarted["memberships"][0])
                    out["documentRelaunch"]={"staleWindowNumbersGoneFromFixture":not set(oldnumbers)&set(numbers),
                                             "differentProcess":oldpid!=proc.pid,"independentMembership":independent}
            except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
                out["documentRelaunchIssue"]=str(error)
            stop()
            try:
                oldhost=host;config=generation/"Nearpane/host-configuration.json"
                fingerprint=hashlib.sha256(config.read_bytes()).hexdigest()
                quit_host(oldhost);host,generation2=launch_isolated(home)
                out["installedRelaunch"]={"newPID":host!=oldhost,"sameGeneration":generation2==generation,
                                          "configurationPreserved":hashlib.sha256(config.read_bytes()).hexdigest()==fingerprint}
                out["R02"]="PARTIAL" if all(out["installedRelaunch"].values()) else "FAIL"
            except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
                out["installedRelaunchIssue"]=str(error);out["R02"]="FAIL"
            out["ownedWindowAppExited"]=proc is None or proc.poll() is not None
            out["M01Reason"]="This run has one physical display. Independent/shared, rotation and reconnect require an additional physical display."
            out["R02SessionTransitions"]="Lock/unlock and sleep/wake not exercised on the occupied interactive login session"
            save();log.close()
    return out


if __name__=="__main__":
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
