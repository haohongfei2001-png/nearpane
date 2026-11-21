// Synthetic system implementing the same single-window reverse and forward membership reads as Darwin.
use super::*;
use std::cell::Cell;

struct Guard {
    ok: Cell<bool>,
}
impl Authority for Guard {
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
    windows: BTreeMap<u32, (Window, u64, u64, bool)>,
    spaces: Rows,
    moved: Vec<(Route, u32, u64, u32)>,
    destroyed: Vec<u64>,
    next: u64,
    connection: i32,
    no_effect: bool,
    switch_topology: bool,
    bystander: bool,
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
        Ok(vec![Desktop {
            display: [5; 16],
            uuid: [6; 16],
            id: 10,
            kind: if self.switch_topology { 4 } else { 0 },
            current: 1,
        }])
    }
    fn all(&self, _: i32) -> Check<Rows> {
        Ok(self.spaces.clone())
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
    fn see(&self, w: Window, lease: &u64) -> Check<Seen> {
        let t = self.windows[&w.number];
        if t.0 == w && t.2 == *lease && !t.3 {
            Ok(Seen {
                visible: t.1 == 10,
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
        self.destroyed.push(s);
        self.spaces.remove(&s);
        Delivery::Accepted
    }
    fn move_window(&mut self, _: i32, route: Route, w: Window, s: u64, mask: u32) -> Delivery {
        self.moved.push((route, w.number, s, mask));
        if !self.no_effect {
            self.windows.get_mut(&w.number).unwrap().1 = s;
        }
        Delivery::Accepted
    }
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
        assert_eq!(s.owned.len(), 1);
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
