import copy
import unittest

from five_preview_metrics import expected_colors, measure_batch, phase_result, overall


class FiveCardEvidence(unittest.TestCase):
    def setUp(self):
        self.run = {"owners":[{"slot":i,"pid":101+i,"birth":901+i,"number":501+i} for i in range(5)]}
        self.hardware = [0,1,0,2,0]

    def sample(self, step=1, stamp=0):
        a = lambda color: dict(color=color,start=stamp,end=stamp+.03,displayTime=stamp+.02,frameStatus=0)
        return dict(ready=True, run=self.run, hardware=self.hardware, onePanelSampleBuffer=True, savedPixels=0,
                    geometry={"panel":999,"pictures":[[50,10*i,4,4] for i in range(5)],"sources":[[60,i*30,4,4] for i in range(5)]},
                    kindsBefore=["窗口画面"]*5,kindsAfter=["窗口画面"]*5,
                    sources=[a(s) for s in expected_colors(step)],cards=[a(s) for s in expected_colors(step)])

    def verdict(self, b, step=1):
        return measure_batch(b,step,self.run,self.hardware)

    def observed(self, b, step=1):
        return {"batch":b,"verdicts":self.verdict(b,step)}

    def test_one_live_card_explicit_four_outlines(self):
        a,b = self.sample(),self.sample(stamp=1)
        for v in (a,b):
            for i in range(1,5):
                v["cards"][i]["color"]="blank"
                v["kindsBefore"][i]=v["kindsAfter"][i]="窗口轮廓"
        pair=[self.observed(a),self.observed(b)]
        self.assertEqual(phase_result(pair, False), ["PASS"]+["UNKNOWN"]*4)
        self.assertEqual(phase_result(pair, True), ["PASS"]+["FAIL"]*4)

    def test_swapped_sources_and_cards_require_exact_slot(self):
        v=self.sample()
        v["cards"][2],v["cards"][3]=v["cards"][3],v["cards"][2]
        self.assertEqual(self.verdict(v),["MATCH","MATCH","MISMATCH","MISMATCH","MATCH"])
        v["sources"][2],v["sources"][3]=v["sources"][3],v["sources"][2]
        self.assertEqual(self.verdict(v)[2:4],["UNKNOWN","UNKNOWN"])

    def test_cached_or_static_picture_does_not_pass_change(self):
        v=self.sample()
        v["cards"][0]["color"]="0/0"
        v["kindsBefore"][1]=v["kindsAfter"][1]="上次画面"
        self.assertEqual(self.verdict(v)[:2],["MISMATCH","MISMATCH"])

    def test_geometry_and_frame_continuity_cannot_be_substituted(self):
        for field,bad in (("ready",False),("onePanelSampleBuffer",False),("savedPixels",64),
                          ("hardware",[7]),("geometry",{}),("run",{"owners":[]}),("cards",[])):
            with self.subTest(field=field):
                v=self.sample();v[field]=bad
                self.assertEqual(self.verdict(v),["UNKNOWN"]*5)
        v=self.sample()
        v["cards"][2]["displayTime"]+=.016
        self.assertEqual(self.verdict(v),["UNKNOWN"]*5)
        a=self.observed(self.sample())
        self.assertEqual(phase_result([a,copy.deepcopy(a)], True),["UNKNOWN"]*5)

    def test_no_op_order_never_proves_six_phases(self):
        self.assertEqual(len(set(expected_colors(0)+expected_colors(5))),10)
        for step in range(1,6):
            self.assertEqual([i for i,(l,r) in enumerate(zip(expected_colors(step-1),expected_colors(step))) if l!=r],[step-1])
        incomplete=[{"bySlot":["PASS"]*5} for _ in range(5)]
        self.assertEqual(overall(incomplete),(["UNKNOWN"]*5,"UNKNOWN"))
        phases=[]
        for step in range(6):
            result=phase_result([self.observed(self.sample(step,step*2),step),
                                 self.observed(self.sample(step,step*2+1),step)],False)
            phases.append({"step":step,"bySlot":result})
        self.assertEqual(overall(phases),(["PASS"]*5,"PASS"))
        self.assertEqual(overall([phases[0]]*6),(["UNKNOWN"]*5,"UNKNOWN"))
        phases[2]={"step":2,"bySlot":["PASS","UNKNOWN","PASS","FAIL","PASS"]}
        self.assertEqual(overall(phases),(["PASS","UNKNOWN","PASS","FAIL","PASS"],"FAIL"))

    def test_missing_source_and_undecodable_card_are_unknown(self):
        v=self.sample();v["sources"][3]["color"]="unknown";v["cards"][4]["color"]="unknown"
        self.assertEqual(self.verdict(v),["MATCH","MATCH","MATCH","UNKNOWN","UNKNOWN"])


if __name__=="__main__":
    unittest.main()
