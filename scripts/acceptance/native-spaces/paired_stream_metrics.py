"""Independent presentation clocks for two source streams and one simultaneous two-patch panel stream."""
from bisect import bisect_left,bisect_right
from collections import Counter
import hashlib
import json
import math
from statistics import median

from paired_preview_metrics import percentiles
from space_scope import private_file

def finite(n):
    return type(n) in (int,float) and math.isfinite(n)

def qualified(frames,session):
    guards=session.get("guards",[]);times=[g["time"] for g in guards]
    clocks=session.get("clocks",[])
    if not guards or len(clocks)<2 or not all(finite(c.get("uncertainty")) and 0<=c["uncertainty"]<=.005 for c in clocks):
        return [],{"reason":"noIndependentClockBracket"}
    if (not all(b>a for a,b in zip(times,times[1:])) or not guards[0]["fullBinding"] or
        max(abs(c[k]-clocks[0][k]) for c in clocks for k in ("machOffset","hostOffset"))>.002):
        return [],{"reason":"scopeOrClockDiscontinuity"}
    good_full=[g["time"] for g in guards if g["valid"] and g["fullBinding"]]
    if len(good_full)<2:return [],{"reason":"missingFullScopeReadbacks"}
    actual=[[] for _ in range(3)];rejected=Counter();status=[Counter() for _ in range(3)];tested=[[] for _ in actual]
    for raw in frames:
        n=raw["channel"]
        if type(n) is not int or n not in (0,1,2):raise ValueError("unexpectedStreamChannel")
        status[n][raw["status"]]+=1
        d,p,cb=raw.get("displayTime"),raw.get("hostPTS"),raw.get("callback")
        valid=lambda t:finite(t) and finite(cb) and 0<t and -.005<=cb-t<=1.0
        if valid(d) and valid(p):tested[n].append(abs(d-p)*1000)
    # A presentation timestamp without an SC display clock is explicitly lower-confidence. Never
    # substitute the callback time or the scheduled fixture pulse for an actual presentation.
    pts_correlated=[len(x)>=3 and (percentiles(x)["p95"]<=34) for x in tested]
    for raw in frames:
        n=raw["channel"];d,p,cb=raw.get("displayTime"),raw.get("hostPTS"),raw.get("callback")
        valid=lambda t:finite(t) and finite(cb) and 0<t and -.005<=cb-t<=1.0
        if valid(d):t,basis=d,"SCDisplayTime"
        elif valid(p):t,basis=p,"correlatedHostPTS" if pts_correlated[n] else "hostPTSOnly"
        else:rejected["missingPresentationTime"]+=1;continue
        if raw["status"] not in (0,4) or len(raw["samples"])!=(2 if n==2 else 1):
            rejected["noNewCompletePixels"]+=1;continue
        i=bisect_right(times,t)-1;j=bisect_left(times,max(t,cb))
        if (i<0 or j>=len(guards) or t<good_full[0] or cb>good_full[-1] or
                times[j]-times[i]>1.2 or not all(g["valid"] for g in guards[i:j+1])):
            rejected["unbracketedScope"]+=1;continue
        if actual[n] and (raw["sequence"]<=actual[n][-1]["sequence"] or t<=actual[n][-1]["time"]):
            rejected["nonAdvancingPresentation"]+=1;continue
        actual[n].append(dict(raw,time=t,basis=basis,guardBefore=times[i],guardAfter=times[j]))
    interval=max(c["uncertainty"] for c in clocks)
    return actual,dict(machAndHostClockUncertaintyMs=1000*interval,statusCounts=[{str(k):v for k,v in x.items()} for x in status],
                       rejected=dict(rejected),observedDisplayToPTSDifferenceMs=[percentiles(x) for x in tested],
                       completePixelFrames=[len(x) for x in actual],basis=[dict(Counter(v["basis"] for v in x)) for x in actual],
                       actualPresentationIntervalsMs=[percentiles([1000*(b["time"]-a["time"]) for a,b in zip(x,x[1:])]) for x in actual])

def steps(series,patch,doc):
    colors=[f["samples"][patch]["color"] for f in series]
    out={}
    for e in range(1,7):
        target=f"{doc}/{e}";old=f"{doc}/{e-1}"
        i=next((i for i in range(1,len(series)-1) if colors[i:i+2]==[target,target]),None)
        if i is None:continue
        j=next((j for j in range(i-1,-1,-1) if colors[j]==old),None)
        if j is not None:out[e]=(series[j],series[i],series[i+1])
    return out

def latency_summary(records):
    return dict(n=len(records),lower=percentiles([r[0] for r in records]),upper=percentiles([r[1] for r in records]),
                firstConfirmedPresentationDifference=percentiles([r[2] for r in records]),
                intervalWidth=percentiles([r[1]-r[0] for r in records]))


def metrics(streams,clock,session):
    windows=[];combined=[];wrongs=0;all_sim=True
    for doc in (0,1):
        src,panel=streams[doc],streams[2]
        origins,pictures=steps(src,0,doc),steps(panel,doc,doc)
        results=[];latencies=[]
        for epoch in range(1,7):
            first,last=origins.get(epoch),pictures.get(epoch)
            r={"epoch":epoch,"outcome":"UNKNOWN"}
            if first:
                r["sourceBracket"]=[first[0]["time"],first[1]["time"]]
                a=first[1]["time"]; end=(origins[epoch+1][0]["time"] if epoch+1 in origins else
                    max((f["time"] for f in src if f["samples"][0]["color"]==f"{doc}/{epoch}"),default=a))
                stable=[f["samples"][doc] for f in panel if a+.15<=f["time"]<=end]
                counts=Counter(item["color"] for item in stable);r["duringConfirmedSource"]=dict(counts)
                srcRGB=[f["samples"][0]["median"] for f in src if a<=f["time"]<=end and f["samples"][0]["color"]==f"{doc}/{epoch}"]
                if stable and srcRGB:
                    source=[median(p[c] for p in srcRGB) for c in range(4)]
                    target=[median(p["median"][c] for p in stable) for c in range(4)]
                    r["observedRGBA"]={"source":source,"card":target,"cardMinusSource":[round(x-y,2) for x,y in zip(target,source)]}
                if any(s.startswith(f"{1-doc}/") for s in counts):r["outcome"]="WRONG_WINDOW"
                elif last:
                    r["cardBracket"]=[last[0]["time"],last[1]["time"]]
                    margin=2*clock.get("machAndHostClockUncertaintyMs",0)
                    low=max(0,(last[0]["time"]-first[1]["time"])*1000-margin)
                    high=(last[1]["time"]-first[0]["time"])*1000+margin
                    observable=(last[1]["time"]-first[1]["time"])*1000
                    if high>=low:
                        ref=[f["basis"] for f in (*first,*last)]
                        r.update(outcome="MATCH",latencyMs=[round(low,3),round(high,3)],firstConfirmedPresentationDifferenceMs=round(observable,3),
                                 timingBasis=sorted(set(ref)),intervalWidthMs=round(high-low,3))
                        if all(x!="hostPTSOnly" for x in ref):latencies.append((low,high,observable))
                    else:r["outcome"]="CARD_PRECEDES_SOURCE"
                elif len(stable)>=2 and all(s=="blank" for s in counts):r["outcome"]="BLANK"
                elif len(stable)>=2 and all(s.startswith(f"{doc}/") for s in counts):r["outcome"]="STALE"
            results.append(r)
        combined.extend(latencies)
        source_counts=Counter(f["samples"][0]["color"] for f in src)
        picture_counts=Counter(f["samples"][doc]["color"] for f in panel)
        wrongs+=sum(n for col,n in picture_counts.items() if col.startswith(f"{1-doc}/"))
        windows.append({"document":doc,"events":results,"outcomes":dict(Counter(f["outcome"] for f in results)),
                        "sourceSampleCounts":dict(source_counts),"pictureSampleCounts":dict(picture_counts),
                        "blankSamples":picture_counts["blank"],"unknownSamples":picture_counts["unknown"],
                        "wrongWindowSamples":sum(n for col,n in picture_counts.items() if col.startswith(f"{1-doc}/")),
                        "latencyMs":latency_summary(latencies)})
    simultaneous=[]
    for e in range(7):
        supporting=[]
        for d in (0,1):
            points=[r["time"] for r in streams[d] if r["samples"][0]["color"]==f"{d}/{e}"]
            supporting.append([min(points),max(points)] if len(points)>=2 else None)
        count=0;consecutive=False;previous=False
        for frame in streams[2]:
            matches=all(x and x[0]<=frame["time"]<=x[1] for x in supporting) and [p["color"] for p in frame["samples"]]==[f"0/{e}",f"1/{e}"]
            if matches:count+=1;consecutive|=previous
            previous=matches
        all_sim &= consecutive
        simultaneous.append(dict(epoch=e,matchingFrames=count,twoConsecutive=consecutive))
    failed=wrongs or any(e['outcome'] in ('BLANK','STALE','CARD_PRECEDES_SOURCE') for w in windows for e in w['events'])
    complete=not session.get("reason") and session.get("stopped")==[True]*3
    return {"status":"FAIL" if failed else "PASS" if complete and all_sim and len(combined)==12 else "INCONCLUSIVE","windows":windows,
            "simultaneous":simultaneous,"sampling":clock,"latencyMs":latency_summary(combined),
            "nativeStageManagerComparison":{"status":"NOT_MEASURED","latencyMs":None},
            "method":"Nearest-rank bounds on independent calibrated presentation transitions. PTS-only matches remain visible per event and are excluded from latency quantiles."}

def integrate(events,folder,output,binding):
    frames=[e["streamFrame"] for e in events if "streamFrame" in e]
    session=next((e["streamSession"] for e in events if "streamSession" in e),{})
    if not session:
        session={"reason":"residentCaptureExitedWithoutFinalReceipt","guards":[e["streamGuard"] for e in events if "streamGuard" in e],
                 "clocks":[e["streamClock"] for e in events if "streamClock" in e],"stopped":[False]*3}
    streams,clock=qualified(frames,session)
    if not streams:streams=[[],[],[]]
    eligible={(f["channel"],f["sequence"]) for series in streams for f in series}
    archived=[];file=output/"presentation-frames.jsonl"
    with file.open("x",encoding="utf-8") as stream:
        for frame in frames:
            bound=(frame["channel"],frame["sequence"]) in eligible
            persisted=dict(frame,qualified=bound)
            if not bound:
                persisted["samples"]=[];persisted["offsets"]=[];persisted["pixelStatisticsWithheld"]=True
            stream.write(json.dumps(persisted,separators=(",",":"))+"\n");archived.append(persisted)
    streams,clock=qualified(archived,session)
    if not streams:streams=[[],[],[]]
    stats=metrics(streams,clock,session);batches=[];witnesses=[]
    packed=b""
    if session.get("packedBytes",0):
        packed=private_file((folder/"stream-patches.rgba").absolute(),limit=5_000_000)
        if len(packed)!=session["packedBytes"] or hashlib.sha256(packed).hexdigest()!=session["packedSHA256"]:raise ValueError("streamRawDigestMismatch")
    times=[[f["time"] for f in group] for group in streams[:2]]
    next_time=0;last=[0,0]
    for panel in streams[2]:
        t=panel["time"]
        if t<next_time:continue
        matches=[]
        for d in (0,1):
            j=bisect_left(times[d],t)
            choices=[streams[d][k] for k in (j-1,j) if 0<=k<len(times[d]) and streams[d][k]["sequence"]>last[d] and abs(times[d][k]-t)<=1/60]
            if choices:matches.append(min(choices,key=lambda f:abs(f["time"]-t)))
        if len(matches)!=2:continue
        next_time=t+.16;last=[f["sequence"] for f in matches]
        inputs=[(matches[0],0),(matches[1],0),(panel,0),(panel,1)]
        def member(f,p):
            return dict(start=f["time"],end=f["time"],displayTime=f["time"] if f["basis"]=="SCDisplayTime" else None,
                        frameStatus=f["status"],color=f["samples"][p]["color"],clockBasis=f["basis"],sequence=f["sequence"])
        row=[member(f,p) for f,p in inputs];batches.append(row);n=len(batches)
        offsets=[f['offsets'][p] for f,p in inputs]
        color=[item["color"] for item in row]
        if color[0] not in {f"0/{e}" for e in range(7)}:continue
        e=int(color[0][2:])
        if color!=[f"0/{e}",f"1/{e}"]*2 or any(o<0 or o+256>len(packed) for o in offsets):continue
        before=min(f["guardBefore"] for f,_ in inputs);after=max(f["guardAfter"] for f,_ in inputs)
        if after-before>3:continue
        raw=b"".join(packed[o:o+256] for o in offsets)
        if any(p[3]!=255 or p!=p[:4]*64 for p in [raw[i:i+256] for i in range(0,1024,256)]):raise ValueError("nonUniformStreamWitness")
        name=f"preview-{n:05d}.rgba"
        with (folder/name).open("xb") as f:f.write(raw)
        witnesses.append({"witness":dict(file=name,sha256=hashlib.sha256(raw).hexdigest(),batch=n,epoch=e,physicalFourPatch=True,uptime=t,
                           hostPID=binding["hostPID"],fixturePID=binding["fixturePID"],numbers=binding["numbers"],panel=binding["panel"],
                           bindingBefore=before,bindingAfter=after,cardKinds=["unreported"]*2)})
    info={"frames":file.name,"sha256":hashlib.sha256(file.read_bytes()).hexdigest(),"count":len(frames),"session":session,
          "compactBatches":len(batches),"maximumSourceToPanelJoinSeconds":1/60}
    auxiliary=[e for e in events if not any(k in e for k in ("streamFrame","streamGuard","streamClock"))]+witnesses
    if session and not session.get("reason") and session.get("stopped")==[True]*3:auxiliary.append({"completedBatches":len(batches)})
    return stats,batches,auxiliary,info


if __name__=="__main__":
    import argparse
    from pathlib import Path
    cli=argparse.ArgumentParser(description="Recompute the installed two-card presentation-clock metrics from qualified captured samples.")
    cli.add_argument("output",type=Path)
    args=cli.parse_args()
    saved=json.loads((args.output/"result.json").read_bytes())
    info=saved["presentation"]
    raw=(args.output/"presentation-frames.jsonl").read_bytes()
    if hashlib.sha256(raw).hexdigest()!=info["sha256"]:raise SystemExit("frame receipt SHA256 mismatch")
    series,clock=qualified([json.loads(line) for line in raw.splitlines()],info["session"])
    derived=metrics(series or [[],[],[]],clock,info["session"])
    if derived!=saved["metrics"]:raise SystemExit("presentation metrics differ from the original receipt")
    print(json.dumps({"status":"REPLAY_MATCH","original":derived["status"],"latencyMs":derived["latencyMs"]},indent=2))
