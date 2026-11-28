#!/usr/bin/env python3
"""Run actual Saytile file ingestion in six cold processes and reopen each journal in another process."""
from array import array
import argparse
import collections
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import wave

cold=importlib.import_module("r4-voice-cold")
from voice_matrix import add_noise
ROOT=Path(__file__).resolve().parents[3]


def pcm(path):
    with wave.open(str(path),"rb") as file:
        if (file.getsampwidth(),file.getframerate(),file.getnchannels())!=(2,16000,1):raise ValueError("unexpected corpus format")
        return array("h",file.readframes(file.getnframes()))


def first_voicing(reference):
    for i in range(0,len(reference)-159,160):
        frame=reference[i:i+160]
        if sum(x*x for x in frame)>=160*400*400 and max(map(abs,frame))>1100:return i
    return None


def alignment(source, saved, first):
    if first is None or len(source)<4000 or len(saved)<3000: return {"status":"UNKNOWN","reason":"shortOrSilentSignal"}
    # Input is digital file PCM; sign-run anchors permit the near-zero rounding from float32 conversion.
    src=bytes(x>0 for x in source);cap=bytes(x>0 for x in saved); votes=collections.Counter()
    for k in range(128,len(src)-128,241):
        token=src[k:k+96]
        if len(set(token))!=2:continue
        j=cap.find(token)
        if j>=0 and cap.find(token,j+1)<0:votes[j-k]+=1
    ranking=votes.most_common(2)
    if not ranking or ranking[0][1]<3 or (len(ranking)>1 and ranking[0][1]<=ranking[1][1]*2):
        return {"status":"UNKNOWN","reason":"noUniqueInputToJournalAlignment"}
    offset,anchors=ranking[0]
    start=first+offset
    result=dict(offsetFrames=offset,uniqueAnchors=anchors,firstCleanVoicingFrame=first,firstVoicingInJournal=start)
    if start<0: return dict(result,status="FAIL",reason="journalBeginsAfterFirstVoicedBlock")
    n=min(2400,len(source)-first,len(saved)-start)
    if n<1600:return dict(result,status="UNKNOWN",reason="insufficientOnsetCoverage")
    a,b=source[first:first+n],saved[start:start+n]
    denom=math.sqrt(sum(x*x for x in a)*sum(y*y for y in b))
    corr=sum(x*y for x,y in zip(a,b))/denom if denom else 0
    return dict(result,status="PASS" if corr>=.98 else "UNKNOWN",onsetCosine=round(corr,7),onsetSamplesCompared=n)


def whole_pcm(source, saved):
    length=min(len(source),len(saved))
    difference=[abs(source[i]-saved[i]) for i in range(length)]
    first=next((i for i,value in enumerate(source) if abs(value)>32),None)
    recorded=next((i for i,value in enumerate(saved) if abs(value)>32),None)
    return dict(sourceFrames=len(source),savedFrames=len(saved),sourceSHA256=hashlib.sha256(source.tobytes()).hexdigest(),
                savedSHA256=hashlib.sha256(saved.tobytes()).hexdigest(),firstSignalSource=first,firstSignalSaved=recorded,
                first320SamplesMaxDelta=max(difference[:320],default=None),maxDeltaAcrossOverlap=max(difference,default=None),
                samplesBeyondOnePCMUnit=sum(delta>1 for delta in difference),
                identical=len(source)==len(saved) and length>0 and not any(difference))


def subprocess_case(folder,phase):
    env={**os.environ,"NEARPANE_OFFLINE":"1","NEARPANE_P4_FILE_PHASE":phase,"NEARPANE_P4_FILE_CASE":str(folder)}
    p=subprocess.run(["bash","scripts/test.sh","--skip-build","--filter","coldFileJournalAndIndependentReopen"],cwd=ROOT,
                     env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=110)
    path=folder/(phase+".json")
    if p.returncode or not path.is_file():raise ValueError("isolated "+phase+" process returned "+str(p.returncode))
    return json.loads(path.read_bytes())


def run(output):
    os.umask(0o077)
    out={"case":"six fresh Saytile file processes, six independent store reopen processes, three unprimed Mandarin phrases",
         "physicalAudioDevices":0,"paidAPICalls":0,"modelInstallRequests":0,"installedHost":"NOT_RUN","cases":[]}
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open("x") as fp: json.dump(out,fp)
    def persist():
        tmp=output.with_suffix(".next");tmp.write_text(json.dumps(out,ensure_ascii=False,indent=2)+"\n");os.replace(tmp,output)
    build_env={**os.environ,"NEARPANE_OFFLINE":"1"}
    build_env.pop("NEARPANE_P4_FILE_CASE",None);build_env.pop("NEARPANE_P4_FILE_PHASE",None)
    # Rebuild this checkout's pinned domain and tests before asking SwiftPM to launch fresh processes with --skip-build.
    build=subprocess.run(["bash","scripts/test.sh","--filter","coldFileJournalAndIndependentReopen"],cwd=ROOT,env=build_env,
                         stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=360)
    out["buildExit"]=build.returncode
    if build.returncode:
        out["status"]={"journalReopen":"BLOCKED","onsetPCM":"NOT_RUN","actualASRScored":0};persist();return
    with tempfile.TemporaryDirectory(prefix="nearpane-p4-corpus.",dir="/private/tmp") as tmp:
        root=Path(tmp).resolve()
        for n,item in enumerate(importlib.import_module("voice_matrix").schedule(cold.PHRASES)[:6]):
            folder=root/f"case-{n}";folder.mkdir(mode=0o700);source=folder/"stimulus.wav"
            row=dict(phrase=item["phrase"],condition=item["condition"],order=n+1,utteranceAccuracy="NOT_RUN",journal="UNKNOWN")
            out["cases"].append(row)
            try:
                row["cleanSource"]=cold.make_stimulus(source,item["phrase"])
                clean=pcm(source);onset=first_voicing(clean)
                if item["condition"]=="noise10dB":row["noise"]=add_noise(source,n+1)
                original=pcm(source)
                write=subprocess_case(folder,"record")
                reopen=subprocess_case(folder,"reopen")
                row.update(recordPID=write["actualProcessID"],reopenPID=reopen["actualProcessID"],sourceSHA256=write["sourceSHA256"],
                           route=write["route"],appleDefaultInstalled=write["appleDefaultInstalled"])
                if row["recordPID"]==row["reopenPID"] or write["recordings"]!=reopen["recordings"] or len(write["recordings"])!=1:
                    raise ValueError("different cold/reopen process and exact one-row durable identity required")
                rec=write["recordings"][0];saved=array("h");aggregate=hashlib.sha256()
                for chunk in rec["chunks"]:
                    rel=Path(chunk["relative"])
                    if rel.is_absolute() or rel.parts[0]!=rec["id"] or len(rel.parts)!=2 or rel.suffix!=".wav":raise ValueError("outside synthetic journal")
                    path=folder/"voice/Audio"/rel
                    if path.resolve()!=path or not path.is_file():raise ValueError("synthetic WAV not an independent regular readback")
                    aggregate.update(path.read_bytes()); saved.extend(pcm(path))
                if len(saved)!=rec["frames"] or aggregate.hexdigest()!=rec.get("audioSHA256"):raise ValueError("reopened WAV bytes or frames mismatch")
                row.update(journal="PASS",recordingID=rec["id"],journalSHA256=rec["audioSHA256"],state=rec["state"],frames=rec["frames"],
                           onset=alignment(original,saved,onset),pcm=whole_pcm(original,saved))
                if rec["state"]=="final" and rec.get("preferredFinalID") and rec.get("finalSHA256"):
                    actual=rec["textForFixtureScoring"]
                    if hashlib.sha256(actual.encode()).hexdigest()!=rec["finalSHA256"]:raise ValueError("final hash differs from reopened preferred text")
                    row["finalComparison"]=cold.compare(item["phrase"],actual)
                    row["utteranceAccuracy"]="PASS" if cold.normalized(actual)==cold.normalized(item["phrase"]) else "FAIL"
                elif not row["appleDefaultInstalled"]:row["utteranceAccuracy"]="BLOCKED_DEFAULT_MODEL_NOT_INSTALLED"
                else:row["utteranceAccuracy"]="UNKNOWN_NO_PREFERRED_FINAL"
            except (ValueError,KeyError,OSError,subprocess.SubprocessError) as exc:
                row["reason"]=str(exc)[:160]
            persist()
    onsets=[x.get("onset",{}).get("status") for x in out["cases"]]
    all_processes=[x.get(key) for x in out["cases"] for key in ("recordPID","reopenPID")]
    out["status"]={"journalReopen":"PASS" if all(x["journal"]=="PASS" for x in out["cases"]) else "UNKNOWN",
                   "onsetPCM":"FAIL" if "FAIL" in onsets else "PASS" if all(s=="PASS" for s in onsets) else "UNKNOWN",
                   "distinctColdProcesses":len({p for p in all_processes if p}),
                   "wholePCMByteIdenticalCases":sum(x.get("pcm",{}).get("identical",False) for x in out["cases"]),
                   "actualASRScored":sum(x["utteranceAccuracy"] in ("PASS","FAIL") for x in out["cases"])}
    persist()


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("output",type=Path);args=parser.parse_args();run(args.output.resolve())
