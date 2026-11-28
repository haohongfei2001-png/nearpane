"""Exercise the actual window exclusion button and the same Host policy setter used by Settings."""
import json
import subprocess
import time


def run(t, original, *, check, wait, put, out, work):
    t.idle_review = True
    t.start_host()
    t.press("admission-open")
    t.press("admission-ordinary-app")
    a,b,sibling = original
    for number in (a,b):
        t.press("admission-window-"+str(number))
    t.press("admission-read")
    t.press("ordinary-confirm")
    x,y,w,h = t.run_focus["bounds"]
    left,width = x+160,w-160
    pair = {**original, a:[left,y,width/2,h], b:[left+width/2,y,width/2,h]}
    t.checkpoint("explicit-pair",pair,2)
    t.press("ordinary-exclude-"+str(b))
    expected = {**pair,a:[left,y,width,h]}
    actions = t.checkpoint("persistent-window-exclusion",expected,3)
    rules_file=t.session/"support/Nearpane/host-configuration.json"
    def rules():
        return json.loads(rules_file.read_text())["workspaces"]
    individual = rules()["windows"]
    check(any(key.get("number") == b and key.get("pid")==t.fixture.pid and rule=="exclude"
              for key,rule in zip(individual[::2],individual[1::2])), "missing persisted window exclusion")
    check([z["id"]["number"] for z in actions].count(b)==1 and all(z["id"]["number"]!=sibling for z in actions),
          "changed excluded or unselected window")
    initial=t.action_ids()
    sample=t.checkpoints[-1]
    helpers=sample.get("controllerResources",[])
    check(len(helpers)==1,"no unique enrolled controller")
    participants={"host":(t.hostpid,t.hostexe),
                  "controller":(helpers[0]["pid"],t.hostexe.parents[1]/"Helpers/NearpaneOrdinaryWindowController")}
    idle=[]
    start=time.monotonic()
    for point in range(7):
        time.sleep(max(0,start+30*point-time.monotonic()))
        check(t.host.poll() is None and t.focus(t.observe()) and t.fixture.poll() is None,
              "idle process or foreground changed")
        check(t.action_ids()==initial,"new action during steady-state management")
        row={"elapsed":time.monotonic()-start,"receipts":len(initial)}
        for name,(pid,exe) in participants.items():
            process=subprocess.run([work/"counters",str(pid),str(exe)],capture_output=True,text=True,timeout=3)
            row[name]=json.loads(process.stdout) if process.returncode==0 else {"unavailable":process.returncode}
        idle.append(row)
        put(out/"steady-resources.json",idle)
    t.checkpoint("three-minute-stable",expected,3)
    # The acceptance request sets a single predefined synthetic bundle exclusion through
    # HostSession. It cannot identify other processes or authorize a window write.
    t.action("exclude-sample-app")
    wait(lambda: "net.example.standard-documents" in rules()["excludedApps"]
         and not (t.records/"journal.json").exists())
    t.checkpoint("app-excluded-after-idle",expected,3)
    check(t.action_ids()==initial and list(t.records.glob("excluded-*.json")),"missing completed revocation")
    put(out/"exclusion-result.json",dict(session=t.sid,explicitlyExcluded=b,appRevoked=a,unapproved=sibling,
        idleSeconds=idle[-1]["elapsed"],actions=len(initial),writesAfterExclusion=0,settings=rules()))
