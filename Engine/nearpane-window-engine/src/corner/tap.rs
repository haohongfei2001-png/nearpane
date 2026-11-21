//! A head-inserted session filter. The callback sees immutable numeric geometry; the WM
//! worker owns all AX/WindowServer queries. A lost observation revokes this tap generation.
use super::geometry::Point;
use super::sliver::{Button, Press, PressGate, Seen, Shield};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub(super) const UNAVAILABLE: u32 = 30;
pub(super) const TIMED_OUT: u32 = 31;
pub(super) const SECURE_INPUT: u32 = 32;
pub(super) const STALE: u32 = 33;
pub(super) const CHANGING: u32 = 34;
pub(super) const RECEIVER_DISAGREES: u32 = 35;

pub(super) struct Publication {
    pub shield: Shield,
    pub seen: Seen,
    pub changing: bool,
}

/// Only a complete CG observation is actionable. Any press in the dynamically changing park zone
/// revokes qualification if its recipient cannot yet be identified; it is never guessed.
fn hit(p: &Publication, at: Point, now: Instant, pid: i32) -> Result<bool, u32> {
    if !p.shield.may_hit(at) {
        return Ok(false);
    }
    if p.changing {
        return Err(CHANGING);
    }
    let rows = p.seen.fresh(now).ok_or(STALE)?;
    Ok(p.shield.hits(rows, at, pid).is_some())
}

fn observed_recipient(p: &Publication, now: Instant, window: u32, pid: i32) -> Option<bool> {
    p.seen
        .fresh(now)?
        .iter()
        .find(|r| r.id == window && r.pid == pid && r.alpha > 0.)
        .map(|r| p.shield.parked.contains(&r.id))
}

fn can_protect_existing(reason: u32) -> bool {
    matches!(reason, STALE | CHANGING | RECEIVER_DISAGREES)
}

// A head tap can lack a resolved recipient. When Quartz supplies both fields,
// corroborate them against the recent front-to-back observation. Only a down
// selects a receiver; a drag outside the corner must follow its original down.
fn press_decision(
    p: &Publication,
    at: Point,
    now: Instant,
    window: i64,
    owner: i64,
) -> (bool, Option<u32>) {
    if !p.shield.may_hit(at) {
        return (false, None);
    }
    let predicted = hit(p, at, now, -1);
    let (Ok(id), Ok(pid)) = (u32::try_from(window), i32::try_from(owner)) else {
        return (predicted.unwrap_or(false), Some(RECEIVER_DISAGREES));
    };
    if id == 0 || pid == 0 {
        return (predicted.unwrap_or(false), predicted.err());
    }
    let actual = observed_recipient(p, now, id, pid);
    match (predicted, actual) {
        (Ok(expected), Some(receiver)) if expected == receiver => (receiver, None),
        (Ok(expected), receiver) => (receiver.unwrap_or(expected), Some(RECEIVER_DISAGREES)),
        (Err(reason), receiver) => (receiver.unwrap_or(false), Some(reason)),
    }
}

struct Shared {
    current: Mutex<Option<Publication>>,
    on: AtomicBool,
    stop: AtomicBool,
    busy: AtomicBool,
    ready: AtomicBool,
    lost: AtomicU32,
}
impl Shared {
    fn revoke(&self, reason: u32) {
        let _ = self
            .lost
            .fetch_update(Ordering::SeqCst, Ordering::Relaxed, |old| {
                (old == 0 || (can_protect_existing(old) && !can_protect_existing(reason)))
                    .then_some(reason)
            });
    }
}
struct TapThread {
    shared: Arc<Shared>,
    gates: [PressGate; 32],
}
pub(super) struct Tap {
    shared: Arc<Shared>,
}
type Decide = extern "C" fn(*mut c_void, u32, f64, f64, i64, i64, i64) -> i32;
type State = extern "C" fn(*mut c_void) -> u32;
type Status = extern "C" fn(*mut c_void, u32);
unsafe extern "C" {
    fn np_corner_tap_run(ctx: *mut c_void, decide: Decide, state: State, status: Status);
}

fn event(kind: u32, number: i64) -> Option<(usize, Press)> {
    let button = match kind {
        1 | 2 | 6 => Button::Left,
        3 | 4 | 7 => Button::Right,
        25..=27 => Button::Other,
        _ => return None,
    };
    let slot = match button {
        Button::Left => 0,
        Button::Right => 1,
        Button::Other if (2..32).contains(&number) => number as usize,
        _ => return None,
    };
    let e = match kind {
        1 | 3 | 25 => Press::Down(button),
        6 | 7 | 27 => Press::Dragged(button),
        _ => Press::Up(button),
    };
    Some((slot, e))
}

extern "C" fn decide(
    raw: *mut c_void,
    kind: u32,
    x: f64,
    y: f64,
    number: i64,
    window: i64,
    owner: i64,
) -> i32 {
    // The callback, controls and health notifications all run on this port's single CFRunLoop.
    let t = unsafe { &mut *raw.cast::<TapThread>() };
    let Some((slot, e)) = event(kind, number) else {
        t.shared.revoke(UNAVAILABLE);
        return 0;
    };
    let s = &*t.shared;
    let swallow = t.gates[slot].swallow(e, || {
        let lost = s.lost.load(Ordering::Acquire);
        if !s.on.load(Ordering::Acquire) || (lost != 0 && !can_protect_existing(lost)) {
            return false;
        }
        let Ok(p) = s.current.try_lock() else {
            s.revoke(CHANGING);
            return false;
        };
        let Some(p) = p.as_ref() else { return false };
        let at = Point::new(x, y);
        let now = Instant::now();
        if lost != 0 {
            // Writes stay revoked. During recovery protect only a positive event recipient
            // corroborated by a still-current observation of an already owned window.
            let (Ok(id), Ok(pid)) = (u32::try_from(window), i32::try_from(owner)) else {
                return false;
            };
            return id > 0
                && pid > 0
                && p.shield.may_hit(at)
                && observed_recipient(p, now, id, pid) == Some(true);
        }
        let (swallow, reason) = press_decision(p, at, now, window, owner);
        if let Some(reason) = reason {
            s.revoke(reason);
        }
        swallow
    });
    s.busy
        .store(t.gates.iter().any(PressGate::busy), Ordering::Release);
    swallow as i32
}
extern "C" fn state(raw: *mut c_void) -> u32 {
    let s = unsafe { &(*raw.cast::<TapThread>()).shared };
    let reason = s.lost.load(Ordering::Acquire);
    let wanted = s.on.load(Ordering::Acquire) && (reason == 0 || can_protect_existing(reason));
    wanted as u32
        | ((s.busy.load(Ordering::Acquire) as u32) << 1)
        | ((s.stop.load(Ordering::Acquire) as u32) << 2)
}
extern "C" fn status(raw: *mut c_void, code: u32) {
    let t = unsafe { &mut *raw.cast::<TapThread>() };
    let s = &t.shared;
    if matches!(code, 2..=4) {
        // A forcibly removed port may never see the balancing release. Never inherit its
        // button latch or suppress an unrelated drag after macOS has disabled this generation.
        t.gates.fill(PressGate::new());
        s.busy.store(false, Ordering::Release);
    }
    s.ready.store(code == 1, Ordering::Release);
    match code {
        2 => s.revoke(UNAVAILABLE),
        3 => s.revoke(TIMED_OUT),
        4 => s.revoke(SECURE_INPUT),
        _ => {}
    }
}
impl Tap {
    pub fn start(initial: Publication) -> Result<Self, u32> {
        let shared = Arc::new(Shared {
            current: Mutex::new(Some(initial)),
            on: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            busy: AtomicBool::new(false),
            ready: AtomicBool::new(false),
            lost: AtomicU32::new(0),
        });
        let worker = Arc::clone(&shared);
        thread::Builder::new()
            .name("nearpane.corner-input".into())
            .spawn(move || {
                let mut local = TapThread {
                    shared: worker,
                    gates: [PressGate::new(); 32],
                };
                unsafe {
                    np_corner_tap_run((&mut local as *mut TapThread).cast(), decide, state, status)
                };
                local.shared.ready.store(false, Ordering::Release);
            })
            .map_err(|_| UNAVAILABLE)?;
        let tap = Self { shared };
        let end = Instant::now() + Duration::from_millis(600);
        while !tap.shared.ready.load(Ordering::Acquire)
            && tap.shared.lost.load(Ordering::Acquire) == 0
            && Instant::now() < end
        {
            thread::sleep(Duration::from_millis(3));
        }
        tap.health()?;
        Ok(tap)
    }
    pub fn publish(&self, new: Publication) -> Result<(), u32> {
        // A replacement cannot retroactively cover a gap in native Z-order observations.
        if let Err(reason) = self.health() {
            if can_protect_existing(reason)
                && !new.changing
                && new.seen.fresh(Instant::now()).is_some()
            {
                let mut current = self.shared.current.lock().map_err(|_| UNAVAILABLE)?;
                if current
                    .as_ref()
                    .is_some_and(|old| new.shield.parked.is_subset(&old.shield.parked))
                {
                    *current = Some(new);
                }
            }
            return Err(reason);
        }
        *self.shared.current.lock().map_err(|_| UNAVAILABLE)? = Some(new);
        self.health()
    }
    pub fn revoke(&self, why: u32) {
        self.shared.revoke(why);
    }
    pub fn health(&self) -> Result<(), u32> {
        let error = self.shared.lost.load(Ordering::Acquire);
        if error != 0 {
            return Err(error);
        }
        if !self.shared.ready.load(Ordering::Acquire) {
            return Err(UNAVAILABLE);
        }
        let p = self.shared.current.lock().map_err(|_| UNAVAILABLE)?;
        if p.as_ref()
            .and_then(|p| p.seen.fresh(Instant::now()))
            .is_none()
        {
            self.shared.revoke(STALE);
            return Err(STALE);
        }
        Ok(())
    }
}
impl Drop for Tap {
    fn drop(&mut self) {
        self.shared.on.store(false, Ordering::Release);
        self.shared.stop.store(true, Ordering::Release);
        // Already-swallowed releases drain on the same tap thread. Its Arc and callback
        // memory live until the CF source and port have been removed there.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::corner::geometry::Rect;
    use crate::corner::sliver::{DockBar, Listed, SEEN_FRESH};
    fn publication(at: Instant, changing: bool) -> Publication {
        let frame = Rect::new(90., 95., 100., 80.);
        Publication {
            shield: Shield {
                on: true,
                zones: vec![Rect::new(70., 60., 30., 40.)],
                parked: [9].into_iter().collect(),
                dock: DockBar::default(),
            },
            seen: Seen {
                at,
                windows: vec![Listed {
                    id: 9,
                    pid: 44,
                    bounds: frame,
                    layer: 0,
                    alpha: 1.,
                }],
            },
            changing,
        }
    }
    #[test]
    fn uncertain_recipient_revokes_only_an_at_risk_down() {
        let now = Instant::now();
        let at = Point::new(95., 97.);
        assert_eq!(hit(&publication(now, true), at, now, 123), Err(CHANGING));
        assert_eq!(
            hit(
                &publication(now, false),
                at,
                now + SEEN_FRESH + Duration::from_millis(1),
                123
            ),
            Err(STALE)
        );
        assert_eq!(hit(&publication(now, false), at, now, 123), Ok(true));
        assert_eq!(
            hit(&publication(now, true), Point::new(5., 5.), now, 123),
            Ok(false)
        );
    }
    #[test]
    #[cfg(feature = "isolated-fixtures")]
    fn unposted_quartz_mouse_metadata_crosses_the_actual_callback_for_down_drag_and_up() {
        unsafe extern "C" {
            fn np_fixture_corner_unposted_mouse(
                ctx: *mut c_void,
                f: Decide,
                kind: u32,
                x: f64,
                y: f64,
                win: i64,
                pid: i64,
            ) -> i32;
        }
        extern "C" fn observe(
            raw: *mut c_void,
            kind: u32,
            x: f64,
            y: f64,
            button: i64,
            win: i64,
            pid: i64,
        ) -> i32 {
            let sample = unsafe { &mut *raw.cast::<[i64; 6]>() };
            *sample = [kind as i64, x as i64, y as i64, button, win, pid];
            i32::from(win == 91)
        }
        for kind in [1, 6, 2] {
            let mut fields = [0_i64; 6];
            let result = unsafe {
                np_fixture_corner_unposted_mouse(
                    fields.as_mut_ptr().cast(),
                    observe,
                    kind,
                    11.,
                    13.,
                    91,
                    44,
                )
            };
            assert_eq!(result, 1);
            assert_eq!(fields, [kind as i64, 11, 13, 0, 91, 44]);
        }
    }
    #[test]
    fn confirmed_receiver_disagreement_latches_the_whole_gesture_and_revokes_health() {
        for (actual_id, actual_pid, peer_in_front, expected) in
            [(9, 44, true, 1), (10, 45, false, 0)]
        {
            let mut p = publication(Instant::now(), false);
            let peer = Listed {
                id: 10,
                pid: 45,
                ..p.seen.windows[0]
            };
            p.seen
                .windows
                .insert(if peer_in_front { 0 } else { 1 }, peer);
            let shared = Arc::new(Shared {
                current: Mutex::new(Some(p)),
                on: AtomicBool::new(true),
                stop: AtomicBool::new(false),
                busy: AtomicBool::new(false),
                ready: AtomicBool::new(true),
                lost: AtomicU32::new(0),
            });
            let mut handler = TapThread {
                shared: shared.clone(),
                gates: [PressGate::new(); 32],
            };
            let raw = (&mut handler as *mut TapThread).cast();
            assert_eq!(decide(raw, 1, 95., 97., 0, actual_id, actual_pid), expected);
            assert_eq!(shared.lost.load(Ordering::Acquire), RECEIVER_DISAGREES);
            assert_eq!(decide(raw, 3, 5., 5., 1, 10, 45), 0);
            assert_eq!(decide(raw, 6, 5., 5., 0, 10, 45), expected);
            assert_eq!(decide(raw, 4, 5., 5., 1, 10, 45), 0);
            assert_eq!(decide(raw, 2, 5., 5., 0, 10, 45), expected);
            assert!(!shared.busy.load(Ordering::Acquire));
            assert_eq!(state(raw) & 1, 1);
            assert_eq!(decide(raw, 1, 95., 97., 0, 9, 44), 1);
            assert_eq!(decide(raw, 6, 1., 1., 0, 0, 0), 1);
            assert_eq!(decide(raw, 2, 1., 1., 0, 0, 0), 1);
            assert_eq!(decide(raw, 1, 95., 97., 0, 10, 45), 0);
            assert_eq!(decide(raw, 2, 95., 97., 0, 10, 45), 0);
            let port = Tap {
                shared: shared.clone(),
            };
            assert_eq!(
                port.publish(publication(Instant::now(), false)),
                Err(RECEIVER_DISAGREES)
            );
            let mut outsider = publication(Instant::now(), false);
            outsider.shield.parked.insert(11);
            assert_eq!(port.publish(outsider), Err(RECEIVER_DISAGREES));
            assert!(
                !shared
                    .current
                    .lock()
                    .unwrap()
                    .as_ref()
                    .unwrap()
                    .shield
                    .parked
                    .contains(&11)
            );
            status(raw, 4);
            assert_eq!(state(raw) & 1, 0);
            assert_eq!(port.health(), Err(SECURE_INPUT));
        }
    }
    #[test]
    fn missing_recipient_uses_geometry_but_a_wrong_owner_or_changing_zone_cannot_attest_input_safety()
     {
        let now = Instant::now();
        let at = Point::new(95., 97.);
        let p = publication(now, false);
        assert_eq!(press_decision(&p, at, now, 0, 0), (true, None));
        assert_eq!(press_decision(&p, at, now, 9, 44), (true, None));
        assert_eq!(
            press_decision(&p, at, now, 9, 45),
            (true, Some(RECEIVER_DISAGREES))
        );
        assert_eq!(
            press_decision(&p, Point::new(4., 4.), now, 9, 45),
            (false, None)
        );
        assert_eq!(
            press_decision(&publication(now, true), at, now, 9, 44),
            (true, Some(CHANGING))
        );
        assert_eq!(
            press_decision(&p, at, now + SEEN_FRESH + Duration::from_millis(1), 9, 44),
            (false, Some(STALE))
        );
    }
    #[test]
    fn forced_port_disable_discards_the_button_latch_and_cannot_be_healed_by_republication() {
        for (code, reason) in [(2, UNAVAILABLE), (3, TIMED_OUT), (4, SECURE_INPUT)] {
            let shared = Arc::new(Shared {
                current: Mutex::new(Some(publication(Instant::now(), false))),
                on: AtomicBool::new(true),
                stop: AtomicBool::new(false),
                busy: AtomicBool::new(false),
                ready: AtomicBool::new(true),
                lost: AtomicU32::new(0),
            });
            let mut handler = TapThread {
                shared: shared.clone(),
                gates: [PressGate::new(); 32],
            };
            let raw = (&mut handler as *mut TapThread).cast();
            assert_eq!(decide(raw, 1, 95., 97., 0, 0, 0), 1);
            assert!(shared.busy.load(Ordering::Acquire));
            status(raw, code);
            assert!(!shared.busy.load(Ordering::Acquire));
            assert_eq!(decide(raw, 6, 95., 97., 0, 0, 0), 0);
            assert_eq!(
                Tap { shared }.publish(publication(Instant::now(), false)),
                Err(reason)
            );
        }
    }
    #[test]
    fn independent_additional_mouse_buttons_keep_their_own_drag_and_up() {
        let mut gates = [PressGate::new(); 32];
        for (kind, n, hit, want) in [
            (25, 2, true, true),
            (25, 4, false, false),
            (27, 2, false, true),
            (27, 4, false, false),
            (26, 4, false, false),
            (26, 2, false, true),
            (27, 2, false, false),
        ] {
            let (i, e) = event(kind, n).unwrap();
            assert_eq!(gates[i].swallow(e, || hit), want);
        }
    }
}
