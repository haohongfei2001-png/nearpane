// Synthetic system implementing the same single-window reverse and forward membership reads as Darwin.
use super::*;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

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

// Configured only after enrollment, then armed by the single actual move. These
// costs advance the existing virtual clock, never an OS thread or test deadline.
#[derive(Default)]
struct MoveReadProbe {
    began: Cell<Option<Instant>>,
    window: Cell<u32>,
    target: Cell<u64>,
    ack_forward_cost: Duration,
    ack_target_cost: Duration,
    ack_other_cost: Duration,
    missing_forward_for: Duration,
    missing_reverse: bool,
    present_in_other: bool,
    see_costs: RefCell<VecDeque<Duration>>,
    see_calls: Cell<u32>,
    fault_on_see: Option<(u32, Why)>,
    changed_frame_on_see: Option<u32>,
    desktop_costs: BTreeMap<u32, Duration>,
    desktop_calls: Cell<u32>,
    revoke_on_see: Option<(u32, Rc<Cell<bool>>)>,
    revoke_on_desktop: Option<(u32, Rc<Cell<bool>>)>,
    changed_scope_on_desktop: Option<u32>,
}
struct MoveAuthority(Rc<Cell<bool>>);
impl Authority for MoveAuthority {
    fn active(&self) -> Check<()> { self.observation() }
    fn observation(&self) -> Check<()> {
        if self.0.get() { Ok(()) } else { Err(Fault(CANCELLED, Why::Stale)) }
    }
}
#[derive(Default)]
struct Fake {
    clock: Cell<Option<Instant>>,
    windows: BTreeMap<u32, (Window, u64, u64, bool)>,
    departure_read_costs: BTreeMap<u32, Duration>,
    unavailable_departures: BTreeSet<u32>,
    departure_observations: RefCell<Vec<Window>>,
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
    probe_read_costs: VecDeque<Duration>,
    probe_read_focus: VecDeque<(u32, i32)>,
    probe_read_window: Option<Window>,
    probe_read_homes: VecDeque<u64>,
    probe_operations: Vec<launch::PanelOp>,
    probe_reads_before_first_move: Option<usize>,
    defer_probe_close: bool,
    cg_keeps_closed_probe: bool,
    probe_absence_failures: Cell<u32>,
    probe_absence_reads: Cell<u32>,
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
    cannot_complete_return_reads: u32,
    pending_cannot_complete_return_reads: Cell<u32>,
    return_binding_read_cost: Duration,
    return_binding_observations: Cell<u32>,
    cannot_complete_minimized_reads: Cell<u32>,
    cannot_complete_read_cost: Duration,
    surface_read_cost: Duration,
    minimized_observations: Cell<u32>,
    confirmed_document_minimized: bool,
    minimize_writes: Vec<(u32, u64, bool)>,
    refuse_unminimize: bool,
    unminimize_returns_to_desktop: bool,
    unminimize_observation_delay: Duration,
    unminimize_observation_unavailable: bool,
    unminimize_started: Option<(u32, Instant)>,
    unminimize_extra_space: Option<(u64, Duration)>,
    unminimize_read_cost: Duration,
    unminimize_animated_reads: Cell<u32>,
    move_read_probe: Option<MoveReadProbe>,
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
    fn transition_space(&self, number: u32) -> Option<u64> {
        let (window, started) = self.unminimize_started?;
        let (space, duration) = self.unminimize_extra_space?;
        (window == number && self.now().saturating_duration_since(started) < duration).then_some(space)
    }
    fn moved_reads(&self) -> Option<&MoveReadProbe> {
        self.move_read_probe.as_ref().filter(|probe| probe.began.get().is_some())
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
        let mut changed_scope = false;
        if let Some(probe) = self.moved_reads() {
            let call = probe.desktop_calls.get() + 1;
            probe.desktop_calls.set(call);
            self.wait(probe.desktop_costs.get(&call).copied().unwrap_or_default());
            if let Some((at, allowed)) = &probe.revoke_on_desktop {
                if call == *at { allowed.set(false); }
            }
            changed_scope = probe.changed_scope_on_desktop.is_some_and(|at| call >= at);
        }
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
            kind: if self.switch_topology || changed_scope { 4 } else { 0 },
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
        if let Some(probe) = self.moved_reads().filter(|probe| probe.see_calls.get() == 0) {
            let target = s == probe.target.get();
            self.wait(if target { probe.ack_target_cost } else { probe.ack_other_cost });
            if target && probe.missing_reverse { set.remove(&u64::from(probe.window.get())); }
            if !target && probe.present_in_other { set.insert(u64::from(probe.window.get())); }
        }
        if self.bystander && s != 10 {
            set.insert(999);
        }
        for &window in self.windows.keys() {
            if self.transition_space(window) == Some(s) { set.insert(u64::from(window)); }
        }
        Ok(set)
    }
    fn spaces(&self, _: i32, w: u32) -> Check<Rows> {
        if let Some(probe) = self.moved_reads()
            .filter(|probe| probe.window.get() == w && probe.see_calls.get() == 0) {
            self.wait(probe.ack_forward_cost);
            if self.now().duration_since(probe.began.get().unwrap()) < probe.missing_forward_for {
                return Ok(Rows::new());
            }
        }
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
        let mut spaces = self
            .windows
            .get(&w)
            .map(|r| Rows::from([r.1]))
            .unwrap_or_default();
        if let Some(extra) = self.transition_space(w) { spaces.insert(extra); }
        Ok(spaces)
    }
    fn bind(&self, w: Window) -> Check<u64> {
        let t = self.windows[&w.number];
        if t.0 == w && !t.3 {
            Ok(t.2)
        } else {
            Err(unknown(Why::Identity))
        }
    }
    fn adopt_minimized(&self, w: Window, original: &u64) -> Check<u64> {
        let t = self.windows[&w.number];
        let same = *original == t.2 || (*original >> 32 == t.2 && *original as u32 == w.number);
        if t.0 == w && t.3 && same { Ok((t.2 << 32) | u64::from(w.number)) }
        else { Err(unknown(Why::MinimizedOrAX)) }
    }
    fn minimized(&self, witness: &u64) -> Check<bool> {
        self.minimized_observations.set(self.minimized_observations.get() + 1);
        let unavailable = self.cannot_complete_minimized_reads.get();
        if unavailable > 0 {
            self.cannot_complete_minimized_reads.set(unavailable - 1);
            self.wait(self.cannot_complete_read_cost);
            return Err(unknown(Why::AXCannotComplete));
        }
        if *witness >> 32 > 0 {
            let number = *witness as u32;
            if let Some((pending, since)) = self.unminimize_started {
                if pending == number { self.wait(self.unminimize_read_cost); }
                if pending == number && self.now().saturating_duration_since(since) < self.unminimize_observation_delay {
                    return if self.unminimize_observation_unavailable { Err(unknown(Why::AXCannotComplete)) } else { Ok(true) };
                }
            }
            return Ok(self.windows[&number].3);
        }
        Ok(self.confirmed_document_minimized)
    }
    fn set_minimized(&mut self, w: Window, witness: &u64, minimized: bool) -> Delivery {
        if *witness as u32 != w.number || *witness >> 32 != self.windows[&w.number].2 || self.refuse_unminimize { return Delivery::Refused; }
        let t = self.windows.get_mut(&w.number).unwrap();
        self.minimize_writes.push((w.number, t.1, minimized));
        t.3 = minimized;
        if !minimized && self.unminimize_returns_to_desktop { t.1 = 10; }
        if !minimized { self.unminimize_started = Some((w.number, self.now())); }
        Delivery::Accepted
    }
    fn canary(&mut self, op: launch::PanelOp, guard: &impl Authority) -> Check<launch::Panel> {
        let n = 77;
        self.probe_operations.push(op);
        if op == launch::PanelOp::Read {
            let cost = self.probe_read_costs.pop_front().unwrap_or_default();
            self.wait(cost);
            if let Some(home) = self.probe_read_homes.pop_front() {
                if let Some(window) = self.windows.get_mut(&n) { window.1 = home; }
            }
        }
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
        let (focus_same, focus_read_error) = if op == launch::PanelOp::Read {
            self.probe_read_focus.pop_front().unwrap_or(((!self.focus_changed) as u32, 0))
        } else { ((!self.focus_changed) as u32, 0) };
        let mut panel = launch::Panel {
            number: if self.opened_probe { n } else { 0 },
            pid: std::process::id() as i32,
            birth: 123,
            opened: self.opened_probe as u32,
            registered: exists as u32,
            absent: (!exists) as u32,
            focus_same,
            close_issued: (self.probe_closes > 0) as u32,
            focus_read_error,
        };
        if op == launch::PanelOp::Read {
            if let Some(changed) = self.probe_read_window {
                panel.number = changed.number; panel.pid = changed.pid; panel.birth = changed.birth;
            }
        }
        Ok(panel)
    }
    fn absent(&self, n: u32) -> Check<bool> {
        if n == 77 && self.probe_closes > 0 && !self.windows.contains_key(&n) {
            self.probe_absence_reads.set(self.probe_absence_reads.get() + 1);
            if self.probe_absence_failures.get() > 0 {
                self.probe_absence_failures.set(self.probe_absence_failures.get() - 1);
                return Err(unknown(Why::Readback));
            }
        }
        Ok(!self.windows.contains_key(&n) && !(n == 77 && self.cg_keeps_closed_probe))
    }
    fn departed(&self, w: Window) -> Check<bool> {
        self.departure_observations.borrow_mut().push(w);
        self.wait(self.departure_read_costs.get(&w.number).copied().unwrap_or_default());
        if self.unavailable_departures.contains(&w.number) { return Err(unknown(Why::Readback)); }
        Ok(self.windows.get(&w.number).is_some_and(|r| r.0 != w) || self.absent(w.number)?)
    }
    fn transparent_canary(&self, w: &u64) -> bool {
        *w == 77
    }
    fn surface(&self, w: Window) -> Check<Seen> {
        self.wait(self.surface_read_cost);
        if self.pending_unavailable_read.replace(false) { return Err(unknown(Why::Readback)); }
        let t = self.windows[&w.number];
        if t.0 == w {
            let animated = self.transition_space(w.number).is_some();
            if animated { self.unminimize_animated_reads.set(self.unminimize_animated_reads.get() + 1); }
            Ok(Seen {
                visible: animated || (!t.3 && w.number != 77 && if self.managed_roster.is_empty() { t.1 == 10 }
                    else { self.managed_roster.iter().any(|d| d.id == t.1 && d.current == 1) }),
                rect: if animated { [439., 530., 512., 203.] } else { [0., 0., 100., 100.] },
            })
        } else {
            Err(unknown(Why::Identity))
        }
    }
    fn see(&self, w: Window, lease: &u64) -> Check<Seen> {
        let mut surface = self.surface(w)?;
        let t = self.windows[&w.number];
        self.return_binding_observations.set(self.return_binding_observations.get() + 1);
        if !((t.2 == *lease && !t.3) || (*lease as u32 == w.number && *lease >> 32 == t.2)) {
            return Err(unknown(Why::Identity));
        }
        let unavailable = self.pending_cannot_complete_return_reads.get();
        if unavailable > 0 {
            self.pending_cannot_complete_return_reads.set(unavailable - 1);
            self.wait(self.return_binding_read_cost);
            return Err(unknown(Why::AXCannotComplete));
        }
        if let Some(probe) = self.moved_reads().filter(|probe| probe.window.get() == w.number) {
            let call = probe.see_calls.get() + 1;
            probe.see_calls.set(call);
            self.wait(probe.see_costs.borrow_mut().pop_front().unwrap_or_default());
            if let Some((at, allowed)) = &probe.revoke_on_see {
                if call == *at { allowed.set(false); }
            }
            if let Some((at, fault)) = probe.fault_on_see {
                if call == at { return Err(unknown(fault)); }
            }
            if probe.changed_frame_on_see.is_some_and(|at| call >= at) { surface.rect[0] += 1.; }
        }
        Ok(surface)
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
        if let Some(probe) = &self.move_read_probe {
            probe.began.set(Some(self.now()));
            probe.window.set(w.number);
            probe.target.set(s);
        }
        if self.moved.is_empty() {
            self.probe_reads_before_first_move = Some(self.probe_operations.iter()
                .filter(|op| **op == launch::PanelOp::Read).count());
        }
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
                self.pending_cannot_complete_return_reads.set(self.cannot_complete_return_reads);
                self.return_binding_observations.set(0);
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
fn passive_health_budget_excludes_unrelated_slots_and_visible_bindings() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    let mut other = request(2, HIDE, 3);
    other.group = [9; 16];
    assert_eq!(state.run(&other, &guard).status, PASS);
    assert_eq!(state.run(&request(3, READBACK, 4), &guard).status, PASS);
    let selected = state.sys.windows[&1].0;
    let visible = state.sys.windows[&3].0;
    state.sys.departure_read_costs = BTreeMap::from([
        (1, Duration::from_millis(20)), (2, Duration::from_secs(1)), (3, Duration::from_secs(1))]);
    state.sys.departure_observations.borrow_mut().clear();
    state.sys.return_binding_observations.set(0);
    let writes = state.sys.moved.len();
    let started = state.sys.now();
    state.observe_health();
    assert!(!state.failed);
    assert_eq!(state.sys.now() - started, Duration::from_millis(20));
    assert_eq!(state.sys.departure_observations.borrow().as_slice(), &[selected]);
    assert_eq!(state.sys.return_binding_observations.get(), 2, "the selected original still receives its full paired read");
    assert_eq!(state.owned.len(), 2);
    assert!(state.visible.contains_key(&visible));
    assert_eq!(state.sys.moved.len(), writes);
}

#[test]
fn passive_health_reaps_its_slot_and_still_rejects_a_replaced_occupant() {
    for replaced in [false, true] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
        assert_eq!(state.run(&request(2, HIDE, 3), &guard).status, PASS);
        let selected = state.sys.windows[&1].0;
        let departed = state.sys.windows[&2].0;
        if replaced { state.sys.windows.get_mut(&2).unwrap().0.birth += 1; }
        else { state.sys.windows.remove(&2); }
        state.sys.departure_observations.borrow_mut().clear();
        let writes = state.sys.moved.len();
        state.observe_health();
        assert_eq!(state.sys.departure_observations.borrow().as_slice(), &[selected, departed]);
        assert!(!state.owned.contains_key(&departed));
        assert!(state.owned.contains_key(&selected));
        assert_eq!(state.failed, replaced, "a replacement left in the same Space remains an unowned occupant");
        assert_eq!(state.sys.moved.len(), writes);
    }
}

#[test]
fn passive_health_never_reaps_an_unavailable_departure_read() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    assert_eq!(state.run(&request(2, HIDE, 3), &guard).status, PASS);
    let originals: Vec<_> = state.owned.values().map(|bound| (bound.lease.window, bound.witness)).collect();
    state.sys.unavailable_departures = BTreeSet::from([1, 2]);
    state.sys.departure_observations.borrow_mut().clear();
    let writes = state.sys.moved.len();
    state.observe_health();
    assert!(!state.failed, "the subsequent complete original-window health read remains required");
    assert_eq!(state.sys.departure_observations.borrow().len(), 2);
    for (window, witness) in originals { assert_eq!(state.owned[&window].witness, witness); }
    assert_eq!(state.sys.moved.len(), writes);
}

#[test]
fn passive_health_ends_a_departed_selection_without_reading_or_rebinding_another_window() {
    for replaced in [false, true] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
        let mut other = request(2, HIDE, 3);
        other.group = [9; 16];
        assert_eq!(state.run(&other, &guard).status, PASS);
        let selected = state.sys.windows[&1].0;
        let remaining = state.sys.windows[&2].0;
        if replaced { state.sys.windows.get_mut(&1).unwrap().0.birth += 1; }
        else { state.sys.windows.remove(&1); }
        state.sys.departure_observations.borrow_mut().clear();
        state.sys.minimized_observations.set(0);
        state.sys.return_binding_observations.set(0);
        let writes = state.sys.moved.len();
        state.observe_health();
        assert!(!state.owned.contains_key(&selected));
        assert!(state.owned.contains_key(&remaining));
        assert_eq!(state.sys.departure_observations.borrow().as_slice(), &[selected]);
        assert_eq!(state.sys.minimized_observations.get(), 0);
        assert_eq!(state.sys.return_binding_observations.get(), 0, "no complete sample is claimed for another or replacement window");
        assert_eq!(state.sys.moved.len(), writes);
    }
}

#[test]
fn passive_health_slot_preparation_still_spends_the_original_deadline() {
    for slow_window in [1, 2] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
        assert_eq!(state.run(&request(2, HIDE, 3), &guard).status, PASS);
        state.sys.departure_read_costs.insert(slow_window, Duration::from_millis(700));
        state.sys.minimized_observations.set(0);
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let started = state.sys.now();
        state.observe_health();
        assert_eq!(state.sys.now() - started, Duration::from_millis(700));
        assert!(state.failed && state.owned.len() == 2, "an expired preparation cannot start a fresh 650 ms budget");
        assert_eq!(state.sys.minimized_observations.get(), 0);
        assert_eq!(state.sys.moved.len(), writes);
        assert_eq!(state.sys.destroyed.len(), destroyed);
    }
}

#[test]
fn health_rereads_only_cannot_complete_on_the_original_witness_until_two_complete_samples() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    let window = state.sys.windows[&1].0;
    let witness = state.owned[&window].witness;
    let writes = state.sys.moved.len();
    state.sys.minimized_observations.set(0);
    state.sys.cannot_complete_minimized_reads.set(1);
    state.observe_health();
    assert!(!state.failed);
    assert_eq!(state.sys.minimized_observations.get(), 3, "one unavailable read then two complete positive samples");
    assert_eq!(state.owned[&window].witness, witness);
    assert_eq!(state.sys.moved.len(), writes);
    assert!(state.sys.minimize_writes.is_empty());
}

#[test]
fn native_animation_transport_time_includes_both_complete_health_samples() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    let window = state.sys.windows[&1].0;
    let witness = state.owned[&window].witness;
    let writes = state.sys.moved.len();
    state.sys.minimized_observations.set(0);
    state.sys.cannot_complete_minimized_reads.set(2);
    state.sys.cannot_complete_read_cost = Duration::from_millis(300);
    state.sys.surface_read_cost = Duration::from_millis(20);
    let started = state.sys.now();
    state.observe_health();
    let elapsed = state.sys.now() - started;
    assert!(!state.failed);
    assert!(elapsed > AX_OBSERVATION_BUDGET && elapsed < AX_UNAVAILABLE_RECOVERY_BUDGET);
    assert_eq!(state.sys.minimized_observations.get(), 4, "two transport timeouts then two complete physical samples");
    assert_eq!(state.owned[&window].witness, witness);
    assert_eq!(state.sys.moved.len(), writes);
    assert!(state.sys.minimize_writes.is_empty());
}

#[test]
fn persistent_ax_unavailability_keeps_the_original_lease_and_exhausts_only_the_health_budget() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    let writes = state.sys.moved.len();
    let window = state.sys.windows[&1].0;
    state.sys.cannot_complete_minimized_reads.set(u32::MAX);
    let start = state.sys.now();
    state.observe_health();
    assert!(state.failed && state.owned.contains_key(&window));
    assert_eq!(state.sys.now().duration_since(start), AX_UNAVAILABLE_RECOVERY_BUDGET);
    assert_eq!(state.sys.moved.len(), writes);
}

#[test]
fn a_positive_bad_health_observation_stops_even_after_a_transport_retry() {
    for unavailable in [0, 1] {
        for changed in 0..3 {
            let (mut state, guard) = setup();
            assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
            assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
            let writes = state.sys.moved.len();
            state.sys.minimized_observations.set(0);
            state.sys.cannot_complete_minimized_reads.set(unavailable);
            state.sys.cannot_complete_read_cost = Duration::from_millis(300);
            match changed {
                0 => state.sys.confirmed_document_minimized = true,
                1 => state.sys.windows.get_mut(&1).unwrap().2 += 1,
                _ => state.sys.windows.get_mut(&1).unwrap().1 = 10,
            }
            let start = state.sys.now();
            state.observe_health();
            assert!(state.failed, "positive minimization, replacement and escaped membership are not a transient read");
            assert_eq!(state.sys.minimized_observations.get(), unavailable + 1);
            assert!(state.sys.now().duration_since(start) < Duration::from_millis(650));
            assert_eq!(state.sys.moved.len(), writes);
        }
    }
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

#[test]
fn return_reobserves_ax_transport_once_then_requires_two_complete_samples() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    state.sys.cannot_complete_return_reads = 1;
    let writes = state.sys.moved.len();
    let began = state.sys.now();
    let result = state.run(&request(1, SHOW, 3), &guard);
    assert_eq!(result.status, PASS);
    assert_eq!(state.sys.moved.len(), writes + 1, "an absent AX response never resends the move");
    assert_eq!(state.sys.return_binding_observations.get(), 5,
        "one absent binding read followed by two complete views, each with two positive binding reads");
    assert!(state.sys.now() - began < DEADLINE);
    assert!(state.owned.is_empty() && state.slots.is_empty() && !state.failed);
}

#[test]
fn return_identity_replacement_is_not_masked_by_pending_ax_transport_failure() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
    let window = state.sys.windows[&1].0;
    let original = state.owned[&window].witness;
    state.sys.cannot_complete_return_reads = 1;
    state.sys.replace_fixture_on_return = true;
    let writes = state.sys.moved.len();
    let destroyed = state.sys.destroyed.len();
    let result = state.run(&request(1, SHOW, 3), &guard);
    assert_eq!((result.status, result.detail), (UNKNOWN, Why::Identity as u32));
    assert_eq!(state.sys.moved.len(), writes + 1);
    assert_eq!(state.sys.return_binding_observations.get(), 1, "a positive replacement stops immediately");
    assert_eq!(state.sys.pending_cannot_complete_return_reads.get(), 1);
    assert_eq!(state.owned[&window].witness, original);
    assert_eq!(state.sys.destroyed.len(), destroyed);
    assert!(state.failed && !state.slots.is_empty());
}

#[test]
fn return_ax_transport_exhaustion_keeps_the_lease_and_original_deadline() {
    // A real 150 ms messaging timeout can already consume the entire 120 ms
    // acknowledgement budget. That case must fail without granting a reread.
    for cost in [Duration::ZERO, Duration::from_millis(150)] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS);
        let window = state.sys.windows[&1].0;
        let original = state.owned[&window].witness;
        state.sys.cannot_complete_return_reads = u32::MAX;
        state.sys.return_binding_read_cost = cost;
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let began = state.sys.now();
        let result = state.run(&request(1, SHOW, 3), &guard);
        assert_eq!((result.status, result.detail), (TIMEOUT, Why::Uncertain as u32));
        assert_eq!(state.sys.now() - began, DEADLINE.max(cost), "no fresh budget starts after the AX miss");
        if cost >= DEADLINE { assert_eq!(state.sys.return_binding_observations.get(), 1); }
        assert_eq!(state.sys.moved.len(), writes + 1);
        assert_eq!(state.owned[&window].witness, original);
        assert_eq!(state.owned[&window].pending_target.get(), Some(10));
        assert_eq!(state.sys.destroyed.len(), destroyed);
        assert!(state.failed && !state.slots.is_empty());
    }
}

fn move_probe_fixture(hidden: bool, probe: MoveReadProbe) -> (State<Fake>, Guard) {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    if !hidden { assert_eq!(state.run(&request(1, HIDE, 2), &guard).status, PASS); }
    state.sys.move_read_probe = Some(probe);
    (state, guard)
}

fn assert_pending_return(state: &State<Fake>, original: (Lease, u64), writes: usize, destroyed: usize) {
    let bound = &state.owned[&original.0.window];
    assert_eq!(bound.lease, original.0);
    assert_eq!(bound.witness, original.1);
    assert_eq!(bound.pending_target.get(), Some(10));
    assert_eq!(state.sys.moved.len(), writes + 1, "confirmation never resends the move");
    assert_eq!(state.sys.destroyed.len(), destroyed, "uncertain proof cannot destroy the retained Space");
    assert!(state.failed && !state.slots.is_empty());
}

#[test]
fn timely_move_ack_allows_two_slow_complete_positive_views() {
    for hidden in [false, true] {
        for ack_ms in [0, 100] {
            let (mut state, guard) = move_probe_fixture(hidden, MoveReadProbe {
                ack_forward_cost: Duration::from_millis(ack_ms),
                see_costs: RefCell::new(VecDeque::from([Duration::from_millis(84); 4])),
                ..Default::default()
            });
            let writes = state.sys.moved.len();
            let result = state.run(&request(1, if hidden { HIDE } else { SHOW }, 3), &guard);
            let probe = state.sys.move_read_probe.as_ref().unwrap();
            assert_eq!(result.status, PASS, "a timely membership ACK is followed by both full original-AX views");
            assert_eq!(probe.see_calls.get(), 4);
            assert_eq!(state.sys.now() - probe.began.get().unwrap(), Duration::from_millis(ack_ms + 340),
                "the first view starts immediately after ACK; only the original inter-view wait remains");
            assert_eq!(state.sys.moved.len(), writes + 1);
            assert!(state.strikes.is_empty(), "slow all-positive observations are not membership/AX misses");
            assert!(!state.failed);
            assert_eq!(state.owned.is_empty(), !hidden);
        }
    }
}

#[test]
fn late_or_incomplete_move_ack_never_starts_full_confirmation() {
    for failure in 0..7 {
        let mut probe = MoveReadProbe::default();
        match failure {
            0 => probe.ack_forward_cost = DEADLINE,
            1 => probe.ack_target_cost = DEADLINE,
            2 => probe.ack_other_cost = DEADLINE,
            // Desktop call 2 is the scope read after a positive ACK, not its
            // preceding scope read. Its own latency must count toward 120 ms.
            3 => { probe.desktop_costs.insert(2, DEADLINE); }
            4 => probe.missing_forward_for = Duration::from_millis(121),
            5 => probe.missing_reverse = true,
            _ => probe.present_in_other = true,
        }
        let (mut state, guard) = move_probe_fixture(false, probe);
        let window = state.sys.windows[&1].0;
        let original = (state.owned[&window].lease, state.owned[&window].witness);
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let result = state.run(&request(1, SHOW, 3), &guard);
        let probe = state.sys.move_read_probe.as_ref().unwrap();
        assert_eq!((result.status, result.detail), (TIMEOUT, Why::Uncertain as u32), "ACK case {failure}");
        assert_eq!(state.sys.now() - probe.began.get().unwrap(), DEADLINE);
        assert_eq!(probe.see_calls.get(), 0, "no timely placement, no confirmation-budget read");
        assert_pending_return(&state, original, writes, destroyed);
    }
}

#[test]
fn first_and_second_positive_views_share_the_original_move_confirmation_deadline() {
    for (ack_ms, costs, expected_reads, elapsed_ms) in [
        (0, [325, 325, 0, 0], 2, 650),
        (0, [0, 0, 323, 323], 4, 650),
        (100, [140, 140, 140, 140], 4, 664),
    ] {
        let (mut state, guard) = move_probe_fixture(false, MoveReadProbe {
            ack_forward_cost: Duration::from_millis(ack_ms),
            see_costs: RefCell::new(costs.into_iter().map(Duration::from_millis).collect()),
            ..Default::default()
        });
        let window = state.sys.windows[&1].0;
        let original = (state.owned[&window].lease, state.owned[&window].witness);
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let result = state.run(&request(1, SHOW, 3), &guard);
        let probe = state.sys.move_read_probe.as_ref().unwrap();
        assert_eq!((result.status, result.detail), (TIMEOUT, Why::Uncertain as u32));
        assert_eq!(probe.see_calls.get(), expected_reads);
        assert_eq!(state.sys.now() - probe.began.get().unwrap(), Duration::from_millis(elapsed_ms));
        assert_pending_return(&state, original, writes, destroyed);
    }
}

#[test]
fn post_view_scope_latency_and_authority_revocation_cannot_seal_a_move() {
    // Post-move Desktop reads: ACK before/after (1/2), view 1 before/inside/after
    // (3/4/5), view 2 before/inside/after (6/7/8). Probe cost/revocation happens
    // inside that native read, after scope has checked Authority on entry.
    for failure in 0..7 {
        let allowed = Rc::new(Cell::new(true));
        let mut probe = MoveReadProbe::default();
        let expected = match failure {
            0 => { probe.desktop_costs.insert(5, MOVE_CONFIRMATION_BUDGET); (TIMEOUT, Why::Uncertain) }
            1 => { probe.desktop_costs.insert(8, Duration::from_millis(646)); (TIMEOUT, Why::Uncertain) }
            2 => { probe.revoke_on_desktop = Some((2, allowed.clone())); (CANCELLED, Why::Stale) }
            3 => { probe.revoke_on_see = Some((2, allowed.clone())); (CANCELLED, Why::Stale) }
            4 => { probe.revoke_on_see = Some((4, allowed.clone())); (CANCELLED, Why::Stale) }
            5 => { probe.revoke_on_desktop = Some((8, allowed.clone())); (CANCELLED, Why::Stale) }
            _ => { probe.changed_scope_on_desktop = Some(8); (UNKNOWN, Why::Scope) }
        };
        let (mut state, _) = move_probe_fixture(false, probe);
        let window = state.sys.windows[&1].0;
        let original = (state.owned[&window].lease, state.owned[&window].witness);
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let result = state.run(&request(1, SHOW, 3), &MoveAuthority(allowed));
        assert_eq!((result.status, result.detail), (expected.0, expected.1 as u32), "post-read case {failure}");
        assert_pending_return(&state, original, writes, destroyed);
    }
}

#[test]
fn positive_identity_or_geometry_conflicts_never_use_confirmation_grace() {
    for geometry in [false, true] {
        let (mut state, guard) = move_probe_fixture(false, MoveReadProbe {
            see_costs: RefCell::new(VecDeque::from([Duration::from_millis(80); 2])),
            fault_on_see: (!geometry).then_some((3, Why::Identity)),
            changed_frame_on_see: geometry.then_some(3),
            ..Default::default()
        });
        let window = state.sys.windows[&1].0;
        let original = (state.owned[&window].lease, state.owned[&window].witness);
        let writes = state.sys.moved.len();
        let destroyed = state.sys.destroyed.len();
        let result = state.run(&request(1, SHOW, 3), &guard);
        assert_eq!((result.status, result.detail), (UNKNOWN, Why::Identity as u32));
        assert_eq!(state.sys.move_read_probe.as_ref().unwrap().see_calls.get(), if geometry { 4 } else { 3 });
        assert_pending_return(&state, original, writes, destroyed);
    }
}

#[test]
fn transient_full_view_errors_cannot_borrow_the_positive_confirmation_budget() {
    for fault in [Why::Membership, Why::Readback, Why::AXCannotComplete] {
        for scenario in 0..3 {
            let (costs, fault_at, reads, elapsed_ms) = match scenario {
                0 => (vec![0, 60, 60], 1, 3, 124),
                1 => (vec![80, 80], 3, 3, 164),
                _ => (vec![116], 1, 1, 120),
            };
            let (mut state, guard) = move_probe_fixture(false, MoveReadProbe {
                see_costs: RefCell::new(costs.into_iter().map(Duration::from_millis).collect()),
                fault_on_see: Some((fault_at, fault)),
                ..Default::default()
            });
            let window = state.sys.windows[&1].0;
            let original = (state.owned[&window].lease, state.owned[&window].witness);
            let writes = state.sys.moved.len();
            let destroyed = state.sys.destroyed.len();
            let result = state.run(&request(1, SHOW, 3), &guard);
            let probe = state.sys.move_read_probe.as_ref().unwrap();
            assert_eq!((result.status, result.detail), (TIMEOUT, Why::Uncertain as u32));
            assert_eq!(probe.see_calls.get(), reads, "no new read follows an expired transient-error deadline, even after the poll wait");
            assert_eq!(state.sys.now() - probe.began.get().unwrap(), Duration::from_millis(elapsed_ms));
            assert_pending_return(&state, original, writes, destroyed);
        }
    }
}

#[test]
fn recovered_full_view_must_return_before_the_original_retry_deadline() {
    let (mut state, guard) = move_probe_fixture(false, MoveReadProbe {
        see_costs: RefCell::new([0, 50, 50, 80, 80].into_iter().map(Duration::from_millis).collect()),
        fault_on_see: Some((1, Why::AXCannotComplete)),
        ..Default::default()
    });
    let writes = state.sys.moved.len();
    assert_eq!(state.run(&request(1, SHOW, 3), &guard).status, PASS);
    let probe = state.sys.move_read_probe.as_ref().unwrap();
    assert_eq!(probe.see_calls.get(), 5, "the recovered view and its consecutive successor are both complete");
    assert_eq!(state.sys.now() - probe.began.get().unwrap(), Duration::from_millis(268));
    assert_eq!(state.sys.moved.len(), writes + 1);
    assert!(state.owned.is_empty() && state.slots.is_empty() && !state.failed);
}

#[test]
fn acknowledgement_misses_keep_the_original_late_health_strike() {
    let (mut state, guard) = move_probe_fixture(false, MoveReadProbe {
        missing_forward_for: Duration::from_millis(8),
        ..Default::default()
    });
    assert_eq!(state.run(&request(1, SHOW, 3), &guard).status, PASS);
    assert_eq!(state.strikes.len(), 1, "the miss at test GRACE still records the original health strike");
    assert_eq!(state.sys.move_read_probe.as_ref().unwrap().see_calls.get(), 4);
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
fn visible_readback_enrolls_the_never_hidden_current_window_without_claiming_ownership() {
    let (mut state, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    assert_eq!(state.run(&launch_request(LAUNCH), &guard).status, PASS);
    assert!(state.visible.is_empty());
    let writes = state.sys.moved.len();
    let registered = state.run(&request(1, READBACK, 2), &guard);
    assert_eq!((registered.status, registered.owned, registered.flags & OWNED), (PASS, 0, 0));
    assert_eq!(state.sys.moved.len(), writes);
    let window = state.sys.windows[&1].0;
    assert_eq!(state.visible[&window].witness, state.sys.windows[&1].2);
    state.sys.windows.get_mut(&1).unwrap().3 = true;
    let retired = state.run(&request(1, HIDE_MINIMIZED, 3), &guard);
    assert_eq!(retired.status, PASS);
    assert_eq!(state.sys.minimize_writes, vec![(1, retired.native_id, false)]);
    assert_eq!(state.run(&request(1, SHOW, 4), &guard).status, PASS);
    assert!(state.visible.contains_key(&window), "SHOW preserves the same original binding for a later native mini event");
    let before_release = state.sys.moved.len();
    let released = state.run(&launch_request(RELEASE_SPACES), &guard);
    assert_eq!((released.status, released.owned), (PASS, 0));
    assert!(state.visible.is_empty());
    assert_eq!(state.sys.moved.len(), before_release, "dropping read-only bindings never sends a window move");
}

#[test]
fn mini_adoption_requires_the_registered_original_lifetime_and_never_rebinds_a_replacement() {
    for change in 0..4 {
        let (mut state, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        assert_eq!(state.run(&launch_request(LAUNCH), &guard).status, PASS);
        if change != 0 { assert_eq!(state.run(&request(1, READBACK, 2), &guard).status, PASS); }
        state.sys.windows.get_mut(&1).unwrap().3 = true;
        let mut mini = request(1, HIDE_MINIMIZED, 3);
        match change {
            1 => mini.lifetime[0] += 1,
            2 => mini.generation[0] += 1,
            3 => state.sys.windows.get_mut(&1).unwrap().2 += 1,
            _ => (), // A pre-existing, never-registered Dock item.
        }
        let writes = state.sys.moved.len();
        let result = state.run(&mini, &guard);
        assert_ne!(result.status, PASS);
        assert_eq!(result.owned, 0);
        assert_eq!(state.sys.moved.len(), writes);
        assert!(state.sys.minimize_writes.is_empty());
    }
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
fn yellow_completion_waits_for_the_original_ax_animation_without_reissuing_writes() {
    for unavailable in [false, true] {
        let (mut state, guard) = setup();
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        state.sys.windows.get_mut(&1).unwrap().3 = true;
        state.sys.unminimize_observation_delay = Duration::from_millis(220);
        state.sys.unminimize_observation_unavailable = unavailable;
        let writes = state.sys.moved.len();
        let result = state.run(&request(1, HIDE_MINIMIZED, 2), &guard);
        assert_eq!(result.status, PASS);
        assert_eq!(result.flags & HIDDEN, HIDDEN);
        assert_eq!(state.sys.moved.len(), writes + 1);
        assert_eq!(state.sys.minimize_writes, vec![(1, result.native_id, false)]);
        let elapsed = state.sys.now() - state.sys.unminimize_started.unwrap().1;
        assert!(elapsed > DEADLINE && elapsed < MINIMIZE_COMPLETION_BUDGET);
        assert_eq!(state.run(&request(1, SHOW, 3), &guard).status, PASS);
        assert_eq!(state.sys.windows[&1].1, 10);
        assert_eq!(state.sys.minimize_writes.len(), 1);
    }
}

#[test]
fn unreadable_yellow_completion_retains_ownership_and_stops_at_its_observation_budget() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    state.sys.windows.get_mut(&1).unwrap().3 = true;
    state.sys.unminimize_observation_delay = Duration::from_secs(1);
    state.sys.unminimize_observation_unavailable = true;
    let writes = state.sys.moved.len();
    let result = state.run(&request(1, HIDE_MINIMIZED, 2), &guard);
    assert_eq!((result.status, result.detail), (UNKNOWN, Why::AXCannotComplete as u32));
    assert!(state.failed && !state.owned.is_empty());
    assert_eq!(result.flags & HIDDEN, 0);
    assert_eq!(state.sys.moved.len(), writes + 1);
    assert_eq!(state.sys.minimize_writes.len(), 1);
    assert_eq!(state.sys.now() - state.sys.unminimize_started.unwrap().1, MINIMIZE_COMPLETION_BUDGET);
    state.sys.unminimize_started = None; // The same original object becomes readable again.
    let returned = state.run(&launch_request(RELEASE_SPACES), &guard);
    assert_eq!((returned.status, returned.owned), (PASS, 0));
    assert_eq!(state.sys.windows[&1].1, 10);
    assert_eq!(state.sys.minimize_writes.len(), 1);
}

#[test]
fn yellow_completion_observes_an_internal_extra_membership_but_never_accepts_a_managed_one() {
    for managed in [false, true] {
        let (mut state, guard) = setup();
        if managed {
            state.sys.managed_roster = vec![
                Desktop { display: [5; 16], uuid: [6; 16], id: 10, kind: 0, current: 1 },
                Desktop { display: [5; 16], uuid: [7; 16], id: 200, kind: 0, current: 0 },
            ];
        }
        assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
        state.sys.windows.get_mut(&1).unwrap().3 = true;
        state.sys.unminimize_extra_space = Some((200, Duration::from_millis(220)));
        let writes = state.sys.moved.len();
        let result = state.run(&request(1, HIDE_MINIMIZED, 2), &guard);
        let elapsed = state.sys.now() - state.sys.unminimize_started.unwrap().1;
        if managed {
            assert_eq!((result.status, result.detail), (UNKNOWN, Why::Membership as u32));
            assert_eq!(result.flags & HIDDEN, 0);
            assert!(elapsed < DEADLINE && state.failed && !state.owned.is_empty());
        } else {
            assert_eq!(result.status, PASS);
            assert_eq!(result.flags & HIDDEN, HIDDEN);
            assert!(elapsed >= Duration::from_millis(220) && elapsed < MINIMIZE_COMPLETION_BUDGET);
            assert_eq!(state.sys.spaces(1, 1).unwrap(), Rows::from([result.native_id]));
        }
        assert_eq!(state.sys.moved.len(), writes + 1);
        assert_eq!(state.sys.minimize_writes.len(), 1);
        state.sys.unminimize_extra_space = None;
        let released = state.run(&launch_request(RELEASE_SPACES), &guard);
        assert_eq!((released.status, released.owned), (PASS, 0));
        assert_eq!(state.sys.windows[&1].1, 10);
    }
}

#[test]
fn active_deminimize_includes_the_native_animation_and_two_complete_read_costs() {
    let (mut state, guard) = setup();
    assert_eq!(state.run(&request(1, TRIAL, 1), &guard).status, PASS);
    state.sys.windows.get_mut(&1).unwrap().3 = true;
    state.sys.unminimize_extra_space = Some((200, Duration::from_millis(600)));
    state.sys.unminimize_observation_delay = Duration::from_millis(600);
    state.sys.unminimize_read_cost = Duration::from_millis(20);
    let moves = state.sys.moved.len();
    let result = state.run(&request(1, HIDE_MINIMIZED, 2), &guard);
    let elapsed = state.sys.now() - state.sys.unminimize_started.unwrap().1;
    assert_eq!(result.status, PASS);
    assert_eq!(result.flags & HIDDEN, HIDDEN);
    assert!(state.sys.unminimize_animated_reads.get() > 0);
    assert!(elapsed > AX_OBSERVATION_BUDGET && elapsed < MINIMIZE_COMPLETION_BUDGET);
    assert_eq!(state.sys.spaces(1, 1).unwrap(), Rows::from([result.native_id]));
    let original = &state.owned[&state.sys.windows[&1].0];
    let settled = state.sys.see(original.lease.window, &original.witness).unwrap();
    assert!(!settled.visible && settled.rect == original.original);
    assert_eq!(state.sys.moved.len(), moves + 1);
    assert_eq!(state.sys.minimize_writes.len(), 1);
    let released = state.run(&launch_request(RELEASE_SPACES), &guard);
    assert_eq!((released.status, released.owned), (PASS, 0));
}

#[test]
fn macos_pulling_an_unminimized_window_home_is_never_reported_as_hidden() {
    let (mut s, a) = setup();
    assert_eq!(s.run(&request(1, TRIAL, 1), &a).status, PASS);
    s.sys.windows.get_mut(&1).unwrap().3 = true;
    s.sys.unminimize_returns_to_desktop = true;
    let writes = s.sys.moved.len();
    let hidden = s.run(&request(1, HIDE_MINIMIZED, 2), &a);
    assert_eq!((hidden.status, hidden.detail), (UNKNOWN, Why::Membership as u32));
    assert_eq!(hidden.flags & HIDDEN, 0);
    assert!(s.failed && !s.owned.is_empty());
    assert_eq!(s.sys.moved.len(), writes + 1);
    assert_eq!(s.sys.minimize_writes.len(), 1);
    assert!(s.sys.now() - s.sys.unminimize_started.unwrap().1 < MINIMIZE_COMPLETION_BUDGET);
    let released = s.run(&launch_request(RELEASE_SPACES), &a);
    assert_eq!((released.status, released.owned), (PASS, 0));
    assert!(s.slots.is_empty());
    assert_eq!(s.sys.windows[&1].1, 10);
}

#[test]
fn initial_home_observations_have_a_budget_separate_from_space_move_acknowledgement() {
    for (cost, empty, should_move) in [(200, 0, true), (200, 1, true), (300, 1, false)] {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        s.sys.initial_empty_memberships.set(empty);
        // Charge the actual synchronous observation cost, including a first
        // empty registration where present. No write is repeated.
        s.sys.probe_read_costs = vec![Duration::from_millis(cost); empty as usize + 2].into();
        let began = s.sys.now();
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert!(s.sys.now() - began > DEADLINE);
        assert_eq!(s.sys.probe_closes, 1);
        assert_eq!(result.owned, 0);
        if should_move {
            assert_eq!(result.status, PASS);
            assert_eq!(s.sys.moved, vec![(Route::Bridge, 77, 101, 7), (Route::Bridge, 77, 10, 15)]);
            assert_eq!(s.sys.destroyed, vec![101]);
            assert_eq!(s.route, Some(Route::Bridge));
        } else {
            // Even two positive final reads cannot qualify when their total
            // observation exceeds the dedicated initial-discovery deadline.
            assert_eq!((result.status, result.detail), (UNKNOWN, Why::Membership as u32));
            assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
            assert_eq!(s.sys.next, 100);
        }
        assert_eq!(s.sys.spaces, Rows::from([10]));
    }
}

#[test]
fn a_missing_retained_desktop_role_requires_two_new_complete_home_reads() {
    for route in [Route::Classic, Route::Bridge] {
        for complete_before_gap in [false, true] {
            let (mut s, mut guard) = setup();
            guard.approved = Some(route);
            let originals = s.sys.windows.clone();
            if complete_before_gap { s.sys.probe_read_focus.push_back((1, 0)); }
            s.sys.probe_read_focus.extend([(0, -25204), (1, 0), (1, 0)]);
            let result = s.run(&launch_request(LAUNCH), &guard);
            assert_eq!((result.status, result.owned, result.native_id), (PASS, 0, 10));
            // A complete sample from before the transport gap cannot combine
            // with its first recovered sample to authorize the initial move.
            assert_eq!(s.sys.probe_reads_before_first_move, Some(if complete_before_gap { 4 } else { 3 }));
            assert_eq!(s.sys.moved, vec![(route, 77, 101, 7), (route, 77, 10, 15)]);
            assert_eq!(s.sys.destroyed, vec![101]);
            for op in [launch::PanelOp::Prepare, launch::PanelOp::Open, launch::PanelOp::Close] {
                assert_eq!(s.sys.probe_operations.iter().filter(|seen| **seen == op).count(), 1);
            }
            assert!(originals.iter().all(|(number, state)| s.sys.windows.get(number) == Some(state)));
            assert!(!s.sys.windows.contains_key(&77));
            assert_eq!(s.route, Some(route));
        }
    }
}

#[test]
fn missing_desktop_role_does_not_mask_changed_or_unknown_focus() {
    // (0, 0) represents a positive original-focus mismatch or an unclassified
    // failure. A default receipt, another AX error, and contradictory flags must
    // never be treated as the narrowly classified missing-role observation.
    for refused in [(0, 0), (0, -25202), (1, -25204), (2, 0)] {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        s.sys.probe_read_focus.extend([(0, -25204), refused, (1, 0), (1, 0)]);
        let began = s.sys.now();
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!((result.status, result.detail), (UNKNOWN, Why::ProbeFocus as u32));
        assert!(s.sys.now() - began < Duration::from_millis(100));
        assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
        assert_eq!(s.sys.probe_closes, 1);
        assert_eq!(s.sys.next, 100);
    }
}

#[test]
fn missing_desktop_role_cannot_hide_changed_canary_identity_or_ambiguous_membership() {
    for conflict in 0..4 {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        s.sys.probe_read_focus.push_back((0, -25204));
        let original = Window { number: 77, pid: std::process::id() as i32, birth: 123 };
        s.sys.probe_read_window = match conflict {
            0 => Some(Window { number: 78, ..original }),
            1 => Some(Window { birth: 124, ..original }),
            2 => Some(Window { pid: original.pid + 1, ..original }),
            _ => None,
        };
        s.sys.ambiguous_panel_membership = conflict == 3;
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!(result.status, UNKNOWN);
        let expected = if conflict == 3 { Why::Membership } else { Why::ProbeFocus };
        assert_eq!(result.detail, expected as u32);
        assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
        assert_eq!(s.sys.probe_operations.iter().filter(|op| **op == launch::PanelOp::Open).count(), 1);
        assert_eq!(s.sys.next, 100);
    }
}

#[test]
fn a_role_gap_cannot_erase_a_positive_home_change_between_current_displays() {
    for samples in [
        vec![(10, 1, 0), (11, 0, -25204), (11, 1, 0), (11, 1, 0)],
        vec![(10, 0, -25204), (11, 1, 0), (11, 1, 0)],
        vec![(10, 1, 0), (10, 0, -25204), (11, 1, 0), (11, 1, 0)],
        vec![(10, 0, -25204), (11, 0, -25204), (11, 1, 0), (11, 1, 0)],
    ] {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        let home = s.sys.desktops(1).unwrap()[0];
        s.sys.managed_roster = vec![home, Desktop { display: [7; 16], uuid: [8; 16], id: 11, ..home }];
        s.sys.spaces.insert(11);
        // Both homes belong to the baseline. A positive move between them is a
        // conflict even when the first or both role observations were missing.
        // Reset only the complete-proof streak, never the observed home identity.
        s.sys.probe_read_homes.extend(samples.iter().map(|sample| sample.0));
        s.sys.probe_read_focus.extend(samples.iter().map(|sample| (sample.1, sample.2)));
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!((result.status, result.detail, result.owned), (UNKNOWN, Why::Scope as u32, 0));
        assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
        assert_eq!(s.sys.probe_closes, 1);
        assert_eq!(s.sys.probe_operations.iter().filter(|op| **op == launch::PanelOp::Open).count(), 1);
        assert_eq!(s.sys.spaces, Rows::from([10, 11]));
        assert_eq!(s.sys.next, 100);
    }
}

#[test]
fn persistent_missing_desktop_role_exhausts_only_the_original_home_budget() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.probe_read_focus = vec![(0, -25204); 1000].into();
    let began = s.sys.now();
    let result = s.run(&launch_request(LAUNCH), &guard);
    assert_eq!((result.status, result.detail), (UNKNOWN, Why::Membership as u32));
    assert!(s.sys.now() - began >= Duration::from_millis(650));
    assert!(s.sys.now() - began < Duration::from_millis(656));
    assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
    assert!(s.launch.as_ref().is_some_and(|run| !run.cleaned));
    assert_eq!(s.sys.probe_closes, 0);
    // An unreadable focus is not permission to close. A later explicit cleanup
    // must establish the original focus before closing this same owned panel.
    s.sys.probe_read_focus.clear();
    let cleaned = s.run(&launch_request(CLEAN_LAUNCH), &guard);
    assert_eq!((cleaned.status, cleaned.owned), (PASS, 0));
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.probe_operations.iter().filter(|op| **op == launch::PanelOp::Open).count(), 1);
    assert!(s.sys.moved.is_empty() && s.route.is_none());
}

#[test]
fn one_over_budget_panel_read_never_gets_a_new_home_discovery_deadline() {
    for focus in [(1, 0), (0, -25204)] {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        s.sys.probe_read_focus.push_back(focus);
        s.sys.probe_read_costs.push_back(Duration::from_millis(651));
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!((result.status, result.detail, result.owned), (UNKNOWN, Why::Membership as u32, 0));
        assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
        // Exactly one discovery read, then the existing cleanup's four reads;
        // the expired observation cannot start another discovery attempt.
        assert_eq!(s.sys.probe_operations.iter().filter(|op| **op == launch::PanelOp::Read).count(), 5);
        assert_eq!(s.sys.probe_closes, 1);
        assert_eq!(s.sys.probe_operations.iter().filter(|op| **op == launch::PanelOp::Open).count(), 1);
        assert_eq!(s.sys.next, 100);
    }
}

#[test]
fn unknown_or_ambiguous_initial_home_never_creates_a_space() {
    for (empty, ambiguous) in [(u32::MAX, false), (0, true)] {
        let (mut s, mut guard) = setup();
        guard.approved = Some(Route::Bridge);
        s.sys.initial_empty_memberships.set(empty);
        s.sys.ambiguous_panel_membership = ambiguous;
        let result = s.run(&launch_request(LAUNCH), &guard);
        assert_eq!((result.status, result.detail, result.owned), (UNKNOWN, Why::Membership as u32, 0));
        assert!(s.sys.moved.is_empty() && s.sys.destroyed.is_empty() && s.route.is_none());
        assert_eq!(s.sys.next, 100);
        assert_eq!(s.sys.probe_closes, 1);
        assert_eq!(s.sys.spaces, Rows::from([10]));
    }
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
fn canary_close_observes_unsettled_cg_then_two_complete_absence_reads() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.probe_absence_failures.set(2);
    let result = s.run(&launch_request(LAUNCH), &guard);
    assert_eq!((result.status, result.owned), (PASS, 0));
    assert_eq!(s.sys.probe_absence_reads.get(), 4);
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.moved, vec![(Route::Bridge, 77, 101, 7), (Route::Bridge, 77, 10, 15)]);
    assert_eq!(s.sys.destroyed, vec![101]);
    assert_eq!(s.route, Some(Route::Bridge));
}
#[test]
fn canary_close_unknown_reaches_original_deadline_and_retains_space_for_cleanup() {
    let (mut s, mut guard) = setup();
    guard.approved = Some(Route::Bridge);
    s.sys.probe_absence_failures.set(u32::MAX);
    let began = s.sys.now();
    let result = s.run(&launch_request(LAUNCH), &guard);
    assert_eq!((result.status, result.detail), (UNKNOWN, Why::Readback as u32));
    assert!(s.sys.now() - began >= DEADLINE);
    assert!(s.sys.now() - began < DEADLINE * 2);
    assert!(result.owned > 0 && s.route.is_none());
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.moved.len(), 2);
    assert!(s.sys.destroyed.is_empty() && s.sys.spaces.contains(&101));
    s.sys.probe_absence_failures.set(0);
    let reads = s.sys.probe_absence_reads.get();
    let clean = s.run(&launch_request(CLEAN_LAUNCH), &guard);
    assert_eq!((clean.status, clean.owned), (PASS, 0));
    assert_eq!(s.sys.probe_absence_reads.get() - reads, 2);
    assert_eq!(s.sys.probe_closes, 1);
    assert_eq!(s.sys.moved.len(), 2);
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
