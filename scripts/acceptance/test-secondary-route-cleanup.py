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


class PresentationGrant(unittest.TestCase):
    def test_permission_is_local_to_the_current_invocation(self):
        session = route.Session.__new__(route.Session)
        session.args = SimpleNamespace(allow_primary_overview=False, ends="2026-11-12T20:56:45Z")
        key = "NEARPANE_PRIMARY_OVERVIEW_UNTIL"
        with patch.dict(route.os.environ, {key: "an earlier grant"}):
            self.assertNotIn(key, session.panel_environment())
            session.args.allow_primary_overview = True
            self.assertEqual(session.panel_environment()[key], session.args.ends)


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

    def test_create_helper_deadline_reserves_route_readbacks_and_cleanup(self):
        s = self.session
        s.args.kit = self.prior
        s.args.allow_primary_overview = True
        reserve = route.MIN_ROUTE_SECONDS + route.CLEANUP_SECONDS + route.ADDED_READBACK_SECONDS
        cutoff = s.end - dt.timedelta(seconds=reserve)
        with patch.object(route, "utcnow", return_value=cutoff - dt.timedelta(seconds=30)), patch.object(route.sp, "run") as run:
            with self.assertRaisesRegex(ValueError, "insufficient time"):
                route.Session.panel(s, "create")
            run.assert_not_called()
        with patch.object(route, "utcnow", return_value=cutoff - dt.timedelta(seconds=31)), patch.object(route.sp, "run") as run:
            route.Session.panel(s, "create")
            self.assertEqual(run.call_args.args[0][4], cutoff.strftime(route.STAMP))
            self.assertEqual(run.call_args.kwargs["env"]["NEARPANE_PRIMARY_OVERVIEW_UNTIL"], cutoff.strftime(route.STAMP))

    def setup_unlaunched_route(self):
        s = self.session
        s.out, s.ledger = self.prior, self.ledger
        s.primary, s.secondary, s.a, s.b = fixtures["PRIMARY"], SECONDARY, "10", None
        s.origin = pair(1, ["10"], ["10"])
        s.setup = Mock()
        self.live.update(added=pair(3, ["10", "11"], ["10", "11"]),
                         **{"before-remove": self.live["current"]})
        return s

    def test_pre_spawn_expiration_cleans_created_target_only_after_new_proof(self):
        s = self.setup_unlaunched_route()
        with patch.object(route, "utcnow", return_value=s.end - dt.timedelta(seconds=90)):
            with self.assertRaisesRegex(ValueError, "insufficient time for route"):
                s.execute()
        self.assertEqual([c.args[0] for c in s.panel.call_args_list], ["create", "remove"])
        self.assertFalse((s.out / "complete.json").exists())
        self.assertTrue((s.out / "route-not-started.json").is_file())

    def test_pre_spawn_refusal_with_unknown_original_focus_retains_desktop(self):
        s = self.setup_unlaunched_route()
        self.creation_receipts.write_text("")
        with patch.object(route, "utcnow", return_value=s.end - dt.timedelta(seconds=90)):
            with self.assertRaisesRegex(ValueError, "externalFocusArmed"):
                s.execute()
        s.panel.assert_called_once_with("create")

    def test_failed_pointer_return(self):
        self.record_route(pointer=False)
        self.assert_refusal("pointer return")

    def test_unconfirmed_external_chord_blocks_an_otherwise_safe_stop(self):
        self.record_route()
        write(self.prior / "witness/external-enroll-B-intent.json", {"operation": "one"})
        self.assert_refusal("external calibration outcome unconfirmed")

    def test_external_chord_must_match_endpoint_and_attestation(self):
        self.record_route()
        w = self.prior / "witness"
        intent = dict(operation="one", checkpoint="enroll-B", run="r", target="11")
        for kind in ("intent", "posted", "confirmed"):
            fields = dict(intent, attestationToken="token") if kind == "confirmed" else intent
            write(w / f"external-enroll-B-{kind}.json", fields)
        attested = dict(token="token", run="r", checkpoint="enroll-B", endpoint="10")
        write(w / "attested-enroll-B.json", attested)
        self.assert_refusal("external calibration receipts disagree")
        write(w / "attested-enroll-B.json", dict(attested, endpoint="11"))
        self.assert_cleanup()

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


class RouteLeg(unittest.TestCase):
    def setUp(self):
        self.run = str(uuid.uuid4()).upper()
        operation = str(uuid.uuid4()).upper()
        self.intent = dict(run=self.run, operation=operation, beforeRevision=9,
                           source={"record": "A"}, target={"record": "B"})
        self.posted = {"operation": operation}
        self.confirmed = dict(operation=operation, afterRevision="10")

    def verify(self):
        route.verify_leg(self.intent, self.posted, self.confirmed, self.run, "A", "B")

    def test_frozen_swift_number_to_string_receipts(self):
        self.verify()

    def test_stale_or_malformed_confirmation(self):
        for value in ("9", "010", "１２", "18446744073709551616", 10, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.confirmed["afterRevision"] = value
                self.verify()

    def test_other_run_or_operation_or_direction(self):
        for obj, field, value in ((self.intent, "run", str(uuid.uuid4()).upper()),
                                  (self.posted, "operation", str(uuid.uuid4()).upper()),
                                  (self.intent, "target", {"record": "A"})):
            with self.subTest(field=field), patch.dict(obj, {field: value}), self.assertRaises(ValueError):
                self.verify()


if __name__ == "__main__":
    unittest.main()
