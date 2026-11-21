import unittest
from unittest.mock import Mock, patch

from lease_visit import after_daily, ScopeError


HOST = dict(pid=18,birth=670,cdhash="a"*40)


def view(uptime, pid=18, birth=670, *, exact=False, bound=True, window=42, space=4):
    return dict(current=space,originExact=exact,originBound=bound,
                systemFocus=dict(pid=pid,birth=birth,number=window),uptime=uptime)


class Reader:
    def __init__(self, samples, reply=None, daily=True):
        self.samples=iter(samples);self.reply=reply;self.daily=daily;self.requests=[];self.closed=False
    def read(self,r):
        if r["command"]=="restoreDaily":
            self.requests.append(r)
            if isinstance(self.reply,Exception):raise self.reply
            return self.reply
        value=next(self.samples)
        if isinstance(value,Exception):raise value
        return value
    def close(self):self.closed=True


class RestoredDailyTests(unittest.TestCase):
    def run_case(self,r,host=HOST,qualify=None):
        with patch("lease_visit.time.sleep"):
            result=after_daily(r,host,qualify or (lambda:True))
        self.assertTrue(r.closed)
        return result

    def test_passive_return_keeps_original_exact_and_posts_nothing(self):
        r=Reader([view(1,39,400,exact=True),view(1.2,39,400,exact=True)])
        out=self.run_case(r)
        self.assertEqual((out["status"],out["issued"],r.requests),("PASS",False,[]))
        self.assertEqual(out["uptimes"],[1,1.2])

    def test_only_reopened_host_can_yield_once_to_the_original_retained_window(self):
        r=Reader([view(1),view(1.2),view(2),view(2.2,39,400,exact=True),view(2.4,39,400,exact=True)],
                 {"issued":True,"accepted":True})
        gate=Mock(return_value=True)
        out=self.run_case(r,qualify=gate)
        self.assertEqual((out["status"],out["issued"],out["originalReferenceMatchedTwice"]),("PASS",True,True))
        self.assertEqual(len(r.requests),1);self.assertEqual(gate.call_count,2)

    def test_reused_pid_changed_foreground_new_input_and_missing_original_never_post(self):
        for readings in ([view(1),view(1.2,birth=671)], [view(1),view(1.2,pid=20)],
                         [view(1),view(1.2,bound=False)],[view(1),view(1.2,window=43)],
                         [view(1),view(1.2,space=6)],[ScopeError("newHumanInput")]):
            r=Reader(readings)
            out=self.run_case(r)
            self.assertIn(out["status"],("BLOCKED","UNKNOWN"));self.assertIs(out["issued"],False);self.assertFalse(r.requests)

    def test_retired_reader_or_unverified_daily_writer_lock_cannot_restore(self):
        r=Reader([view(1),view(1.2)])
        self.assertEqual(self.run_case(r,qualify=lambda:False)["issued"],False); self.assertFalse(r.requests)
        for host,cap in ((None,True),(HOST,False)):
            r=Reader([view(1),view(1.2)],daily=cap)
            self.assertIs(self.run_case(r,host=host)["issued"],False);self.assertFalse(r.requests)
        self.assertFalse(after_daily(None)["originalReferenceRetained"])

    def test_rejected_lost_or_superseded_activation_never_repeats(self):
        for reply,samples,issued in (({"issued":False,"reason":"originalAppWouldActivateAnotherWindow"},[],False),
                                     (ScopeError("retainedReaderTimeout"),[],None),
                                     ({"issued":True,"accepted":False},[],True),
                                     ({"issued":True,"accepted":True},[view(2,pid=22)],True),
                                     ({"issued":True,"accepted":True},[ScopeError("newHumanInput")],True)):
            r=Reader([view(1),view(1.2),*samples],reply)
            out=self.run_case(r)
            self.assertNotEqual(out["status"],"PASS");self.assertIs(out["issued"],issued);self.assertEqual(len(r.requests),1)


if __name__=="__main__":unittest.main()
