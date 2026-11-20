import unittest
from performance import arrival_distribution


class ArrivalDistributionTests(unittest.TestCase):
    def test_first_batch_excluded_and_exactly_five_complete_batches_required(self):
        rows = [dict(batch=batch, t0=0, tArrival=(1000 if batch == 0 else (batch-1)*20+i+1),
                     status="PASS") for batch in range(6) for i in range(20)]
        result = arrival_distribution(rows, product=True)
        self.assertEqual((result["p50ms"], result["p95ms"], result["p99ms"]), (50000,95000,99000))
        for invalid in [rows[:-1], rows[1:], rows + [rows[-1]], rows[:-1] + [dict(rows[-1], batch=3)],
                        rows[:-1] + [dict(rows[-1], status="UNKNOWN")], rows[:-1] + [dict(rows[-1], tArrival=-1)]]:
            self.assertIsNone(arrival_distribution(invalid, product=True)["p95ms"])

    def test_native_requires_twenty_actual_readbacks(self):
        rows = [dict(t0=5,tArrival=5.5,status="PASS") for _ in range(20)]
        self.assertEqual(arrival_distribution(rows, product=False)["p99ms"], 500)
        rows[0]["tArrival"] = float("nan")
        self.assertIsNone(arrival_distribution(rows, product=False)["p50ms"])
