import unittest

from overview_system_events import activation_chain, decode, join_clock, time_window


class OverviewSystemEvents(unittest.TestCase):
    def test_observed_transition_does_not_name_its_requester(self):
        front = dict(kind="setFront", targetPID=7, previousPID=3, pid=392, mach=300, unix=10.1)
        self.assertEqual(activation_chain([front], 3), dict(status="UNKNOWN", confirmedForegroundTransitions=1, matchedRequestChains=0))
        send = dict(kind="activationSent", returnID=41, pid=8, mach=100, unix=10.0)
        recv = dict(kind="activationReceived", returnID=41, pid=7, mach=200, unix=10.05)
        linked = activation_chain([send,recv,front], 3)
        self.assertEqual((linked["status"], linked["candidateSenderPID"]), ("UNKNOWN", 8))
        self.assertEqual(activation_chain([send,dict(send,pid=9),recv,front],3)["matchedRequestChains"],0)

    def test_join_requires_agreement_at_both_ends_and_checks_continuous_time(self):
        first = dict(numer=1,denom=1,uptime=50,unix=150,machAbsolute=50_000_000_000,machContinuous=80_000_000_000)
        last = dict(first,uptime=52,unix=152,machAbsolute=52_000_000_000,machContinuous=82_000_000_000)
        report = dict(clockStart=first,clockEnd=last)
        row = dict(unix=151,mach=81_000_000_000)
        self.assertEqual(join_clock(row,report),dict(clockStatus="machContinuous",uptime=51))
        self.assertEqual(join_clock(row,dict(report,clockEnd=dict(last,unix=154)))["clockStatus"],"wallUptimeDiscontinuity")
        self.assertEqual(join_clock(dict(row,mach=10),report)["clockStatus"],"clockDomainUnverified")
        self.assertIsNone(time_window(dict(measurement=dict(presentations=0))))

    def test_only_the_enrolled_window_identity_survives_projection(self):
        event = dict(processImagePath="/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager",
                     formatString="%x[%s]: space %d remove window %x", eventMessage="12[system]: space 4 remove window ff")
        self.assertEqual(decode(event,{255}),dict(kind="trackedWindowRemove",space=4,window=255))
        self.assertIsNone(decode(event,{411}))
        self.assertIsNone(decode(dict(event,formatString="Other",eventMessage="unrelated private text"),{255}))
