#!/usr/bin/env python3
"""The Host event loop, admissions and restart decisions, without a desktop."""
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, call, patch

SPEC = importlib.util.spec_from_file_location("management", Path(__file__).with_name("window-management.py"))
wm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wm)


class ProductManagementTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        profile = Path(temp.name).resolve()
        (profile / "profile.version").write_text("Nearpane P4.8\n")
        self.m = wm.Manager(profile, profile)
        self.addCleanup(self.m.lease.close)
        self.id = {"pid": 20, "launch": 32, "number": 3, "element": "one"}
        self.member = {"id": self.id, "minimum": {"width": 144}}
        self.owner = dict(owner={"pid": 20, "start": 32}, revision=2, keyOrMain=False, members=[self.member], frames=[dict(x=3)])
        self.host = dict(edge="right", workspaces={})

    def test_default_and_pause_do_not_observe_or_write(self):
        self.m.snapshot = Mock(side_effect=AssertionError)
        self.m.tick()
        self.m.mode = "active"
        self.m.command("pause")
        self.m.mode = "paused"
        self.m.tick()
        self.m.snapshot.assert_not_called()

    def test_restart_without_consent_cannot_resume(self):
        with self.assertRaises(ValueError):
            self.m.command("resume")
        self.assertFalse(self.m.settings.exists())

    def test_denied_controller_cannot_create_a_grant(self):
        self.m.control = Mock(return_value={"parent": {"pid": wm.os.getpid()}, "trusted": False})
        with self.assertRaisesRegex(ValueError, "辅助功能"):
            self.m.command("enable")
        self.assertEqual(self.m.mode, "off")
        self.assertFalse(self.m.settings.exists())

    def test_stop_restores_before_revoking_consent(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        actions = []
        self.m.preflight = lambda: actions.append("preflight")
        self.m.recover = lambda: actions.append("recover")
        self.m.apply = actions.append
        self.m.grant = actions.append
        self.assertTrue(self.m.command("disable"))
        self.assertEqual(actions, ["preflight", "recover", "candidate-exit", "off"])
        self.assertEqual(wm.read(self.m.settings)["mode"], "off")

    def test_another_manager_cannot_take_the_same_lease(self):
        with self.assertRaisesRegex(ValueError, "另一个 Host"):
            wm.Manager(self.m.root.parent, self.m.root.parent)

    def test_specific_exclusion_and_ambiguous_reused_id(self):
        rules = dict(excludedApps=[wm.APP_ID], windows=[self.id, "include"])
        self.assertTrue(wm.allowed(self.member, rules))
        rules["windows"] = [self.id, "exclude"]
        self.assertFalse(wm.allowed(self.member, rules))
        with self.assertRaises(ValueError):
            wm.allowed({"id": dict(self.id, element="other")}, rules)

    def test_dedup_ignores_ui_but_preserves_window_generation_and_area(self):
        def key():
            return wm.plan_key(self.owner, self.host, "display")
        first = key()
        self.host.update(surfaceHidden=True, modules=["hidden"])
        self.assertEqual(first, key())
        self.host["displays"] = {"display": {"placement": "floating"}}
        self.assertNotEqual(first, key())
        changed = key()
        self.owner["revision"] += 1
        self.assertNotEqual(changed, key())

    def test_two_stable_observations_required_after_burst(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        self.m.pre = dict(trusted=True)
        self.m.owner = Mock(return_value=self.owner)
        original = (1, 1, [(self.member, {"x": 1})])
        rebuilt = (1, 2, [(self.member, {"x": 2})])
        self.m.snapshot = Mock(side_effect=[({}, {}, key) for key in (original, rebuilt, rebuilt, rebuilt)])
        self.m.apply = Mock(side_effect=lambda _, approved: setattr(self.m, "last", approved) or True)
        for _ in range(4):
            self.m.tick()
        self.m.apply.assert_called_once_with("candidate-layout", approved=rebuilt)

    def test_replaced_member_after_debounce_gets_no_ticket_or_controller_call(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        self.m.pre = {"trusted": True}
        self.m.owner = Mock(return_value=self.owner)
        first = wm.plan_key(self.owner, self.host, "display")
        other = dict(self.owner, revision=3, members=[{"id": dict(self.id, element="replacement")}])
        changed = wm.plan_key(other, self.host, "display")
        self.m.snapshot = Mock(side_effect=[(self.owner, self.host, first)] * 2 + [(other, self.host, changed)])
        self.m.control = Mock(side_effect=AssertionError)
        self.m.tick()
        self.m.tick()
        self.m.control.assert_not_called()
        self.assertFalse((self.m.root / "ticket.json").exists())

    def test_failed_explicit_quit_survives_restart_and_blocks_auto_takeover(self):
        import uuid
        self.m.directory = self.m.root / str(uuid.uuid4())
        self.m.directory.mkdir()
        wm.save(self.m.directory / "run.json", {"session": self.m.directory.name})
        self.m.mode = "active"
        self.m.prefs.update(mode="active", session=self.m.directory.name)
        self.m.preflight = Mock()
        self.m.recover = Mock()
        self.m.apply = Mock(side_effect=ValueError("foreign frame"))
        with self.assertRaisesRegex(ValueError, "foreign frame"):
            self.m.command("quit")
        self.m.lease.close()
        m = wm.Manager(self.m.root.parent, self.m.root.parent)
        self.addCleanup(m.lease.close)
        m.preflight = Mock()
        m.tick()
        m.preflight.assert_not_called()
        self.assertTrue(m.error)
        with self.assertRaises(ValueError):
            m.command("resume")
        m.recover, m.apply, m.grant = Mock(), Mock(), Mock()
        self.assertTrue(m.command("retry"))
        m.apply.assert_called_once_with("candidate-exit")
        self.assertEqual(m.mode, "paused")
        self.assertNotIn("pendingStop", wm.read(m.settings))

    def test_conflict_prevents_periodic_retries(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        self.m.error = "external layout change"
        self.m.preflight = Mock(side_effect=AssertionError)
        self.m.tick()
        self.m.preflight.assert_not_called()

    def presentation_setup(self):
        self.m.directory = self.m.root / "ad7eb93a-37d7-465c-89a6-d841493424ea"
        self.m.directory.mkdir()
        self.id["number"] = 179888
        self.full_frame = dict(x=-681, y=64, width=562, height=422)
        self.small_frame = dict(x=-64, y=602, width=49, height=76)
        self.owner["frames"] = [self.full_frame]
        key = wm.plan_key(self.owner, self.host, "display")
        self.m.snapshot = Mock(return_value=(self.owner, self.host, key))
        self.m.grant = Mock()
        return key

    def proof(self, *observations):
        return dict(session=self.m.directory.name, revision=self.owner["revision"],
                    beganUptime=wm.time.clock_gettime(wm.time.CLOCK_UPTIME_RAW), stageManagerEnabled=True, confirmed=observations)

    def observation(self):
        return dict(member=self.member, onScreen=True, cg=self.full_frame, ax=self.full_frame)

    def test_unconfirmed_presentation_preserves_wal_baseline_and_issues_no_ticket(self):
        self.presentation_setup()
        layout = self.m.directory / "layout.json"
        journal = self.m.directory / "journal.json"
        wm.save(layout, dict(initial=self.full_frame, confirmed=self.full_frame))
        wm.save(journal, dict(status="prepared", original=self.full_frame))
        previous = (layout.read_bytes(), journal.read_bytes())
        for evidence in (self.proof(), self.proof(dict(self.observation(), cg=self.small_frame)),
                         self.proof(dict(self.observation(), cg=self.small_frame, ax=self.small_frame)),
                         self.proof(dict(self.observation(), onScreen=False)),
                         dict(self.proof(self.observation()), beganUptime=0)):
            for action in (lambda: self.m.apply("candidate-adopt"), self.m.recover):
                self.m.control = Mock(return_value=evidence)
                with self.assertRaises(ValueError):
                    action()
                self.m.control.assert_called_once_with("product-presentation")
                self.m.grant.assert_not_called()
                self.assertFalse((self.m.directory / "ticket.json").exists())
                self.assertEqual(previous, (layout.read_bytes(), journal.read_bytes()))

    def test_identity_change_after_readback_vetoes_ticket(self):
        key = self.presentation_setup()
        self.m.control = Mock(return_value=self.proof(self.observation()))
        replaced = dict(self.owner, revision=3)
        self.m.snapshot = Mock(side_effect=[(self.owner, self.host, key),
                                           (replaced, self.host, wm.plan_key(replaced, self.host, "display"))])
        with self.assertRaisesRegex(ValueError, "核对后发生变化"):
            self.m.apply("candidate-layout")
        self.m.control.assert_called_once_with("product-presentation")
        self.assertFalse((self.m.directory / "ticket.json").exists())

    def test_periodic_refusal_latches_until_recheck_then_settled_window_can_layout(self):
        self.presentation_setup()
        self.m.mode = "active"
        self.m.run = {"screens": {"secondary": "display"}}
        self.m.pre = {"trusted": True, "screens": {"secondary": "display"}}
        self.m.preflight = Mock()
        self.m.owner = Mock(return_value=self.owner)
        good = self.observation()
        calls = []

        def control(verb):
            calls.append(verb)
            if verb == "product-presentation":
                self.assertFalse((self.m.directory / "ticket.json").exists())
                if len(calls) == 1:
                    return dict(self.proof(), refusal="窗口呈现不一致", unconfirmed=[dict(good, cg=self.small_frame)])
                return self.proof(good)
            self.assertEqual(verb, "candidate-layout")
            ticket = wm.read(self.m.directory / "ticket.json")
            self.assertEqual((ticket["members"], ticket["frames"]), ([self.member], [self.full_frame]))
            return dict(session=self.m.directory.name, snapshotRevision=2, observations=[good])

        self.m.control = control
        idle = ([], [], [])
        command = ([True], [], [])
        def events():
            yield idle
            yield idle  # First layout reaches the read-only controller and is refused.
            for _ in range(4):
                yield idle
            self.assertEqual(calls, ["product-presentation"])
            self.assertTrue(wm.read(self.m.root / "status.json")["blocked"])
            self.assertEqual(wm.read(self.m.directory / "presentation-result.json")["unconfirmed"][0]["cg"], self.small_frame)
            yield command  # Explicit retry
            yield idle
            yield idle
            yield command  # EOF
        with patch.object(wm.select, "select", side_effect=events()), patch.object(wm.sys, "stdin", io.StringIO("retry\n")), \
                patch.object(wm.sys, "stdout", io.StringIO()):
            self.m.loop()
        self.assertEqual(calls, ["product-presentation", "product-presentation", "candidate-layout"])
        self.assertEqual(self.m.grant.call_args_list, [call("paused"), call("active")])
        self.assertFalse(wm.read(self.m.root / "status.json")["blocked"])

    def test_recovery_only_tickets_confirmed_members_in_mixed_group(self):
        self.presentation_setup()
        other = dict(self.member, id=dict(self.id, number=29, element="other"))
        owner = dict(self.owner, members=[other, self.member], frames=[self.small_frame, self.full_frame])
        key = wm.plan_key(owner, self.host, "display")
        self.m.snapshot = Mock(return_value=(owner, self.host, key))
        self.m.control = Mock(return_value=self.proof(self.observation()))
        with self.assertRaises(ValueError):
            self.m.issue_ticket(owner, key)
        self.assertFalse((self.m.directory / "ticket.json").exists())
        self.m.issue_ticket(owner, key, recovery=True)
        self.assertEqual(wm.read(self.m.directory / "ticket.json")["members"], [self.member])

    def test_unacknowledged_write_is_recovered_before_layout(self):
        self.presentation_setup()
        self.m.control = Mock(side_effect=[self.proof(self.observation()),
                                           dict(journal=dict(status="restored"), observations=[self.owner])])
        wm.save(self.m.directory / "journal.json", dict(status="prepared"))
        self.m.recover()
        calls = [call("product-presentation"), call("recover")]
        self.assertEqual(self.m.control.call_args_list, calls)
        wm.save(self.m.directory / "journal.json", dict(status="restored"))
        self.m.recover()
        self.assertEqual(self.m.control.call_args_list, calls)


if __name__ == "__main__":
    unittest.main()
