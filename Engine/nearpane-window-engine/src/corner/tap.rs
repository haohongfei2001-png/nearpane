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
            .compare_exchange(0, reason, Ordering::SeqCst, Ordering::Relaxed);
    }
}
struct TapThread {
    shared: Arc<Shared>,
    gates: [PressGate; 32],
}
pub(super) struct Tap {
    shared: Arc<Shared>,
}
type Decide = extern "C" fn(*mut c_void, u32, f64, f64, i64) -> i32;
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

extern "C" fn decide(raw: *mut c_void, kind: u32, x: f64, y: f64, number: i64) -> i32 {
    // The callback, controls and health notifications all run on this port's single CFRunLoop.
    let t = unsafe { &mut *raw.cast::<TapThread>() };
    let Some((slot, e)) = event(kind, number) else {
        t.shared.revoke(UNAVAILABLE);
        return 0;
    };
    let s = &*t.shared;
    let swallow = t.gates[slot].swallow(e, || {
        if !s.on.load(Ordering::Acquire) || s.lost.load(Ordering::Acquire) != 0 {
            return false;
        }
        let Ok(p) = s.current.try_lock() else {
            s.revoke(CHANGING);
            return false;
        };
        let Some(p) = p.as_ref() else { return false };
        match hit(p, Point::new(x, y), Instant::now(), -1) {
            Ok(answer) => answer,
            Err(reason) => {
                s.revoke(reason);
                false
            }
        }
    });
    s.busy
        .store(t.gates.iter().any(PressGate::busy), Ordering::Release);
    swallow as i32
}
extern "C" fn state(raw: *mut c_void) -> u32 {
    let s = unsafe { &(*raw.cast::<TapThread>()).shared };
    let wanted = s.on.load(Ordering::Acquire) && s.lost.load(Ordering::Acquire) == 0;
    wanted as u32
        | ((s.busy.load(Ordering::Acquire) as u32) << 1)
        | ((s.stop.load(Ordering::Acquire) as u32) << 2)
}
extern "C" fn status(raw: *mut c_void, code: u32) {
    let s = unsafe { &(*raw.cast::<TapThread>()).shared };
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
                unsafe { np_corner_tap_run((&mut local as *mut TapThread).cast(), decide, state, status) };
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
        self.health()?;
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
        if p.as_ref().and_then(|p| p.seen.fresh(Instant::now())).is_none() {
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
