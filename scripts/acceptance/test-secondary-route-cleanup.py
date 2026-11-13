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
    def test_console_is_claimed_across_different_candidate_entry_points(self):
        with tempfile.TemporaryDirectory() as directory:
            trials = Path(directory)
            with route.exclusive_console(trials):
                with self.assertRaisesRegex(ValueError, "another Native Spaces trial"):
                    with route.exclusive_console(trials):
                        self.fail("concurrent trial acquired the console")
            with route.exclusive_console(trials):
                pass

    def test_permission_is_local_to_the_current_invocation(self):
        session = route.Session.__new__(route.Session)
        session.args = SimpleNamespace(allow_primary_overview=False, ends="2026-11-12T20:56:45Z")
        key = "NEARPANE_PRIMARY_OVERVIEW_UNTIL"
        with patch.dict(route.os.environ, {key: "an earlier grant"}):
            self.assertNotIn(key, session.panel_environment())
            session.args.allow_primary_overview = True
            self.assertEqual(session.panel_environment()[key], session.args.ends)


class CurrentDisplayRoute(unittest.TestCase):
    def setUp(self):
        self.session = route.Session.__new__(route.Session)
        self.session.args = SimpleNamespace(display=SECONDARY, source="20", existing_target="19",
            current_display=True, cleanup_run=None, allow_primary_overview=False, provision_current=False)
        self.session.verify_kit = Mock()
        self.sample = dict(displays=[dict(id=SECONDARY)], ordinaryRecordsByDisplay={SECONDARY: ["18", "19", "20"]},
                           scopes=[dict(displayID=SECONDARY, records=[dict(id=i, isCurrent=i=="20") for i in ("18","19","20")])])
        self.session.pair = Mock(return_value=[self.sample, self.sample])

    def test_selects_designated_adjacent_pair_without_touching_previous_desktops(self):
        self.session.setup()
        self.assertEqual((self.session.a, self.session.b), ("20", "19"))
        with self.assertRaisesRegex(ValueError, "cannot be created or removed"):
            self.session.panel("create")

    def test_refuses_nonadjacent_target_or_additional_display(self):
        self.session.args.existing_target = "18"
        with self.assertRaisesRegex(ValueError, "not adjacent"):
            self.session.setup()
        self.session.args.existing_target = "19"
        self.sample["displays"].append(dict(id=fixtures["PRIMARY"]))
        with self.assertRaisesRegex(ValueError, "sole live display"):
            self.session.setup()

    def test_live_source_selector_requires_real_rehearsal_and_rightmost_source(self):
        self.session.args.source = "rightmost-current"
        self.session.args.existing_target = None
        self.session.args.provision_current = True
        with self.assertRaisesRegex(ValueError, "source is not current"):
            self.session.setup()
        self.session.args.check_overview_first = True
        self.session.setup()
        self.assertEqual(self.session.a, "20")
        for row in self.sample["scopes"][0]["records"]:
            row["isCurrent"] = row["id"] == "19"
        with self.assertRaisesRegex(ValueError, "rightmost"):
            self.session.setup()


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

    def test_observe_requires_original_focus_and_zero_desktop_changes(self):
        self.session.setup = Mock()
        self.session.args.check_overview_first = True
        self.session.b = None
        self.session.rounds = Mock()
        log = self.session.out / "observe.jsonl"
        rows = [json.loads(line) for line in self.creation_receipts.read_text().splitlines()]
        for mutations, focused in ((1, True), (0, False)):
            rows[1]["verifiedSpaceMutations"] = mutations
            rows[2]["sameAXObjectFocusedAfterExit"] = focused
            log.write_text("\n".join(map(json.dumps, rows)))
            with self.assertRaisesRegex(ValueError, "post-exit focus"):
                self.session.execute()
            self.session.panel.assert_called_once_with("observe")
            self.session.panel.reset_mock()
            self.session.rounds.assert_not_called()

    def set_sole_display(self):
        self.session.args.current_display = True
        self.session.args.provision_current = False
        self.session.args.allow_primary_overview = False
        self.session.args.kit = self.prior
        def single_pair(offset, order):
            samples = pair(offset, order, order)
            for sample in samples:
                sample["displays"] = sample["displays"][1:]
                sample["displays"][0]["frame"]["x"] = 0
                sample["scopes"] = sample["scopes"][1:]
                del sample["ordinaryRecordsByDisplay"][fixtures["PRIMARY"]]
            return samples
        for tag, offset, order in (("origin", 1, ["9","10"]), ("added", 3, ["9","10","11"])):
            for index, sample in enumerate(single_pair(offset, order), 1):
                write(self.prior / f"{tag}-{index}.json", sample)
        self.live.update(current=single_pair(5, ["9","10","11"]), restored=single_pair(7, ["9","10"]))

    def test_sole_display_cleanup_binds_receipts_and_all_original_desktops(self):
        self.set_sole_display()
        self.assert_cleanup()
        s = self.session
        with patch.object(route, "utcnow", return_value=s.start), patch.object(route.sp, "run") as run:
            route.Session.panel(s, "remove")
            cmd = run.call_args.args[0]
            self.assertEqual(cmd[1:4], ["--current-display", SECONDARY, "10"])
            self.assertEqual(cmd[-2:], ["remove", self.ledger])
            self.assertEqual(run.call_args.kwargs["env"]["NEARPANE_PRIMARY_OVERVIEW_UNTIL"], cmd[5])
            with self.assertRaisesRegex(ValueError, "recovery may only remove"):
                route.Session.panel(s, "create")
            run.assert_called_once()

    def test_sole_display_cleanup_refuses_changed_peer_or_unknown_focus(self):
        self.set_sole_display()
        self.record_route()
        path = self.prior / "witness/stopped.json"
        stopped = route.read(path)
        write(path, dict(stopped, focusReturn="unverified"))
        self.assert_refusal("route did not prove a safe stop")
        write(path, stopped)
        self.live["current"] = pair(5, ["9","10","11"], ["9","10","11"])
        self.assert_refusal("designated displays required")
        self.assertFalse((self.prior / "recovery-attempt.json").exists())

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


class BlankTargetCalibration(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.run = str(uuid.uuid4()).upper()
        self.child = Mock(pid=2345)
        self.child.poll.return_value = None
        self.session = route.Session.__new__(route.Session)
        self.session.primary, self.session.secondary = "main", "side"
        self.session.a, self.session.b = "10", "11"
        self.session.out = self.root
        self.session.args = SimpleNamespace(kit=self.root, witness=self.root)
        self.enrollment = dict(run=self.run, label="A", window="99", frontPID="2345", method="appkit-key-window")
        write(self.root / "enrolled-A.json", self.enrollment)
        write(self.root / "origin-A.json", dict(number=99, record="10", frontPID=2345, currents={"main":"1","side":"10"}))
        self.proof = dict(occupancy="NO_RELOCATION_OBSERVED", source="10", target="11", sourcePID=2345,
                          sourceWindow=99, primary="main", secondary="side", primaryCurrent="1", scopeSamples=2,
                          blockingWindows=0, corroboratedShared=0)

    def calibrate(self):
        self.session.calibrate("enroll-B", self.root, self.run, self.child)

    def test_clear_target_reaches_one_calibration_after_double_occupancy_read(self):
        with patch.object(route.sp, "run", return_value=Mock(returncode=0, stdout=json.dumps(self.proof))) as call:
            self.calibrate()
        self.assertEqual([c.args[0][0].name for c in call.call_args_list], ["occupancy", "calibrate-route"])
        self.assertEqual(call.call_args_list[0].args[0][1:], ["--scoped","2345","99","main","side","1","10","11"])
        self.assertEqual(route.read(self.root / "target-occupancy.json")["sample"], self.proof)

    def test_occupied_changed_unreadable_or_shared_target_gets_zero_calibration_calls(self):
        for delta, code in (({"blockingWindows":1},0), ({"corroboratedShared":1},0), ({"scopeSamples":1},0),
                            ({"target":"12"},0), ({"sourcePID":2346},0), ({"sourceWindow":100},0), ({},2)):
            with self.subTest(delta=delta, code=code), patch.object(
                route.sp, "run", return_value=Mock(returncode=code, stdout=json.dumps(dict(self.proof, **delta)))
            ) as call:
                with self.assertRaisesRegex(ValueError, "blank secondary B"):
                    self.calibrate()
                self.assertEqual([c.args[0][0].name for c in call.call_args_list], ["occupancy"])
                (self.root / "target-occupancy.json").unlink()

    def test_stale_enrollment_rejected_without_invoking_helpers(self):
        write(self.root / "enrolled-A.json", dict(self.enrollment, run="older"))
        with patch.object(route.sp, "run") as call, self.assertRaisesRegex(ValueError, "unbound occupancy"):
            self.calibrate()
        call.assert_not_called()


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
