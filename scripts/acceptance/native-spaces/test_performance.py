import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import Mock, patch

from performance import arrival_distribution, matched_terminal, run, warmed_cpu_percent
from space_scope import ScopeError


class ArrivalDistributionTests(unittest.TestCase):
    def rows(self, product):
        rows = []
        for index in range(120 if product else 20):
            batch, i = divmod(index, 20)
            source, target = (6, 7) if i % 2 == 0 else (7, 6)
            t0 = 1 + index * 2
            delay = 1.5 if product and batch == 0 else .5 if not product else (index - 19) / 1000
            row = dict(ordinal=i+1, source=source, target=target, actual=target, t0=t0,
                       tArrival=t0+delay, status="PASS")
            if product:
                row.update(batch=batch, hostOperation=str(uuid.UUID(int=index+1)), tIssued=t0+.0002,
                           hostConfirmed=t0+.0005, tHighlight=t0+delay+.05,
                           dispatch=[dict(source=source, target=target, axError=0, tPress=t0)])
            rows.append(row)
        return rows

    def test_first_batch_excluded_and_exactly_five_complete_batches_required(self):
        rows = self.rows(True)
        result = arrival_distribution(rows, product=True)
        for percentile in (50, 95, 99):
            self.assertAlmostEqual(result[f"p{percentile}ms"], percentile)
        for invalid in [rows[:-1], rows[1:], rows + [rows[-1]], rows + [dict(rows[0], status="FAIL")],
                        rows[:1]+[rows[0]]+rows[2:], rows[:-1] + [dict(rows[-1], batch=3)],
                        rows[:-1] + [dict(rows[-1], status="UNKNOWN")], rows[1::-1] + rows[2:],
                        rows[:-1] + [dict(rows[-1], tArrival=-1)], rows[:-1] + [dict(rows[-1], dispatch=[])],
                        rows[:-1] + [dict(rows[-1], hostOperation=rows[0]["hostOperation"])],
                        rows[:-1] + [dict(rows[-1], tIssued=None)], rows[:-1] + [dict(rows[-1], actual=99)],
                        rows[:-1] + [dict(rows[-1], t0=0)], rows[:-1] + [dict(rows[-1], source=175)],
                        rows[:-1] + [dict(rows[-1], tHighlight=rows[-1]["t0"]-.01)],
                        rows[:-1] + [dict(rows[-1], t0=rows[-1]["t0"]-.01)]]:
            self.assertIsNone(arrival_distribution(invalid, product=True)["p95ms"])

    def test_native_requires_twenty_actual_readbacks(self):
        rows = self.rows(False)
        self.assertEqual(arrival_distribution(rows, product=False)["p99ms"], 500)
        for change in ({"tArrival": float("nan")}, {"actual": 8}, {"source": rows[0]["target"]}):
            altered = [dict(rows[0], **change)] + rows[1:]
            self.assertIsNone(arrival_distribution(altered, product=False)["p50ms"])

    def test_receipt_requires_the_exact_three_phase_host_operation_and_fixture(self):
        display, a, b, ident = (str(uuid.uuid4()).upper() for _ in range(4))
        window = dict(pid=701,birth=11,number=34)
        scope = dict(display=display, spaces=[dict(id=6,uuid=a),dict(id=7,uuid=b)], witnesses=[dict(**window,space=7)])
        intent = dict(id=ident,action="select",display=display,source="6",target="7",sourceUUID=a,targetUUID=b,
                      window=window,createdAtUptime=100.011)
        result = dict(id=ident,state="confirmed",submittedSteps=1,issuedAtUptime=100.02,confirmedAtUptime=101.1,
                      currentBefore={display:"6"},currentAfter={display:"7"},
                      switchTrace=dict(adapter=27,phasesMachTicks=[30,40,60],observations=[dict(currents={display:"7"})]))
        trial = dict(source=6,target=7,dispatch=[dict(tPress=100.01)])
        path = Path(ident+".json")
        def proof(i, r):
            return matched_terminal(dict(intent=i,result=r),path,scope,trial)
        self.assertEqual(proof(intent,result)["operation"],ident)
        for i,r in [(dict(intent,targetUUID=a),result), (dict(intent,createdAtUptime=99),result),
                    (dict(intent,window=dict(window,birth=12)),result), (intent,dict(result,state="outcomeUnknown")),
                    (intent,dict(result,switchTrace=dict(result["switchTrace"],phasesMachTicks=[20,20,60])))]:
            with self.assertRaises(ValueError):
                proof(i,r)

    def test_real_gate_precedes_any_system_or_product_action(self):
        workspace = Mock(spec=["read", "select"])
        with tempfile.TemporaryDirectory() as folder, patch("performance.native_capabilities",
                return_value=[{"ready": True, "canSwitch": False, "canMove": False}]):
            result = run(workspace=workspace, scope={"spaces": [{"id": 6},{"id": 7},{"id": 8}], "host": {"pid": 701}},
                         observer="absent", driver="absent", output=Path(folder)/"result")
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual((result["native"], result["product"], result["memorySamples"]), ([], [], []))
        self.assertIsNone(result["productObservedArrival"]["p95ms"])
        workspace.read.assert_not_called()
        workspace.select.assert_not_called()

    def test_process_tree_cannot_mask_replacement_reparenting_or_a_counter_rollback(self):
        def sample(when, a, b, **edits):
            row = dict(pid=21, parent=18, birthSec=11, birthUsec=3, cpuUserNs=a, cpuSystemNs=10)
            child = dict(pid=22, parent=21, birthSec=12, birthUsec=8, cpuUserNs=b, cpuSystemNs=20)
            child.update(edits)
            return {"monotonic": when, "processes": [row, child]}
        first = sample(10, 100, 90)
        self.assertEqual(warmed_cpu_percent(first, sample(11, 100_000_100, 100_000_090)), 20)
        for altered in [sample(11, 100_000_100, 80), sample(11, 200, 100, parent=19),
                        sample(11, 200, 100, birthUsec=7), sample(10, 200, 100)]:
            with self.assertRaises(ScopeError):
                warmed_cpu_percent(first, altered)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin kernel counter")
    def test_kernel_cpu_units_agree_with_this_test_process_mach_clock(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp)/"footprint"
            subprocess.run(["xcrun","clang","-Wall","-Werror",Path(__file__).with_name("footprint.c"),"-o",binary], check=True)
            def read():
                values = list(map(int,subprocess.check_output([binary,str(os.getpid())]).split()))
                self.assertEqual((len(values), values[0], values[1]), (7, os.getpid(), os.getppid()))
                self.assertGreater(values[4], 0)
                return values
            first = read()
            start = time.process_time()
            while time.process_time() - start < .25:
                sum(i*i for i in range(1000))
            elapsed = time.process_time() - start
            last = read()
            self.assertEqual(first[:4], last[:4])
            self.assertLess(abs((sum(last[5:]) - sum(first[5:])) / 1e9 - elapsed), .025)


if __name__ == "__main__":
    unittest.main()
