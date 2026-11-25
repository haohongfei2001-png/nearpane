// Synthetic system implementing the same single-window reverse and forward membership reads as Darwin.
use super::*;
use std::cell::Cell;

struct Guard {
    ok: Cell<bool>,
    approved: Option<Route>,
    lose_companion_while_hidden: bool,
    input_observed: bool,
}
impl Authority for Guard {
    fn fixture_companions(&self, _home: u64, hidden: bool) -> Check<()> {
        if hidden && self.lose_companion_while_hidden { Err(unknown(Why::Readback)) } else { Ok(()) }
    }
    fn fixture_parked_input(&self, _parking: u64) -> Check<()> {
        if self.input_observed { Ok(()) } else { Err(unknown(Why::Readback)) }
    }

    fn approved_route(&self) -> Option<Route> {
        self.approved
    }
    fn active(&self) -> Check<()> {
        self.observation()
    }
    fn observation(&self) -> Check<()> {
        if self.ok.get() {
            Ok(())
        } else {
            Err(Fault(CANCELLED, Why::Stale))
        }
    }
}
#[derive(Default)]
struct Fake {
    clock: Cell<Option<Instant>>,
    windows: BTreeMap<u32, (Window, u64, u64, bool)>,
    spaces: Rows,
    moved: Vec<(Route, u32, u64, u32)>,
    destroyed: Vec<u64>,
    next: u64,
    connection: i32,
    no_effect: bool,
    switch_topology: bool,
    bystander: bool,
    opened_probe: bool,
    initial_empty_memberships: Cell<u32>,
    ambiguous_panel_membership: bool,
    defer_probe_close: bool,
    cg_keeps_closed_probe: bool,
    managed_roster: Vec<Desktop>,
    reverse_managed_after_hide: bool,
    repeated_fullscreen: Option<u64>,
    lose_repeat_after_create: bool,
    probe_closes: u32,
    lose_focus_on_hide: bool,
    focus_changed: bool,
    replace_fixture_when_parked: bool,
    unavailable_first_return_read: bool,
    pending_unavailable_read: Cell<bool>,
    replace_fixture_on_return: bool,
    minimize_writes: Vec<(u32, u64, bool)>,
    refuse_unminimize: bool,
    unminimize_returns_to_desktop: bool,
}
impl Fake {
    fn new() -> Self {
        Self {
            spaces: Rows::from([10]),
            connection: 1,
            next: 100,
            ..Self::default()
        }
    }
    fn add(&mut self, r: &Request) {
        self.windows.insert(
            r.window,
            (
                Window {
                    number: r.window,
                    pid: r.pid,
                    birth: r.birth,
                },
                10,
                42,
                false,
            ),
        );
    }
}
impl Platform for Fake {
    type Witness = u64;
    fn now(&self) -> Instant {
        // Synthetic scheduling follows the engine's polling interval. OS thread
        // descheduling must not turn two pending observations into a fake timeout.
        let now = self.clock.get().unwrap_or_else(Instant::now);
        self.clock.set(Some(now));
        now
    }
    fn wait(&self, duration: Duration) {
        self.clock.set(Some(self.now() + duration));
    }
    fn flags(&self) -> u32 {
        7
    }
    fn target(&self) -> bool {
        true
    }
    fn connection(&self) -> Check<i32> {
        Ok(self.connection)
    }
    fn desktops(&self, _: i32) -> Check<Vec<Desktop>> {
        if !self.managed_roster.is_empty() {
            let mut roster = self.managed_roster.clone();
            if self.reverse_managed_after_hide && !self.moved.is_empty() {
                roster.reverse();
            }
            return Ok(roster);
        }
        Ok(vec![Desktop {
            display: [5; 16],
            uuid: [6; 16],
            id: 10,
            kind: if self.switch_topology { 4 } else { 0 },
            current: 1,
        }])
    }
    fn all(&self, _: i32) -> Check<Vec<u64>> {
        let mut ids: Vec<_> = self.spaces.iter().copied().collect();
        if let Some(id) = self
            .repeated_fullscreen
            .filter(|_| !self.lose_repeat_after_create || self.next == 100)
        {
            ids.push(id);
            ids.sort_unstable();
        }
        Ok(ids)
    }
    fn members(&self, _: i32, s: u64) -> Check<Rows> {
        let mut set: Rows = self
            .windows
            .iter()
            .filter_map(|(&w, v)| (v.1 == s).then_some(u64::from(w)))
            .collect();
        if self.bystander && s != 10 {
            set.insert(999);
        }
        Ok(set)
    }
    fn spaces(&self, _: i32, w: u32) -> Check<Rows> {
        if w == 77 && self.opened_probe {
            if self.ambiguous_panel_membership {
                return Ok(Rows::from([10, 11]));
            }
            if self.initial_empty_memberships.get() > 0 {
                self.initial_empty_memberships
                    .set(self.initial_empty_memberships.get() - 1);
                return Ok(Rows::new());
            }
        }
        Ok(self
            .windows
            .get(&w)
            .map(|r| Rows::from([r.1]))
            .unwrap_or_default())
    }
    fn bind(&self, w: Window) -> Check<u64> {
        let t = self.windows[&w.number];
        if t.0 == w && !t.3 {
            Ok(t.2)
        } else {
            Err(unknown(Why::Identity))
        }
    }
    fn bind_minimized(&self, w: Window) -> Check<u64> {
        let t = self.windows[&w.number];
        if t.0 == w && t.3 { Ok(10_000 + u64::from(w.number)) }
        else { Err(unknown(Why::MinimizedOrAX)) }
    }
    fn minimized(&self, witness: &u64) -> Check<bool> {
        if *witness >= 10_000 { return Ok(self.windows[&((*witness - 10_000) as u32)].3); }
        Ok(false)
    }
    fn set_minimized(&mut self, w: Window, witness: &u64, minimized: bool) -> Delivery {
        if *witness != 10_000 + u64::from(w.number) || self.refuse_unminimize { return Delivery::Refused; }
        let t = self.windows.get_mut(&w.number).unwrap();
        self.minimize_writes.push((w.number, t.1, minimized));
        t.3 = minimized;
        if !minimized && self.unminimize_returns_to_desktop { t.1 = 10; }
        Delivery::Accepted
    }
    fn canary(&mut self, op: launch::PanelOp, guard: &impl Authority) -> Check<launch::Panel> {
        let n = 77;
        if op == launch::PanelOp::Open {
            guard.active()?;
            if self.opened_probe {
                return Err(fail(Why::Stale));
            }
            self.add(&request(n, READBACK, 1));
            self.windows.get_mut(&n).unwrap().2 = 77;
            self.opened_probe = true;
        } else if op == launch::PanelOp::Close {
            guard.active()?;
            self.probe_closes += 1;
            if !self.defer_probe_close {
                self.windows.remove(&n);
            }
        }
        let exists = self.windows.contains_key(&n);
        Ok(launch::Panel {
            number: if self.opened_probe { n } else { 0 },
            pid: std::process::id() as i32,
            birth: 123,
            opened: self.opened_probe as u32,
            registered: exists as u32,
            absent: (!exists) as u32,
            focus_same: (!self.focus_changed) as u32,
            close_issued: (self.probe_closes > 0) as u32,
        })
    }
    fn absent(&self, n: u32) -> Check<bool> {
        Ok(!self.windows.contains_key(&n) && !(n == 77 && self.cg_keeps_closed_probe))
    }
    fn departed(&self, w: Window) -> Check<bool> {
        Ok(self.windows.get(&w.number).is_some_and(|r| r.0 != w) || self.absent(w.number)?)
    }
    fn transparent_canary(&self, w: &u64) -> bool {
        *w == 77
    }
    fn see(&self, w: Window, lease: &u64) -> Check<Seen> {
        if self.pending_unavailable_read.replace(false) { return Err(unknown(Why::Readback)); }
        let t = self.windows[&w.number];
        if t.0 == w && ((t.2 == *lease && !t.3) || *lease == 10_000 + u64::from(w.number)) {
            Ok(Seen {
                visible: !t.3 && *lease != 77 && if self.managed_roster.is_empty() { t.1 == 10 }
                    else { self.managed_roster.iter().any(|d| d.id == t.1 && d.current == 1) },
                rect: [0., 0., 100., 100.],
            })
        } else {
            Err(unknown(Why::Identity))
        }
    }
    fn create(&mut self, _: i32) -> Check<u64> {
        self.next += 1;
        self.spaces.insert(self.next);
        Ok(self.next)
    }
    fn destroy(&mut self, _: i32, s: u64) -> Delivery {
        assert!(
            !self.windows.contains_key(&77) && !self.cg_keeps_closed_probe,
            "the owned probe must disappear in AppKit and CG before destroying its Space"
        );
        self.destroyed.push(s);
        self.spaces.remove(&s);
        Delivery::Accepted
    }
    fn move_window(&mut self, _: i32, route: Route, w: Window, s: u64, mask: u32) -> Delivery {
        self.moved.push((route, w.number, s, mask));
        if self.lose_focus_on_hide && mask == 7 && w.number == 77 {
            self.focus_changed = true;
        }
        if !self.no_effect {
            self.windows.get_mut(&w.number).unwrap().1 = s;
            if self.replace_fixture_when_parked && w.number != 77 && mask == 7 {
                self.windows.get_mut(&w.number).unwrap().2 += 1;
            }
            if mask == 15 {
                self.pending_unavailable_read.set(self.unavailable_first_return_read);
                if self.replace_fixture_on_return { self.windows.get_mut(&w.number).unwrap().2 += 1; }
            }
        }
        Delivery::Accepted
    }
}
#[cfg(target_os = "macos")]
fn installed_fixture() -> (State<Fake>, Guard, Window) {
    let (mut s, g) = setup();
    let mut enrolled = request(5, READBACK, 42);
    enrolled.pid = std::process::id() as i32 + 1;
    s.sys.add(&enrolled);
    let w = s.sys.windows[&5].0;
    (s, g, w)
}
#[cfg(target_os = "macos")]
#[test]
fn standalone_panel_never_moves_an_external_window_or_releases_a_pending_close() {
    for deferred in [false, true] {
        let (mut state, guard, ordinary) = installed_fixture();
        state.sys.defer_probe_close = deferred;
        let verdict = installed::replay_panel(&mut state, &guard);
        assert_eq!(
            state.sys.moved.iter().map(|m| m.1).collect::<Vec<_>>(),
            vec![77, 77]
        );
        assert_eq!(state.sys.windows[&ordinary.number].1, 10);
        assert_eq!(state.sys.probe_closes, 1);
        if deferred {
            assert_eq!(verdict, (UNKNOWN, 0, 0));
            assert!(state.sys.destroyed.is_empty() && state.route.is_none());
        } else {
            assert_eq!(verdict, (PASS, 2, 1));
            assert_eq!(state.sys.destroyed, vec![101]);
        }
    }
}

#[cfg(target_os = "macos")]
#[test]
fn panel_waits_for_registration_and_refuses_unresolved_membership_before_dispatch() {
    for (empty, ambiguous, should_move) in
        [(2, false, true), (0, true, false), (u32::MAX, false, false)]
    {
        let (mut state, guard, _) = installed_fixture();
        state.sys.initial_empty_memberships.set(empty);
        state.sys.ambiguous_panel_membership = ambiguous;
        let (status, _, clean) = installed::replay_panel(&mut state, &guard);
        assert_eq!(status, if should_move { PASS } else { UNKNOWN },
            "initial empty reads={empty}, ambiguous={ambiguous}");
        assert_eq!(state.sys.moved.len(), if should_move { 2 } else { 0 });
        assert_eq!(state.sys.next, if should_move { 101 } else { 100 });
        assert_eq!(state.sys.probe_closes, 1);
        assert_eq!(clean, 1);
    }
}
#[cfg(target_os = "macos")]
#[test]
fn full_inventory_multiplicity_must_survive_create_and_cleanup_before_external_admission() {
    for lose in [false, true] {
        let (mut s, guard, _) = installed_fixture();
        let home = s.sys.desktops(1).unwrap()[0];
        s.sys.managed_roster = vec![
            home,
            Desktop {
                id: 11,
                uuid: [8; 16],
                kind: 4,
                current: 0,
                ..home
            },
        ];
        s.sys.spaces.insert(11);
        s.sys.repeated_fullscreen = Some(11);
        s.sys.lose_repeat_after_create = lose;
        let result = installed::replay_panel(&mut s, &guard);
        if lose {
            assert_ne!(result.0, PASS);
            assert!(s.sys.moved.is_empty() && s.route.is_none());
        } else {
            assert_eq!(result, (PASS, 2, 1));
            assert_eq!(s.sys.all(1).unwrap(), vec![10, 11, 11]);
        }
    }
}
#[cfg(target_os = "macos")]
#[test]
fn installed_cycle_uses_two_distinct_owners_ordinary_fixture_returns_and_both_parking_ids_disappear(
) {
    let (mut s, g, w) = installed_fixture();
    let (result, proof) = installed::replay(&mut s, w, &g, || ());
    assert_eq!(result, PASS);
    assert_eq!(proof, [2, 2, 2, 2, 1, 1, 1, 77]);
    assert_eq!(
        s.sys.moved,
        vec![
            (Route::Bridge, 77, 101, 7),
            (Route::Bridge, 77, 10, 15),
            (Route::Bridge, 5, 102, 7),
            (Route::Bridge, 5, 10, 15)
        ]
    );
    assert_eq!(s.sys.destroyed, vec![101, 102]);
    assert_eq!(s.sys.spaces, Rows::from([10]));
    assert!(s.owned.is_empty() && s.slots.is_empty());
}
#[cfg(target_os = "macos")]
#[test]
fn installed_cycle_does_not_acquire_fixture_after_failed_canary_or_superseding_input() {
    let (mut s, g, w) = installed_fixture();
    s.sys.defer_probe_close = true;
    let (result, proof) = installed::replay(&mut s, w, &g, || {
        panic!("must not reach the external window")
    });
    assert_ne!(result, PASS);
    assert_eq!(proof[1], 0);
    assert_eq!(proof[4], 0);
    assert!(s.sys.moved.iter().all(|(_, id, _, _)| *id == 77));
    let (mut s, g, w) = installed_fixture();
    let (result, proof) = installed::replay(&mut s, w, &g, || g.ok.set(false));
    assert_ne!(result, PASS);
    assert_eq!(proof[1], 0);
    assert_eq!(proof[4], 1);
    assert!(s.sys.moved.iter().all(|(_, id, _, _)| *id == 77));
}
#[cfg(target_os = "macos")]
#[test]
fn loss_of_companion_or_input_refuses_qualification_but_returns_the_original_once() {
    for lost_companion in [false, true] {
        let (mut state, mut guard, window) = installed_fixture();
        guard.lose_companion_while_hidden = lost_companion;
        guard.input_observed = lost_companion;
        let (status, proof) = installed::replay(&mut state, window, &guard, || ());
        assert_ne!(status, PASS);
        assert_eq!(proof[2], 2, "independent returned-window proofs");
        assert!(state.owned.is_empty() && state.slots.is_empty());
        let moves: Vec<_> = state.sys.moved.iter().filter(|action| action.1 == window.number).collect();
        assert_eq!(moves.len(), 2);
        assert_eq!(moves[1].2, 10);
        assert_eq!(state.sys.spaces, Rows::from([10]));
    }
}
#[cfg(target_os = "macos")]
#[test]
fn replacement_ax_object_preserves_ownership_without_an_unproven_restore_or_resend() {
    let (mut s, g, w) = installed_fixture();
    s.sys.replace_fixture_when_parked = true;
    let (result, proof) = installed::replay(&mut s, w, &g, || ());
    assert_ne!(result, PASS);
    assert_eq!(proof[6], 0);
    assert_eq!(
        s.sys.moved.iter().filter(|(_, id, _, _)| *id == 5).count(),
        1
    );
    assert!(s.owned.contains_key(&w));
    assert!(s.sys.spaces.contains(&102));
}
#[cfg(target_os = "macos")]
#[test]
fn own_pid_cannot_be_misrepresented_as_the_external_ordinary_subject() {
    let (mut s, g, mut w) = installed_fixture();
    w.pid = std::process::id() as i32;
    let (result, _) = installed::replay(&mut s, w, &g, || panic!("must refuse"));
    assert_eq!(result, FAIL);
    assert!(s.sys.moved.is_empty() && !s.sys.opened_probe);
}
fn request(number: u32, operation: u32, i: u8) -> Request {
    Request {
        backend: SPACES,
        operation,
        intent: [i; 16],
        group: [4; 16],
        display: [5; 16],
        native_space: [6; 16],
        member: [number as u8; 16],
        pid: std::process::id() as i32,
        window: number,
        birth: 123,
        native_id: 10,
        generation: [8; 16],
        lifetime: [number as u8; 16],
        frame: Rect {
            x: 0.,
            y: 0.,
            width: 100.,
            height: 100.,
        },
        ..Request::default()
    }
}
fn setup() -> (State<Fake>, Guard) {
    let mut s = State::new(Fake::new());
    for n in 1..=3 {
        s.sys.add(&request(n, READBACK, 1));
    }
    (
        s,
        Guard {
            ok: Cell::new(true),
            approved: None,
            lose_companion_while_hidden: false,
            input_observed: true,
        },
    )
}
#[test]
fn symbols_do_not_qualify_and_foreign_or_missing_fixture_cannot_probe() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, PROBE, 1), &a).status, UNKNOWN);
    assert_eq!(s.run(&request(1, HIDE, 2), &a).status, UNSUPPORTED);
    let mut r = request(1, TRIAL, 3);
    r.pid += 1;
    assert_eq!(s.run(&r, &a).status, FAIL);
    assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty());
}
#[test]
fn distinct_routes_need_their_own_actual_trial_and_destruction() {
    for (route, flag) in [(Route::Classic, TRIAL_CLASSIC), (Route::Bridge, 0)] {
        let (mut s, a) = setup();
        let mut r = request(1, TRIAL, 1);
        r.flags = flag;
        assert_eq!(s.run(&r, &a).status, PASS);
        assert_eq!(s.route, Some(route));
        assert_eq!(s.sys.moved, vec![(route, 1, 101, 7), (route, 1, 10, 15)]);
        assert_eq!(s.sys.destroyed, vec![101]);
        assert_eq!(s.sys.spaces, Rows::from([10]));
        assert_eq!(s.run(&request(1, HEALTH, 2), &a).status, PASS);
    }
}
#[test]
fn two_exact_siblings_use_one_group_space_and_bystander_never_moves() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    let ah = s.run(&request(1, HIDE, 2), &a);
    let bh = s.run(&request(2, HIDE, 3), &a);
    assert_eq!((ah.status, bh.status), (PASS, PASS));
    assert_eq!(ah.native_id, bh.native_id);
    assert_eq!(s.run(&request(2, READBACK, 4), &a).flags & HIDDEN, HIDDEN);
    let shown = s.run(&request(2, SHOW, 5), &a);
    assert_eq!((shown.status, shown.native_id), (PASS, 10));
    assert!(s.sys.spaces.contains(&ah.native_id));
    assert_eq!(s.run(&request(1, RESTORE, 6), &a).status, PASS);
    assert!(!s.sys.spaces.contains(&ah.native_id));
    assert!(s.sys.moved.iter().all(|m| m.1 != 3));
}
#[test]
fn uninitialized_inactive_desktop_is_observed_without_becoming_an_authorized_home() {
    let (mut s, a) = setup();
    let home = s.sys.desktops(1).unwrap()[0];
    s.sys.managed_roster = vec![Desktop { id: 1, uuid: [0; 16], current: 0, ..home }, home];
    s.sys.spaces.insert(1);
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    assert_eq!(s.run(&request(1, HIDE, 2), &a).status, PASS);
    assert_eq!(s.run(&request(1, SHOW, 3), &a).status, PASS);
    assert_eq!(s.sys.spaces, Rows::from([1, 10]));
    assert_eq!(s.sys.managed_roster[0].uuid, [0; 16], "no fabricated native identity");
    let count = s.sys.moved.len();
    let mut invented = request(1, HIDE, 4);
    invented.native_id = 1;
    invented.native_space = [9; 16];
    assert_ne!(s.run(&invented, &a).status, PASS);
    assert_eq!(s.sys.moved.len(), count);
}
#[test]
fn unknown_uuid_never_authorizes_current_or_retained_home_and_stays_in_the_baseline() {
    let (mut s, a) = setup();
    let home = s.sys.desktops(1).unwrap()[0];
    let bound = Lease::from(&request(1, HIDE, 1)).unwrap().slot.home;
    s.sys.managed_roster = vec![Desktop { id: 1, uuid: [0; 16], current: 0, ..home }, home];
    let baseline = s.topology(1, bound).unwrap();
    s.sys.managed_roster[0].uuid = [7; 16];
    assert!(s.scope(1, bound, &baseline, &a).is_err(), "metadata change is still an interruption");
    for current in [0, 1] {
        s.sys.managed_roster = vec![Desktop { uuid: [0; 16], current, ..home },
            Desktop { id: 11, uuid: [8; 16], current: 1-current, ..home }];
        assert!(s.topology(1, bound).is_err(), "unknown current={current} home is never actionable");
    }
    assert!(s.sys.moved.is_empty());
}
#[test]
fn different_catalogue_generation_cannot_resume_a_parked_window() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    assert_eq!(s.run(&request(1, HIDE, 2), &a).status, PASS);
    let writes = s.sys.moved.len();
    let mut other = request(1, RESTORE, 3);
    other.generation = [11; 16];
    assert_ne!(s.run(&other, &a).status, PASS);
    assert_eq!((s.sys.moved.len(), s.owned.len()), (writes, 1));
    assert_eq!(s.run(&request(1, RESTORE, 4), &a).status, PASS);
}
#[test]
fn readback_failure_never_replays_an_accepted_ambiguous_move() {
    let (mut s, a) = setup();
    s.sys.no_effect = true;
    let r = request(1, TRIAL, 1);
    let outcome = s.run(&r, &a);
    assert_eq!(outcome.status, TIMEOUT);
    assert_eq!(s.sys.moved.len(), 1);
    assert_eq!(s.sys.destroyed.len(), 1);
    assert_ne!(s.run(&r, &a).status, PASS);
    assert_eq!(s.sys.moved.len(), 1);
    assert_ne!(s.run(&request(1, HEALTH, 2), &a).status, PASS);
}
#[test]
fn changed_ax_object_or_process_birth_prevents_restoring_a_reused_window_number() {
    for change_birth in [false, true] {
        let (mut s, a) = setup();
        assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
        s.run(&request(1, HIDE, 2), &a);
        let before = s.sys.moved.len();
        let t = s.sys.windows.get_mut(&1).unwrap();
        if change_birth {
            t.0.birth += 1;
        } else {
            t.2 += 1;
        }
        assert_ne!(s.run(&request(1, RESTORE, 3), &a).status, PASS);
        assert_eq!(s.sys.moved.len(), before);
        // A changed AX reference is unresolved ownership of the same process;
        // a different process birth proves the original lifetime has ended.
        assert_eq!(s.owned.len(), if change_birth { 0 } else { 1 });
        assert_eq!(s.slots.len(), 1);
    }
}
#[test]
fn bystander_in_parking_space_prevents_writes_and_destruction() {
    let (mut s, a) = setup();
    s.run(&request(1, TRIAL, 1), &a);
    s.run(&request(1, HIDE, 2), &a);
    s.sys.bystander = true;
    let n = s.sys.moved.len();
    assert_ne!(s.run(&request(1, RESTORE, 3), &a).status, PASS);
    assert_eq!(s.sys.moved.len(), n);
    assert_eq!(s.sys.destroyed.len(), 1);
    assert_eq!(s.run(&request(1, HEALTH, 4), &a).status, UNKNOWN);
}
#[test]
fn minimized_changes_takeover_and_connection_loss_do_not_authorize_a_move() {
    for case in 0..4 {
        let (mut s, a) = setup();
        s.run(&request(1, TRIAL, 1), &a);
        let n = s.sys.moved.len();
        match case {
            0 => s.sys.windows.get_mut(&1).unwrap().3 = true,
            1 => s.sys.switch_topology = true,
            2 => s.sys.connection += 1,
            _ => a.ok.set(false),
        }
        assert_ne!(s.run(&request(1, HIDE, 2), &a).status, PASS);
        assert_eq!(s.sys.moved.len(), n);
    }
}

#[test]
fn health_is_revoked_on_three_late_observations_in_one_minute() {
    let (mut s, _) = setup();
    let now = Instant::now();
    s.record_late(now);
    s.record_late(now + Duration::from_secs(1));
    s.record_late(now + Duration::from_secs(60));
    assert!(!s.failed);
    s.record_late(now + Duration::from_secs(60));
    assert!(s.failed);
}
#[test]
fn source_drift_is_refused_before_creator_or_window_operations() {
    let (mut s, a) = setup();
    let mut r = request(1, TRIAL, 1);
    r.frame.width += 10.;
    assert_ne!(s.run(&r, &a).status, PASS);
    assert!(s.sys.moved.is_empty());
    assert_eq!(s.sys.next, 100);
}

#[test]
fn repeated_input_id_does_not_submit_a_second_window_action() {
    let (mut s, a) = setup();
    s.run(&request(1, TRIAL, 1), &a);
    let r = request(1, HIDE, 2);
    assert_eq!(s.run(&r, &a).status, PASS);
    let before = s.sys.moved.len();
    assert_ne!(s.run(&r, &a).status, PASS);
    assert_eq!(s.sys.moved.len(), before);
    assert_eq!(s.run(&request(1, RESTORE, 3), &a).status, PASS);
}

#[test]
fn passive_worker_tick_freezes_after_external_change_and_never_dispatches_recovery() {
    let (mut s, a) = setup();
    s.run(&request(1, TRIAL, 1), &a);
    s.run(&request(1, HIDE, 2), &a);
    let writes = s.sys.moved.len();
    s.sys.windows.get_mut(&1).unwrap().1 = 10;
    s.observe_health();
    assert!(s.failed);
    assert_eq!(s.sys.moved.len(), writes);
    assert_ne!(s.run(&request(2, HIDE, 3), &a).status, PASS);
    assert_eq!(s.run(&request(1, RESTORE, 4), &a).status, PASS);
    assert_eq!(s.sys.moved.len(), writes);
    assert!(s.slots.is_empty());
}

#[test]
fn return_reobserves_an_unavailable_sample_but_never_accepts_a_replaced_original_witness() {
    for replaced in [false, true] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
        let window = state.sys.windows[&1].0;
        let original_witness = state.owned[&window].witness;
        state.sys.unavailable_first_return_read = true;
        state.sys.replace_fixture_on_return = replaced;
        let writes = state.sys.moved.len();
        let result = state.run(&request(1, SHOW, 3), &guard);
        assert_eq!(state.sys.moved.len(), writes + 1, "observation retry must not repeat the move");
        if replaced {
            assert_eq!((result.status, result.detail), (UNKNOWN, Why::Identity as u32));
            assert_eq!(state.owned[&window].witness, original_witness);
            assert!(state.failed && !state.slots.is_empty());
        } else {
            assert_eq!(result.status, PASS);
            assert!(state.owned.is_empty() && state.slots.is_empty());
            assert!(!state.failed);
        }
    }
}

fn launch_request(op: u32) -> Request {
    Request {
        backend: SPACES,
        operation: op,
        intent: [17; 16],
        epoch: 1,
        timeout_ms: 2000,
        ..Request::default()
    }
}

#[test]
fn same_app_siblings_and_a_foreign_app_share_a_hidden_group_without_moving_the_bystander() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    let mut foreign = request(3, HIDE, 4);
    foreign.pid += 1;
    s.sys.windows.get_mut(&3).unwrap().0.pid = foreign.pid;
    assert_eq!(s.run(&request(1, HIDE, 2), &a).status, PASS);
    assert_eq!(s.run(&foreign, &a).status, PASS);
    let hidden = s.sys.windows[&1].1;
    assert_eq!(s.sys.windows[&3].1, hidden, "cross-app members share the group's hidden Space");
    assert_eq!(s.sys.windows[&2].1, 10, "same-app sibling is independently visible");
    let result = s.run(&launch_request(RELEASE_SPACES), &a);
    assert_eq!((result.status, result.owned), (PASS, 0));
    assert!(s.owned.is_empty() && s.slots.is_empty());
    assert!(s.sys.windows.values().all(|w| w.1 == 10));
    assert!(s.sys.moved.iter().all(|(route, _, _, _)| *route == Route::Bridge));
}

#[test]
fn switching_native_desktops_does_not_fail_hidden_groups_or_move_any_window() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    assert_eq!(s.run(&request(1, HIDE, 2), &a).status, PASS);
    s.sys.spaces.insert(11);
    s.sys.managed_roster = vec![
        Desktop { display: [5; 16], uuid: [6; 16], id: 10, kind: 0, current: 0 },
        Desktop { display: [5; 16], uuid: [7; 16], id: 11, kind: 0, current: 1 },
    ];
    let writes = s.sys.moved.len();
    s.observe_health();
    assert!(!s.failed);
    assert_eq!(s.run(&request(1, HEALTH, 3), &a).status, PASS);
    assert_eq!(s.sys.moved.len(), writes);
    let result = s.run(&launch_request(RELEASE_SPACES), &a);
    assert_eq!((result.status, result.owned), (PASS, 0));
    assert_eq!(s.sys.windows[&1].1, 10, "quit restores to the window's own Desktop");
    assert_eq!(s.sys.managed_roster[1].current, 1, "no desktop switch was requested");
}

#[test]
fn closed_and_reused_window_ids_are_forgotten_without_moving_the_new_lifetime() {
    for reused in [false, true] {
        let (mut s, a) = setup();
        assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
        assert_eq!(s.run(&request(1, HIDE, 2), &a).status, PASS);
        if reused {
            let row = s.sys.windows.get_mut(&1).unwrap();
            row.0.birth += 1;
            row.1 = 10;
        } else { s.sys.windows.remove(&1); }
        let writes = s.sys.moved.len();
        let result = s.run(&launch_request(RELEASE_SPACES), &a);
        assert_eq!((result.status, result.owned), (PASS, 0));
        assert_eq!(s.sys.moved.len(), writes, "no move is sent to a departed lifetime");
        assert_eq!(s.sys.spaces, Rows::from([10]));
    }
}

#[test]
fn release_cleans_an_empty_failed_candidate_without_claiming_foreign_window_success() {
    let (mut s, mut a) = setup();
    a.approved = Some(Route::Bridge);
    assert_eq!(s.run(&launch_request(RELEASE_SPACES), &a).status, PASS);
    assert!(s.sys.moved.is_empty() && s.route.is_none());
    assert_eq!(s.run(&request(1, PROBE, 1), &a).status, UNKNOWN);
}

#[test]
fn yellow_button_adoption_moves_the_minimized_window_before_removing_its_dock_item() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    s.sys.windows.get_mut(&1).unwrap().3 = true;
    s.sys.windows.get_mut(&2).unwrap().3 = true; // A pre-existing Dock item is a bystander.
    let hidden = s.run(&request(1, HIDE_MINIMIZED, 2), &a);
    assert_eq!(hidden.status, PASS);
    assert_eq!(s.sys.minimize_writes, vec![(1, hidden.native_id, false)]);
    assert_ne!(hidden.native_id, 10, "the Dock item is removed only inside the hidden Space");
    assert!(s.sys.windows[&2].3 && s.sys.windows[&2].1 == 10);
    let back = s.run(&request(1, SHOW, 3), &a);
    assert_eq!(back.status, PASS);
    assert_eq!(s.sys.windows[&1].1, 10);
    assert!(!s.sys.windows[&1].3);
}

#[test]
fn failed_yellow_button_adoption_restores_membership_and_keeps_the_native_minimized_state() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    s.sys.windows.get_mut(&1).unwrap().3 = true;
    s.sys.refuse_unminimize = true;
    assert_ne!(s.run(&request(1, HIDE_MINIMIZED, 2), &a).status, PASS);
    assert!(!s.owned.is_empty());
    let released = s.run(&launch_request(RELEASE_SPACES), &a);
    assert_eq!((released.status, released.owned), (PASS, 0));
    assert_eq!(s.sys.windows[&1].1, 10);
    assert!(s.sys.windows[&1].3);
    assert!(s.sys.minimize_writes.is_empty());
}

#[test]
fn macos_pulling_an_unminimized_window_home_is_never_reported_as_hidden() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    s.sys.windows.get_mut(&1).unwrap().3 = true;
    s.sys.unminimize_returns_to_desktop = true;
    let hidden = s.run(&request(1, HIDE_MINIMIZED, 2), &a);
    assert_ne!(hidden.status, PASS);
    assert_eq!(hidden.flags & HIDDEN, 0);
    assert!(s.failed && !s.owned.is_empty());
    let released = s.run(&launch_request(RELEASE_SPACES), &a);
    assert_eq!((released.status, released.owned), (PASS, 0));
    assert!(s.slots.is_empty());
    assert_eq!(s.sys.windows[&1].1, 10);
}

#[test]
fn approved_launch_arms_only_its_evidence_route_after_its_own_canary_dies() {
    for route in [Route::Classic, Route::Bridge] {
        let (mut s, mut guard) = setup();
        let passive = s.run(&request(1, PROBE, 8), &guard);
        assert_eq!(passive.status, UNKNOWN);
        assert_eq!(s.run(&launch_request(LAUNCH), &guard).status, UNSUPPORTED);
        assert!(s.sys.moved.is_empty() && !s.sys.opened_probe);
        guard.approved = Some(route);
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!(
            (result.status, result.owned, result.native_id),
            (PASS, 0, 10)
        );
        assert_eq!(
            result.flags,
            CG_VALID | MEMBERSHIP_VALID | HEALTHY | PROBE_CLEAN_FLAGS
        );
        assert_eq!(s.sys.moved, vec![(route, 77, 101, 7), (route, 77, 10, 15)]);
        assert_eq!(s.sys.destroyed, vec![101]);
        assert_eq!(s.sys.probe_closes, 1);
        assert!(!s.sys.windows.contains_key(&77));
        assert_eq!(s.run(&request(1, HEALTH, 3), &guard).status, PASS);
        assert_eq!(s.run(&launch_request(LAUNCH), &guard).status, FAIL);
        assert_eq!(s.sys.moved.len(), 2);
    }
}
#[test]
fn cleanup_waits_for_delayed_probe_close_without_reissuing_or_arming_backend() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.defer_probe_close = true;
    let waiting = s.run(&launch_request(LAUNCH), &guard);
    assert_eq!(waiting.status, UNKNOWN);
    assert!(waiting.owned > 0 && s.route.is_none());
    assert_ne!(s.run(&request(1, HIDE, 4), &guard).status, PASS);
    assert_eq!(s.sys.probe_closes, 1);
    assert!(s.sys.destroyed.is_empty() && s.sys.spaces.contains(&101));
    s.sys.windows.remove(&77);
    let closed = s.run(&launch_request(CLEAN_LAUNCH), &guard);
    assert_eq!((closed.status, closed.owned), (PASS, 0));
    assert_eq!(closed.flags & PROBE_CLEAN_FLAGS, PROBE_CLEAN_FLAGS);
    assert_eq!(closed.flags & HEALTHY, 0);
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.moved.len(), 2);
    assert_eq!(s.sys.destroyed, vec![101]);
    assert!(s.route.is_none());
}
#[test]
fn windowserver_close_lag_keeps_owned_space_and_only_cleanup_can_release_it() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.cg_keeps_closed_probe = true;
    let result = s.run(&launch_request(LAUNCH), &guard);
    assert_eq!(result.status, UNKNOWN);
    assert_eq!(s.sys.probe_closes, 1);
    assert!(!s.sys.windows.contains_key(&77));
    assert!(s.sys.spaces.contains(&101) && s.sys.destroyed.is_empty() && s.route.is_none());
    s.sys.cg_keeps_closed_probe = false;
    assert_eq!(s.run(&launch_request(CLEAN_LAUNCH), &guard).status, PASS);
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.destroyed, vec![101]);
    assert!(s.route.is_none());
}
#[test]
fn reordering_managed_spaces_retains_ownership_until_original_order_returns() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    let home = s.sys.desktops(1).unwrap()[0];
    s.sys.managed_roster = vec![
        home,
        Desktop {
            id: 11,
            uuid: [8; 16],
            current: 0,
            ..home
        },
    ];
    s.sys.spaces.insert(11);
    s.sys.reverse_managed_after_hide = true;
    assert_eq!(s.run(&launch_request(LAUNCH), &guard).status, UNKNOWN);
    assert_eq!(s.sys.moved.len(), 1);
    assert!(s.sys.destroyed.is_empty() && s.route.is_none());
    s.sys.reverse_managed_after_hide = false;
    assert_eq!(s.run(&launch_request(CLEAN_LAUNCH), &guard).status, PASS);
    assert!(s.route.is_none());
    assert_eq!(s.sys.spaces, Rows::from([10, 11]));
}
#[test]
fn launch_never_accepts_a_caller_window_or_acquires_a_different_evidence_route() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Classic);
    let mut forged = launch_request(LAUNCH);
    forged.window = 2;
    assert_eq!(s.run(&forged, &guard).status, FAIL);
    let noop = s.run(&launch_request(CLEAN_LAUNCH), &guard);
    assert_eq!((noop.status, noop.owned), (PASS, 0));
    assert!(!s.sys.opened_probe && s.sys.moved.is_empty() && s.sys.destroyed.is_empty());
    guard.approved = Some(Route::Bridge);
    assert_ne!(s.run(&launch_request(CLEAN_LAUNCH), &guard).status, PASS);
}

#[test]
fn changing_external_focus_stops_launch_and_only_original_owner_can_clean_the_canary() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.lose_focus_on_hide = true;
    let failed = s.run(&launch_request(LAUNCH), &guard);
    assert_ne!(failed.status, PASS);
    assert!(failed.owned > 0 && s.route.is_none());
    let writes = s.sys.moved.len();
    guard.approved = Some(Route::Classic);
    assert_ne!(s.run(&launch_request(CLEAN_LAUNCH), &guard).status, PASS);
    assert_eq!(s.sys.moved.len(), writes);
    // Independently observed return to the original focus, with no input or activation by the backend.
    s.sys.focus_changed = false;
    s.sys.lose_focus_on_hide = false;
    guard.approved = Some(Route::Bridge);
    let cleaned = s.run(&launch_request(CLEAN_LAUNCH), &guard);
    assert_eq!((cleaned.status, cleaned.owned), (PASS, 0));
    assert_eq!(cleaned.flags & PROBE_CLEAN_FLAGS, PROBE_CLEAN_FLAGS);
    assert!(s.sys.moved.iter().all(|row| row.1 == 77));
    assert!(!s.sys.windows.contains_key(&77) && s.route.is_none());
}
#[test]
fn release_after_host_loss_cleans_the_original_canary_without_focus_or_route_qualification() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.lose_focus_on_hide = true;
    assert_ne!(s.run(&launch_request(LAUNCH), &guard).status, PASS);
    assert!(s.sys.focus_changed && !s.owned.is_empty());
    let released = s.run(&launch_request(RELEASE_SPACES), &guard);
    assert_eq!((released.status, released.owned), (PASS, 0));
    assert_eq!(released.flags & (HEALTHY | OWNED), 0);
    assert!(s.sys.focus_changed, "cleanup must not steal focus back from the user");
    assert!(s.owned.is_empty() && s.slots.is_empty() && s.route.is_none());
    assert!(s.sys.moved.iter().all(|row| row.1 == 77));
    assert!(!s.sys.windows.contains_key(&77));
    assert_eq!(s.sys.spaces, Rows::from([10]));
    assert_ne!(s.run(&request(1, HIDE, 9), &guard).status, PASS);
}
