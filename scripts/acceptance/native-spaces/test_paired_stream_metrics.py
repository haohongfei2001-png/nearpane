import json
import tempfile
import subprocess
import sys
import unittest
from pathlib import Path

from paired_stream_metrics import qualified,metrics,integrate


def scenario(pts_only=False,unknown=False):
    sample=lambda doc,epoch:dict(color=f"{doc}/{epoch}",median=[100+epoch,40+doc,60,255],minimum=[95,38,55,255],maximum=[113,42,65,255],dominantFraction=1.0)
    records=[]
    for k in range(210):
        t=100.05+k/60
        for c in range(3):
            epoch=min(6,max(0,(k-(3 if c==2 else 0))//27))
            values=[sample(c,epoch)] if c<2 else [sample(0,epoch),sample(1,epoch)]
            if unknown and c==2 and epoch==3:values[0]["color"]="unknown";values[0]["median"]=[190,70,35,255]
            records.append(dict(channel=c,sequence=k+1,status=0,callback=t+.008,displayTime=None if pts_only else t,pts=t,hostPTS=t,
                                samples=values,offsets=[-1]*len(values)))
    guards=[dict(time=100+i/5,fullBinding=i in (0,9,19),valid=True,cardKinds=[]) for i in range(20)]
    clock=dict(uptime=100,uncertainty=.000001,machOffset=0,hostOffset=0)
    return records,dict(clocks=[clock,dict(clock,uptime=103.8)],guards=guards,stopped=[True]*3)

class StreamTiming(unittest.TestCase):
    def test_exact_display_clock_recovers_all_transitions_and_intervals_contain_true_delay(self):
        f,s=scenario();streams,c=qualified(f,s);r=metrics(streams,c,s)
        self.assertEqual(r["status"],"PASS");self.assertEqual(r["latencyMs"]["n"],12)
        self.assertAlmostEqual(r["latencyMs"]["firstConfirmedPresentationDifference"]["p50"],50,places=1)
        bounds=r["windows"][0]["events"][0]["latencyMs"];self.assertLess(bounds[0],50);self.assertGreater(bounds[1],50)
        self.assertTrue(all(e["twoConsecutive"] for e in r["simultaneous"]))

    def test_uncorrelated_pts_or_unrecognized_color_never_proves_ms_latency(self):
        f,s=scenario(pts_only=True);streams,c=qualified(f,s);r=metrics(streams,c,s)
        self.assertEqual(r["latencyMs"]["n"],0);self.assertEqual(r["status"],"INCONCLUSIVE")
        f,s=scenario(unknown=True);streams,c=qualified(f,s);r=metrics(streams,c,s)
        self.assertEqual(r["windows"][0]["events"][2]["outcome"],"UNKNOWN")
        self.assertEqual(r["windows"][0]["events"][2]["observedRGBA"]["card"],[190,70,35,255])

    def test_supported_early_display_is_bracketed_at_both_callback_and_presentation(self):
        frames, session = scenario()
        for clock in session["clocks"]:
            clock["frameTimingVersion"] = 2
        for f in frames:
            if f["channel"] == 2:
                f["callback"] = f["displayTime"] - .013
        streams, clock = qualified(frames, session)
        result = metrics(streams, clock, session)
        self.assertEqual(result["latencyMs"]["n"], 12)
        self.assertAlmostEqual(result["latencyMs"]["firstConfirmedPresentationDifference"]["p50"], 50, places=1)
        self.assertEqual(clock["prePresentationCallbacks"]["qualifiedCount"], [0, 0, 210])

        frame = dict(frames[2], callback=100.191, displayTime=100.204, hostPTS=100.204001)
        start, end = session["guards"][0], session["guards"][-1]
        session["guards"] = [start, dict(start, time=100.198, valid=False, fullBinding=False),
                             dict(start, time=100.200, fullBinding=False), end]
        self.assertEqual(qualified([frame], session)[1]["rejected"], {"unbracketedScope": 1})
        session["guards"] = [start, end]
        end["time"] = 100.201
        self.assertEqual(qualified([frame], session)[1]["rejected"], {"unbracketedScope": 1})
        end["time"] = 100.5
        invalid = [dict(frame, displayTime=None), dict(frame, hostPTS=100.208), dict(frame, hostPTS=None),
                   dict(frame, callback=100.180), dict(frame, displayTime=100.220, hostPTS=100.190)]
        self.assertEqual(qualified(invalid, session)[1]["rejected"], {"outOfBoundsOrUncorroboratedPresentation": 5})

    def test_an_observed_current_target_without_the_previous_color_has_unknown_latency(self):
        frames, session = scenario(unknown=True)
        for clock in session["clocks"]:
            clock["frameTimingVersion"] = 2
        series, clock = qualified(frames, session)
        event = metrics(series, clock, session)["windows"][0]["events"][3]
        self.assertEqual(event["outcome"], "UNKNOWN")
        self.assertEqual(event["reason"], "currentColorObservedWithoutBoundedPrecedingTransition")
        self.assertNotIn("latencyMs", event)
        for row in frames:
            if row["channel"] == 2 and row["samples"][0]["color"] == "0/4":
                row["samples"][0]["color"] = "0/2"
        series, clock = qualified(frames, session)
        self.assertEqual(metrics(series, clock, session)["windows"][0]["events"][3]["outcome"], "STALE")

    def test_archived_json_roundtrip_replays_the_exact_report(self):
        f,s=scenario()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            stats,_,_,info=integrate([{"streamFrame":x} for x in f]+[{"streamSession":s}],root,root,{})
            (root/"result.json").write_text(json.dumps({"metrics":stats,"presentation":info}))
            run=subprocess.run([sys.executable,Path(__file__).with_name("paired_stream_metrics.py"),root],capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout)["status"],"REPLAY_MATCH")

    def test_invalid_bracket_retains_numeric_status_without_pixels_and_partial_run_stays_unfinished(self):
        frames,s=scenario();s["guards"][3]["valid"]=False;s["stopped"]=[False]*3;s["reason"]="input"
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);events=[{"streamFrame":f} for f in frames]+[{"streamSession":s}]
            stats,_,aux,info=integrate(events,root,root,{})
            rows=[json.loads(x) for x in (root/info["frames"]).read_text().splitlines()]
            self.assertTrue(any(x.get("pixelStatisticsWithheld") and x["samples"]==[] for x in rows))
            self.assertTrue(any(x["qualified"] for x in rows));self.assertNotEqual(stats["status"],"PASS")
            self.assertFalse(any("completedBatches" in x for x in aux))
