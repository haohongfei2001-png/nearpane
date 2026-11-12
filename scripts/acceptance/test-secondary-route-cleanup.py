"""Exercise the route supervisor's rollback using only temporary receipts and scope samples."""

import datetime as dt
import importlib.util
import json
import runpy
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("route", SCRIPTS / "secondary-overview" / "run-route.py")
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)
fixtures = runpy.run_path(str(SCRIPTS / "test-secondary-provision.py"))
SECONDARY, pair = fixtures["SECONDARY"], fixtures["pair"]


def write(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


class RouteCleanup(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.prior = root / "build/verification/secondary-route-followup" / str(uuid.uuid4())
        self.prior.mkdir(mode=0o700, parents=True)
        self.ledger = self.prior / "provision"
        self.ledger.mkdir(mode=0o700)
        self.intent = {"operation": str(uuid.uuid4()), "display": SECONDARY, "source": "10"}
        write(self.ledger / "create-intent.json", self.intent)
        write(self.ledger / "created.json", {"intent": self.intent, "target": "11"})
        write(self.prior / "stopped.json", {"reason": "fixture stopped before route"})
        armed = dict(event="externalFocusArmed", observer=12, run=str(uuid.uuid4()), originalPID=1, originalWindow=2)
        cleanup = dict(event="cleanup", originalWindow=2, windowAbsent=True, originalPointer=True,
                       overviewDismissed=True, scopesMatchVerifiedOperation=True, verifiedSpaceMutations=1)
        exited = dict(armed, event="externalAfterExit", childExited=True,
                      sameAXObjectFocusedAfterExit=True, originalIdentityAndGeometry=True)
        self.creation_receipts = self.prior / "create.jsonl"
        self.creation_receipts.write_text("\n".join(map(json.dumps, (armed, cleanup, exited))))
        for tag, offset, records in (("origin", 1, ["10"]), ("added", 3, ["10", "11"])):
            for i, sample in enumerate(pair(offset, records, records), 1):
                write(self.prior / f"{tag}-{i}.json", sample)

        root_patch = patch.object(route, "ROOT", root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        when = dt.datetime(2026, 11, 13, 2, tzinfo=dt.timezone.utc)
        with patch.object(route, "utcnow", return_value=when), patch("builtins.print"):
            self.session = route.Session(SimpleNamespace(
                starts=when.strftime(route.STAMP), ends=(when + dt.timedelta(minutes=3)).strftime(route.STAMP),
                existing_target=None, display=SECONDARY, source="10", cleanup_run=self.prior, witness=root,
            ))
        self.live = {"current": pair(5, ["10", "11"], ["10", "11"]), "restored": pair(7, ["10"], ["10"])}
        self.session.verify_kit = Mock()
        self.session.pair = Mock(side_effect=self.live.__getitem__)
        self.session.panel = Mock()

    def record_route(self, *, completed=False, pending="none", pointer=True):
        (self.prior / "witness.log").touch()
        witness = self.prior / "witness"
        witness.mkdir()
        if completed:
            write(witness / "completed.json", {"observedRoundTrips": 3})
            write(witness / "after-cleanup.json", {})
            write(witness / "restored-focus.json", {"sameAXFocus": "true"})
        else:
            write(witness / "stopped.json", dict(pendingInput=pending, scopeReturn="verified",
                                                 focusReturn="verified", cleanup="verified"))
        if pointer is not None:
            write(self.prior / "pointer-exit.json", {"returned": pointer, "exit": 0 if pointer else 2})

    def assert_cleanup(self):
        self.session.recover_prepared(self.prior)
        self.session.panel.assert_called_once_with("remove")
        self.assertEqual(self.session.ledger, self.ledger)
        receipt = route.read(self.session.out / "cleanup-complete.json")
        self.assertEqual(receipt, dict(originalTrial=self.prior.name, source="10", target="11",
                                       restored=True, roundTripsPerformed=0))
        self.assertEqual(route.read(self.prior / "recovery-attempt.json")["target"], "11")

    def assert_refusal(self, error):
        with self.assertRaisesRegex((ValueError, OSError), error):
            self.session.recover_prepared(self.prior)
        self.session.panel.assert_not_called()
        self.assertFalse((self.session.out / "cleanup-complete.json").exists())

    def test_cleanup_from_original_paired_receipts(self):
        self.assert_cleanup()

    def test_failed_pointer_return(self):
        self.record_route(pointer=False)
        self.assert_refusal("pointer return")

    def test_missing_pointer_receipt(self):
        self.record_route(pointer=None)
        self.assert_refusal("pointer-exit.json")

    def test_unconfirmed_route_input(self):
        self.record_route(pending="inflight")
        self.assert_refusal("safe stop")

    def test_verified_safe_stop(self):
        self.record_route()
        self.assert_cleanup()

    def test_verified_round_trip(self):
        self.record_route(completed=True)
        self.assert_cleanup()

    def test_remove_intent_already_exists(self):
        write(self.ledger / "remove-intent.json", {})
        self.assert_refusal("removal already attempted")

    def test_recovery_attempt_already_exists(self):
        write(self.prior / "recovery-attempt.json", {})
        self.assert_refusal("cleanup already attempted")

    def test_missing_focus_observer(self):
        self.creation_receipts.write_text("")
        self.assert_refusal("externalFocusArmed")

    def test_missing_second_original_sample(self):
        (self.prior / "added-2.json").unlink()
        self.assert_refusal("creation-readback")

    def test_current_target_changed(self):
        self.live["current"][1]["scopes"][1]["records"][1]["id"] = "12"
        self.assert_refusal("inconsistent current or ordinary record order")

    def test_created_target_mismatches_samples(self):
        write(self.ledger / "created.json", {"intent": self.intent, "target": "12"})
        self.assert_refusal("adjacent created desktop not confirmed")


if __name__ == "__main__":
    unittest.main()
