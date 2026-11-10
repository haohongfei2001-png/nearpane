#!/usr/bin/env python3
"""The Host event loop, admissions and restart decisions, without a desktop."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

SPEC = importlib.util.spec_from_file_location("management", Path(__file__).with_name("window-management.py"))
wm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wm)


class ProductManagementTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        profile = Path(temp.name).resolve()
        (profile / "profile.version").write_text("Nearpane P4.6\n")
        self.m = wm.Manager(profile, profile)
        self.addCleanup(self.m.lease.close)
        self.id = {"pid": 20, "launch": 32, "number": 3, "element": "one"}
        self.member = {"id": self.id, "minimum": {"width": 144}}
        self.owner = dict(owner={"pid": 20, "start": 32}, revision=2, members=[self.member], frames=[dict(x=3)])
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
        self.m.apply = Mock(side_effect=lambda _: setattr(self.m, "last", rebuilt))
        for _ in range(4):
            self.m.tick()
        self.m.apply.assert_called_once_with("candidate-layout")

    def test_conflict_prevents_periodic_retries(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        self.m.error = "external layout change"
        self.m.preflight = Mock(side_effect=AssertionError)
        self.m.tick()
        self.m.preflight.assert_not_called()

    def test_unacknowledged_write_is_recovered_before_layout(self):
        self.m.directory = self.m.root
        self.m.snapshot = Mock(return_value=(self.owner, self.host, wm.plan_key(self.owner, self.host, "display")))
        self.m.grant = Mock()
        self.m.control = Mock(return_value=dict(journal=dict(status="restored"), observations=[self.owner]))
        wm.save(self.m.root / "journal.json", dict(status="prepared"))
        self.m.recover()
        self.m.control.assert_called_once_with("recover")
        wm.save(self.m.root / "journal.json", dict(status="restored"))
        self.m.recover()
        self.m.control.assert_called_once()


if __name__ == "__main__":
    unittest.main()
