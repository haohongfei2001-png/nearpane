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
        (profile / "profile.version").write_text("Nearpane P5.2\n")
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
            return wm.plan_key(self.owner, self.host, "display", 800)
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

    def test_layout_dedup_uses_effective_reservation_after_panel_resize(self):
        measures = {}
        settings = {"placement": "docked", "measures": measures}
        self.host["displays"] = {"display": settings}
        def key():
            return wm.plan_key(self.owner, self.host, "display", 800)
        factory = key()
        measures["panelWidth"] = {"value": 100, "unit": "pt"}
        measures["panelHeight"] = {"value": 20, "unit": "pt"}
        self.assertEqual(key(), factory)
        measures["panelWidth"] = {"value": 0, "unit": "%"}
        icon = key()
        self.assertEqual(icon[-1], 20)
        self.assertNotEqual(factory, icon)
        measures["panelWidth"] = {"value": 20, "unit": "pt"}
        self.assertEqual(key(), icon)
        measures["reservedWidth"] = {"value": 12.5, "unit": "%"}
        self.assertEqual(key(), factory)
        measures["panelWidth"] = {"value": 97, "unit": "%"}
        self.assertEqual(key(), factory)
        settings["placement"] = "floating"
        floating = key()
        self.assertEqual(floating[-1], 0)
        settings["edge"] = "left"
        measures.clear()
        self.assertEqual(key(), floating)

    def test_replaced_member_after_debounce_gets_no_ticket_or_controller_call(self):
        self.m.mode = "active"
        self.m.directory = self.m.root
        self.m.pre = {"trusted": True}
        self.m.owner = Mock(return_value=self.owner)
        first = wm.plan_key(self.owner, self.host, "display", 800)
        other = dict(self.owner, revision=3, members=[{"id": dict(self.id, element="replacement")}])
        changed = wm.plan_key(other, self.host, "display", 800)
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

    def test_refused_recovery_survives_process_replacement_and_requires_explicit_recheck(self):
        import uuid
        self.m.directory = self.m.root / str(uuid.uuid4())
        self.m.directory.mkdir()
        wm.save(self.m.directory / "run.json", {"session": self.m.directory.name})
        self.m.mode = "active"
        self.m.prefs.update(session=self.m.directory.name, mode="active")
        self.m.suspend_on_error(ValueError("恢复缺少原窗口编辑代际"))
        self.m.lease.close()
        reopened = wm.Manager(self.m.root.parent, self.m.root.parent)
        self.addCleanup(reopened.lease.close)
        self.assertIn("编辑代际", reopened.error)
        reopened.preflight = Mock()
        reopened.recover = Mock(side_effect=ValueError("仍缺代际"))
        reopened.tick()
        for cmd in ("resume", "enable", "open"):
            with self.assertRaises(ValueError):
                reopened.command(cmd)
        reopened.preflight.assert_not_called()
        with self.assertRaisesRegex(ValueError, "仍缺代际"):
            reopened.command("retry")
        self.assertIn("blockedReason", wm.read(reopened.settings))
        reopened.recover = Mock()
        reopened.pre = {"screens": {"secondary": "fixture-side"}}
        reopened.command("retry")
        self.assertNotIn("blockedReason", wm.read(reopened.settings))

    def test_dead_or_replaced_owner_cannot_discard_an_unresolved_journal(self):
        self.presentation_setup()
        journal = self.m.directory / "journal.json"
        wm.save(journal, {"status": "prepared"})
        self.m.control = Mock()
        with self.assertRaisesRegex(ValueError, "未解决"):
            self.m.verify_retirable()
        self.m.control.assert_not_called()
        self.assertEqual(wm.read(journal)["status"], "prepared")

    def presentation_setup(self):
        self.m.directory = self.m.root / "ad7eb93a-37d7-465c-89a6-d841493424ea"
        self.m.directory.mkdir()
        self.id["number"] = 179888
        self.full_frame = dict(x=-681, y=64, width=562, height=422)
        self.small_frame = dict(x=-64, y=602, width=49, height=76)
        self.owner["frames"] = [self.full_frame]
        key = wm.plan_key(self.owner, self.host, "display", 800)
        self.m.snapshot = Mock(return_value=(self.owner, self.host, key))
        self.m.grant = Mock()
        return key

    def proof(self, *observations):
        return dict(session=self.m.directory.name, revision=self.owner["revision"],
                    beganUptime=wm.time.clock_gettime(wm.time.CLOCK_UPTIME_RAW), stageManagerEnabled=True, confirmed=observations)

    def observation(self):
        return dict(member=self.member, onScreen=True, cg=self.full_frame, ax=self.full_frame)

    def send_presentation(self, state, display, lifetime=12):
        deadline = wm.time.clock_gettime(wm.time.CLOCK_UPTIME_RAW) + lifetime
        return self.m.command(f"presentation {state} {display} {deadline!r}")

    def held_fullscreen(self):
        key = self.presentation_setup()
        display = "A4B0E968-D7AC-46DA-A770-7E4356006069"
        self.m.mode = self.m.prefs["mode"] = "active"
        self.m.prefs["display"] = display
        self.m.preflight = Mock()
        self.m.control = Mock(return_value=self.proof(self.observation()))
        self.m.last = key
        wm.save(self.m.directory / "journal.json", dict(status="retained"))
        self.m.command("presentation hold " + display)
        return display, key

    def test_verified_return_reads_actual_layout_without_new_action_ticket(self):
        display, key = self.held_fullscreen()
        self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.m.tick()
        self.m.snapshot.assert_not_called()
        self.send_presentation("returned", display)
        self.assertNotIn("fullscreenHold", wm.read(self.m.settings))
        self.assertEqual(self.m.last, key)
        self.assertEqual(self.m.control.call_args_list, [call("product-presentation")])
        self.assertFalse((self.m.directory / "ticket.json").exists())

    def test_unproven_return_and_changed_window_preserve_journal(self):
        display, key = self.held_fullscreen()
        with self.assertRaisesRegex(ValueError, "返回原空间"):
            self.send_presentation("ordinary", display)
        changed = (key[0], key[1], [(self.member, self.small_frame)], *key[3:])
        self.m.snapshot.return_value = (self.owner, self.host, changed)
        with self.assertRaisesRegex(ValueError, "手动布局"):
            self.send_presentation("returned", display)
        with self.assertRaisesRegex(ValueError, "手动布局"):
            self.m.command("retry")
        self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.assertEqual(wm.read(self.m.directory / "journal.json"), dict(status="retained"))
        self.m.control.assert_not_called()

    def test_fullscreen_quit_and_crash_do_not_replay_restore(self):
        display, _ = self.held_fullscreen()
        self.m.return_evidence.clear()  # A new process has no fresh ordinary observation.
        with self.assertRaisesRegex(ValueError, "尚未证实"):
            self.m.command("quit")
        self.assertEqual(wm.read(self.m.settings)["pendingStop"], "quit")
        self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.m.tick()
        self.m.control.assert_not_called()

    def test_ordinary_cannot_release_managed_group_through_retry_disable_or_quit(self):
        display, _ = self.held_fullscreen()
        with self.assertRaisesRegex(ValueError, "返回原空间"):
            self.send_presentation("ordinary", display)
        for command in ("retry", "disable", "quit"):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "返回原空间"):
                self.m.command(command)
        self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.m.control.assert_not_called()
        self.assertFalse((self.m.directory / "ticket.json").exists())

    def test_missing_or_invalid_heartbeat_revokes_previous_usable_return(self):
        display, _ = self.held_fullscreen()
        self.m.suspend_on_error(ValueError("等待手动核对"))
        for invalid in ["unknown", "returned", "returned nan", "returned inf", "returned expired", "ordinary future"]:
            self.send_presentation("returned", display)
            state, *suffix = invalid.split()
            if state == "unknown":
                self.m.command(f"presentation unknown {display}")
            else:
                with self.assertRaises(ValueError):
                    if suffix in (["expired"], ["future"]):
                        self.send_presentation(state, display, lifetime=60 if suffix == ["future"] else -1)
                    else:
                        self.m.command(" ".join(["presentation", state, display, *suffix]))
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "尚未证实"):
                self.m.command("retry")
            self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.m.control.assert_not_called()

    def test_return_expires_while_waiting_for_retry_or_for_independent_readback(self):
        display, _ = self.held_fullscreen()
        self.m.suspend_on_error(ValueError("等待手动核对"))
        now = wm.time.clock_gettime(wm.time.CLOCK_UPTIME_RAW)
        with patch.object(wm.time, "clock_gettime", return_value=now):
            self.send_presentation("returned", display)
        with patch.object(wm.time, "clock_gettime", return_value=now + 12):
            with self.assertRaisesRegex(ValueError, "过期"):
                self.m.command("retry")
        self.m.control.assert_not_called()
        with patch.object(wm.time, "clock_gettime", return_value=now):
            self.send_presentation("returned", display)
        def readback(_):
            proof = self.proof(self.observation())
            proof["beganUptime"] = now + 11
            clock.return_value = now + 12.1
            return proof
        self.m.control.side_effect = readback
        with patch.object(wm.time, "clock_gettime", return_value=now + 11.9) as clock:
            with self.assertRaisesRegex(ValueError, "过期"):
                self.m.command("retry")
        self.assertIn("fullscreenHold", wm.read(self.m.settings))
        self.assertFalse((self.m.directory / "ticket.json").exists())

    def test_known_hold_before_window_registration_blocks_creation_poll_and_apply(self):
        display = "A4B0E968-D7AC-46DA-A770-7E4356006069"
        self.m.mode = self.m.prefs["mode"] = "active"
        self.m.prefs["display"] = display
        self.m.pre = {"screens": {"secondary": display}}
        self.m.command("presentation hold " + display)
        self.m.command("presentation unknown " + display)
        with self.assertRaisesRegex(ValueError, "全屏期间"):
            self.m.command("open")
        self.assertIsNone(self.m.directory)
        self.m.directory = self.m.root
        self.m.snapshot = Mock(side_effect=AssertionError)
        self.m.tick()
        with self.assertRaisesRegex(ValueError, "全屏期间"):
            self.m.apply("candidate-layout")
        self.m.snapshot.assert_not_called()

    def test_detached_displays_release_volatile_evidence_and_ignore_late_events(self):
        primary = str(wm.uuid.uuid4()).upper()
        self.m.command("topology " + primary)
        for _ in range(64):
            secondary = str(wm.uuid.uuid4()).upper()
            self.m.command(f"topology {primary} {secondary}")
            self.assertTrue(self.m.display_blocked(secondary))
            self.send_presentation("ordinary", secondary)
            self.assertFalse(self.m.display_blocked(secondary))
            self.m.command("presentation hold " + secondary)
            self.m.command("topology " + primary)
            self.send_presentation("ordinary", secondary)
            self.assertTrue(self.m.display_blocked(secondary))
        self.assertEqual(self.m.fullscreen_displays, set())
        self.assertEqual(self.m.return_evidence, {})

    def test_reconnect_cannot_discharge_a_managed_fullscreen_transaction(self):
        display, _ = self.held_fullscreen()
        self.m.command("topology " + display)
        original = self.m.prefs["fullscreenHold"].copy()
        self.m.command("topology")
        self.send_presentation("returned", display)
        self.m.command("topology " + display)
        self.m.command("presentation unknown " + display)
        self.assertTrue(self.m.display_blocked(display))
        with self.assertRaisesRegex(ValueError, "尚未证实"):
            self.m.command("retry")
        self.assertEqual(wm.read(self.m.settings)["fullscreenHold"], original)
        self.m.control.assert_not_called()

    def test_disable_before_first_layout_never_opens_an_exit_frame_transaction(self):
        display = "A4B0E968-D7AC-46DA-A770-7E4356006069"
        self.presentation_setup()
        self.m.mode = self.m.prefs["mode"] = "active"
        self.m.prefs.update(display=display, session=self.m.directory.name)
        self.m.run = dict(productManagement=True, session=self.m.directory.name)
        wm.save(self.m.directory / "run.json", self.m.run)
        self.m.preflight = Mock()
        self.m.apply = Mock(side_effect=AssertionError)
        self.m.command("presentation hold " + display)
        self.assertTrue(wm.read(self.m.settings)["fullscreenHold"]["untouched"])
        with self.assertRaisesRegex(ValueError, "尚未证实"):
            self.m.command("disable")
        with self.assertRaisesRegex(ValueError, "过期"):
            self.send_presentation("ordinary", display, lifetime=-1)
        with self.assertRaisesRegex(ValueError, "尚未证实"):
            self.m.command("disable")
        self.send_presentation("ordinary", display)
        self.assertTrue(self.m.command("disable"))
        prefs = wm.read(self.m.settings)
        self.assertEqual(prefs["mode"], "off")
        self.assertNotIn("fullscreenHold", prefs)
        self.assertNotIn("pendingStop", prefs)
        self.m.snapshot.assert_called_once()
        self.m.apply.assert_not_called()

    def test_unknown_baseline_with_prior_or_intervening_transaction_keeps_hold(self):
        display = "A4B0E968-D7AC-46DA-A770-7E4356006069"
        self.presentation_setup()
        self.m.mode = self.m.prefs["mode"] = "active"
        self.m.prefs.update(display=display, session=self.m.directory.name)
        self.m.run = dict(productManagement=True, session=self.m.directory.name)
        wm.save(self.m.directory / "run.json", self.m.run)
        self.m.preflight = Mock()
        self.m.control = Mock(side_effect=AssertionError)
        for receipt in ["ticket.json", "last-result.json", "last-recovery.json", "layout.json", "journal.json"]:
            with self.subTest(receipt=receipt):
                self.m.command("presentation hold " + display)
                evidence = self.m.directory / receipt
                wm.save(evidence, dict(status="prepared"))
                with self.assertRaises(ValueError):
                    self.send_presentation("returned", display)
                with self.assertRaises(ValueError):
                    self.m.command("retry")
                self.assertIn("fullscreenHold", wm.read(self.m.settings))
                self.assertEqual(wm.read(evidence), dict(status="prepared"))
                evidence.unlink()
        self.m.control.assert_not_called()

    def test_coalesced_primary_and_secondary_notifications_precede_any_tick(self):
        reader, writer = wm.os.pipe()
        self.addCleanup(wm.os.close, writer)
        commands = []
        def handle(cmd):
            commands.append(cmd)
            return cmd != "quit"
        self.m.command = handle
        self.m.status = Mock()
        self.m.tick = Mock(side_effect=AssertionError("layout tick interleaved with queued display notices"))
        wm.os.write(writer, b"presentation ordinary primary\npresentation hold secondary\nquit\n")
        with wm.os.fdopen(reader, "r") as source, patch.object(wm.sys, "stdin", source):
            self.m.loop()
        self.assertEqual(commands, ["presentation ordinary primary", "presentation hold secondary", "quit"])

    def test_only_committed_workrect_change_can_schedule_relayout_after_return(self):
        display, key = self.held_fullscreen()
        self.m.snapshot.return_value = (self.owner, self.host, (*key[:4], key[4] + 10))
        self.send_presentation("returned", display)
        self.assertIsNone(self.m.last)
        self.assertIsNone(self.m.pending)
        self.assertFalse((self.m.directory / "ticket.json").exists())

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
                                           (replaced, self.host, wm.plan_key(replaced, self.host, "display", 800))])
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
        with tempfile.TemporaryFile() as source, patch.object(wm.select, "select", side_effect=events()), \
                patch.object(wm.sys, "stdin", source), patch.object(wm.sys, "stdout", io.StringIO()):
            source.write(b"retry\n")
            source.seek(0)
            self.m.loop()
        self.assertEqual(calls, ["product-presentation", "product-presentation", "candidate-layout"])
        self.assertEqual(self.m.grant.call_args_list, [call("paused"), call("active")])
        self.assertFalse(wm.read(self.m.root / "status.json")["blocked"])

    def test_recovery_only_tickets_confirmed_members_in_mixed_group(self):
        self.presentation_setup()
        other = dict(self.member, id=dict(self.id, number=29, element="other"))
        owner = dict(self.owner, members=[other, self.member], frames=[self.small_frame, self.full_frame])
        key = wm.plan_key(owner, self.host, "display", 800)
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
