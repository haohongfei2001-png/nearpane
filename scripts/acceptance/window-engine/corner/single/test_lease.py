"""Offline admission/receipt regressions; do not create a macOS application or query the GUI."""
from copy import deepcopy
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

spec = spec_from_file_location("physical_lease", Path(__file__).resolve().parents[1] / "physical-lease.py")
lease = module_from_spec(spec)
spec.loader.exec_module(lease)


class LeaseTests(unittest.TestCase):
    def setUp(self):
        preflight = dict.fromkeys(("signed", "launchdParent", "ownResponsibilitySubject", "console", "accessibilityAlreadyGranted",
                                   "postEventAlreadyGranted", "stableFocus", "stableHID14", "stablePhysicalScope"), True)
        scope = {"display": "D", "space": "S", "native": 4}
        self.pre = [{"event": "scope1", "scope": scope}, {"event": "scope2", "scope": scope},
                    dict(event="preflight", stage="OFF", secureInput=False, blockingReasons=[], **preflight)]
        self.terminal = dict(event="terminal", mode="preflight", status="PASS", qualification="UNQUALIFIED", fullCycle="NOT_RUN",
                             preflightPassed=True, windowRequested=False, globalEventsPosted=0, preferenceWrites=0, thirdPartyWindowWrites=0)
        self.complete = self.pre[:]
        for phase in ("admission", "original", "original", "parked", "parked", "restored", "restored"):
            self.complete.append(dict(event="ownedWindow", window=19, phase=phase, exactOwnedWindow=True, listedWithZeroAlpha=True))
        self.complete.extend([dict(event="submitted", operation=3), dict(event="submitted", operation=5)])
        for operation, flags, owned in [(2,45,0),(2,45,0),(6,80,0),(3,190,1),(2,190,1),(2,190,1),(5,45,0),(2,45,0),(2,45,0)]:
            self.complete.append(dict(event="engine",operation=operation,flags=flags,owned=owned,status=0))
        self.complete.append(dict(self.terminal, mode="run", windowRequested=True, engineClose=0, parkSubmitted=True,
                                  restoreSubmitted=True, originalGeometryRestored=True, fixtureExited=True, ownedWindowGone=True,
                                  externalExactFocusPreserved=True, originalHIDUnchanged=True, originalDisplaySpacePreserved=True))

    def test_missing_access_is_never_promoted(self):
        rows = deepcopy(self.pre)
        rows[-1]["accessibilityAlreadyGranted"] = False
        denied = dict(self.terminal, status="BLOCKED", reason="preflightNotAdmitted", preflightPassed=False)
        self.assertEqual(lease.verified_terminal("preflight", rows + [denied])["status"], "BLOCKED")
        with self.assertRaises(ValueError): lease.verified_terminal("preflight", rows + [self.terminal])

    def test_preflight_makes_no_window_and_requires_own_tcc_subject(self):
        self.assertEqual(lease.verified_terminal("preflight", self.pre + [self.terminal]), self.terminal)
        for change in ({"ownResponsibilitySubject":False},{"stage":"ON"},{"stableFocus":False}):
            rows = deepcopy(self.pre)
            rows[-1].update(change)
            with self.assertRaises(ValueError): lease.verified_terminal("preflight",rows + [self.terminal])
        with self.assertRaises(ValueError): lease.verified_terminal("preflight",self.pre + [dict(self.terminal,windowRequested=True)])

    def test_root_cannot_verify_incomplete_or_retried_geometry(self):
        self.assertEqual(lease.verified_terminal("run",self.complete)["qualification"],"UNQUALIFIED")
        for index in (3,5,7,9,11,17):
            with self.assertRaises(ValueError): lease.verified_terminal("run",self.complete[:index] + self.complete[index+1:])
        with self.assertRaises(ValueError): lease.verified_terminal("run",self.complete[:-1] + [{"event":"submitted","operation":3},self.complete[-1]])

    def test_other_window_new_input_or_visible_substitute_fails_closed(self):
        for index,key,value in [(6,"window",20),(8,"listedWithZeroAlpha",False),(-1,"originalHIDUnchanged",False),
                                (-1,"externalExactFocusPreserved",False),(-1,"ownedWindowGone",False),(-1,"fullCycle","PASS")]:
            rows = deepcopy(self.complete)
            rows[index][key] = value
            with self.assertRaises(ValueError): lease.verified_terminal("run",rows)
        changed = deepcopy(self.complete)
        changed[1]["scope"] = {"display":"D","space":"T","native":6}
        with self.assertRaises(ValueError): lease.verified_terminal("run",changed)
