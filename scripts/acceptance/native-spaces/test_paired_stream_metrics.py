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
