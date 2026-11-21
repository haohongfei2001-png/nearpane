//! The durable intent belongs to the Host's journal. This worker retains only its live AX
//! objects and independently observed footprints. A restarted process cannot adopt an old ID.
use super::{
    geometry::Rect,
    native::{self, Display, Member, Reference, Sample},
    park, sliver,
    tap::{self, Publication, Tap},
};
use crate::contract::{self as c, Control, Outcome, Request, WindowEngine};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Key {
    member: [u8; 16],
    lifetime: [u8; 16],
    generation: [u8; 16],
    group: [u8; 16],
}
impl From<&Request> for Key {
    fn from(r: &Request) -> Self {
        Self {
            member: r.member,
            lifetime: r.lifetime,
            generation: r.generation,
            group: r.group,
        }
    }
}

const BAD_LAYOUT: u32 = 40;
const IDENTITY: u32 = 41;
const NO_TARGET: u32 = 42;
const USER_CHANGED: u32 = 43;
const POSTCONDITION: u32 = 44;
const OWNERSHIP_UNKNOWN: u32 = 45;
const NEED_INDEPENDENT_READ: u32 = 46;

struct Owned {
    key: Key,
    id: Member,
    reference: Reference,
    original: Rect,
    parked: Option<Rect>,
    displays: Vec<Display>,
    corner: park::Corner,
}

/// The default is idle. No tap, native operation, or screen read is started at construction.
#[derive(Default)]
pub struct Corner {
    owned: HashMap<u32, Owned>,
    tap: Option<Tap>,
    patch: Option<native::PatchSession>,
    last_refresh: Option<Instant>,
}
fn same(a: Rect, b: Rect) -> bool {
    [a.x - b.x, a.y - b.y, a.w - b.w, a.h - b.h]
        .into_iter()
        .all(|n| n.is_finite() && n.abs() <= 0.75)
}
fn abi(r: Rect) -> c::Rect {
    c::Rect {
        x: r.x,
        y: r.y,
        width: r.w,
        height: r.h,
    }
}
fn rect(r: c::Rect) -> Rect {
    Rect::new(r.x, r.y, r.width, r.height)
}
fn scoped(list: &[Display], id: [u8; 16]) -> Result<(&Display, park::Corner), u32> {
    let here = list.iter().find(|d| d.id == id).ok_or(BAD_LAYOUT)?;
    let other: Vec<_> = list.iter().filter(|d| d.id != id).map(|d| d.frame).collect();
    let choice = park::choose_corner(here.frame, here.visible, &other);
    // The least-bad corner can still expose another display. It never qualifies for a write.
    if choice.overlap != 0.0 {
        return Err(BAD_LAYOUT);
    }
    Ok((here, choice.corner))
}
fn hidden(frame: Rect, list: &[Display], id: [u8; 16], corner: park::Corner) -> bool {
    let Some(display) = list.iter().find(|d| d.id == id) else {
        return false;
    };
    if !park::is_parked_in_at(frame, display.frame, display.visible, corner)
        || list
            .iter()
            .any(|d| d.id != id && frame.intersect(&d.frame).is_some())
    {
        return false;
    }
    // A large clamped body or a sliver beyond the published input zone is a real failure.
    let Some(slit) = frame.intersect(&display.frame) else {
        return false;
    };
    slit.w <= park::PARK_SLIVER
        && sliver::corner_zone(display.frame, display.visible, corner).contains_rect(&slit)
}
fn origin_safe(old: Rect, displays: &[Display], id: [u8; 16], corner: park::Corner) -> bool {
    let Some(screen) = displays.iter().find(|d| d.id == id) else {
        return false;
    };
    !old.is_degenerate()
        && old.intersect(&screen.visible).is_some()
        && !park::is_parked_in_at(old, screen.frame, screen.visible, corner)
        && displays
            .iter()
            .filter(|d| d.id != id)
            .all(|d| old.intersect(&d.frame).is_none())
}

/// Startup/monitoring has no nominated member. A partially populated lease is never an idle check.
fn health_member(r: &Request) -> Result<Option<Member>, u32> {
    let identifiers = [
        r.group,
        r.display,
        r.native_space,
        r.member,
        r.lifetime,
        r.generation,
    ];
    if identifiers.iter().all(|id| *id == [0; 16])
        && r.pid == 0
        && r.birth == 0
        && r.window == 0
        && r.native_id == 0
        && r.frame == c::Rect::default()
        && r.target == c::Rect::default()
    {
        return Ok(None);
    }
    let bound = Request {
        operation: c::READBACK,
        ..*r
    };
    bound.valid().then(|| Some(Member::from(r))).ok_or(IDENTITY)
}

impl Corner {
    fn result(&self, status: u32, detail: u32, sample: Option<Sample>, owned: bool) -> Outcome {
        let mut v = Outcome::new(status);
        v.detail = detail;
        v.owned = self.owned.len() as u32;
        if let Some(s) = sample {
            v.flags = c::AX_VALID | c::CG_VALID | c::MEMBERSHIP_VALID;
            v.frame = abi(s.cg);
        }
        if owned {
            v.flags |= c::OWNED;
        }
        v
    }
    fn publication(&self, preparing: bool) -> Result<Publication, u32> {
        let started = Instant::now();
        let layout = native::displays()?;
        let (list, dock) = native::zorder()?;
        let mut ids = HashSet::new();
        let mut zones = Vec::new();
        for o in self.owned.values() {
            if layout != o.displays || !o.reference.matches(&o.id) {
                return Err(IDENTITY);
            }
            let q = native::sample(&o.id)?;
            let (display, corner) = scoped(&layout, o.id.display)?;
            let matches: Vec<_> = list.iter().filter(|w| w.id == o.id.window).collect();
            if matches.len() != 1
                || matches[0].pid != o.id.pid
                || matches[0].layer != 0
                || !same(matches[0].bounds, q.cg)
            {
                return Err(IDENTITY);
            }
            if let Some(parked) = o.parked {
                if !same(parked, q.cg) || !hidden(q.cg, &layout, o.id.display, corner) {
                    return Err(USER_CHANGED);
                }
            } else if !preparing || !same(q.cg, o.original) {
                return Err(OWNERSHIP_UNKNOWN);
            }
            ids.insert(o.id.window);
            let zone = sliver::corner_zone(display.frame, display.visible, corner);
            if !zones.contains(&zone) {
                zones.push(zone);
            }
        }
        let seen = sliver::Seen {
            at: started,
            windows: sliver::near_zones(list, &zones),
        };
        if seen.fresh(Instant::now()).is_none() {
            return Err(tap::STALE);
        }
        Ok(Publication {
            shield: sliver::Shield {
                on: true,
                zones,
                parked: ids,
                dock,
            },
            seen,
            changing: preparing,
        })
    }
    fn refresh(&mut self, changing: bool) -> Result<(), u32> {
        if self.owned.is_empty() {
            self.patch.take();
            self.tap.take();
            self.last_refresh = None;
            return Ok(());
        }
        if changing {
            self.patch.take();
        }
        let current = self.publication(changing).inspect_err(|why| {
            self.patch.take();
            if let Some(t) = &self.tap {
                t.revoke(*why)
            }
        })?;
        match &self.tap {
            Some(t) => t.publish(current).inspect_err(|_| { self.patch.take(); })?,
            None => self.tap = Some(Tap::start(current)?),
        }
        self.last_refresh = Some(Instant::now());
        if !changing {
            // Only a proven parked footprint with a healthy, published input shield
            // may supply a visual. The sheet has no write authority over the member.
            let mut members: Vec<_> = self.owned.values().filter_map(|owned| owned.parked.map(|frame|
                native::PatchMember { member: owned.id, frame })).collect();
            members.sort_by_key(|m| m.member.window);
            if self.patch.is_none() { self.patch = native::PatchSession::new(); }
            if let Some(patch) = &self.patch { patch.publish(&members); }
        }
        Ok(())
    }
    /// Startup checks an empty-recipient real tap. A per-command check additionally binds the
    /// nominated window across both reads. Neither check grants authority to set an AX attribute.
    fn health(&self, r: &Request, control: &Control) -> Outcome {
        let probe = || -> Result<(), u32> {
            if !control.may_check_corner_input() {
                return Err(NEED_INDEPENDENT_READ);
            }
            let id = health_member(r)?;
            native::input_access()?;
            let input = native::inputs();
            let layout = native::displays()?;
            let retained = id
                .map(|id| -> Result<_, u32> {
                    scoped(&layout, id.display)?;
                    let first = native::sample(&id)?;
                    if let Some(o) = self.owned.get(&id.window) {
                        if o.id != id
                            || o.key != Key::from(r)
                            || !o.reference.matches(&id)
                            || !o.parked.is_some_and(|p| same(p, first.cg))
                        {
                            return Err(IDENTITY);
                        }
                    } else if !same(first.cg, rect(r.frame)) {
                        return Err(USER_CHANGED);
                    }
                    Ok((Reference::acquire(&id)?, first.cg))
                })
                .transpose()?;
            let first = self.publication(false)?;
            let initial_dock = first.shield.dock.clone();
            let temporary;
            let port = match &self.tap {
                Some(port) => {
                    port.publish(first)?;
                    port
                }
                None if self.owned.is_empty() => {
                    temporary = Tap::start(first)?;
                    &temporary
                }
                None => return Err(tap::UNAVAILABLE),
            };
            let second = self.publication(false)?;
            if let (Some(id), Some((reference, before))) = (id, retained) {
                if !reference.matches(&id) || !same(native::sample(&id)?.cg, before) {
                    return Err(USER_CHANGED);
                }
            }
            if initial_dock != second.shield.dock || layout != native::displays()? {
                return Err(USER_CHANGED);
            }
            native::input_access()?;
            if input != native::inputs() || !control.may_check_corner_input() {
                return Err(USER_CHANGED);
            }
            port.publish(second)
        };
        let owned = !self.owned.is_empty();
        match probe() {
            Err(e) => self.result(control.guard().err().unwrap_or(c::UNKNOWN), e, None, owned),
            Ok(()) => {
                let mut receipt = self.result(c::PASS, 0, None, owned);
                receipt.flags |= c::HEALTHY | c::INPUT_SAFE;
                receipt
            }
        }
    }
    fn read(&mut self, r: &Request) -> Outcome {
        let id = Member::from(r);
        let o = self.owned.get(&r.window);
        if o.is_some_and(|o| o.key != Key::from(r) || o.id != id || !o.reference.matches(&id)) {
            return self.result(c::FAIL, IDENTITY, None, true);
        }
        let s = match native::sample(&id) {
            Ok(s) => s,
            Err(why) => return self.result(c::UNKNOWN, why, None, o.is_some()),
        };
        let mut out = self.result(c::PASS, 0, Some(s), o.is_some());
        out.native_id = id.native;
        match o {
            None => {
                if same(s.cg, rect(r.frame))
                    && native::displays().is_ok_and(|d| {
                        scoped(&d, id.display)
                            .is_ok_and(|(_, corner)| origin_safe(s.cg, &d, id.display, corner))
                    })
                {
                    out.flags |= c::VISIBLE;
                } else {
                    out.status = c::UNKNOWN;
                    out.detail = USER_CHANGED;
                }
            }
            Some(o)
                if o.parked.is_some_and(|p| same(p, s.cg))
                    && native::displays()
                        .is_ok_and(|d| d == o.displays && hidden(s.cg, &d, id.display, o.corner)) =>
            {
                out.flags |= c::HIDDEN;
                if let Some(t) = &self.tap {
                    match t.health() {
                        Ok(()) => out.flags |= c::INPUT_SAFE,
                        Err(e) => {
                            out.detail = e;
                            out.status = c::UNKNOWN;
                        }
                    }
                } else {
                    out.status = c::UNKNOWN;
                    out.detail = tap::UNAVAILABLE;
                }
            }
            Some(_) => {
                out.status = c::UNKNOWN;
                out.detail = USER_CHANGED;
            }
        };
        out
    }
    fn hide(&mut self, r: &Request, control: &Control) -> Outcome {
        let input = native::inputs();
        if self.owned.contains_key(&r.window) || self.owned.len() >= 32 {
            return self.result(c::FAIL, IDENTITY, None, true);
        }
        let id = Member::from(r);
        let layout = match native::displays() {
            Ok(v) => v,
            Err(e) => return self.result(c::UNKNOWN, e, None, false),
        };
        let (display, corner) = match scoped(&layout, id.display) {
            Ok(v) => v,
            Err(e) => return self.result(c::UNSUPPORTED, e, None, false),
        };
        let sample = match native::sample(&id) {
            Ok(v) => v,
            Err(e) => return self.result(c::UNKNOWN, e, None, false),
        };
        if !same(sample.cg, rect(r.frame)) || !origin_safe(sample.cg, &layout, id.display, corner) {
            return self.result(c::FAIL, USER_CHANGED, Some(sample), false);
        }
        let reference = match Reference::acquire(&id) {
            Ok(v) => v,
            Err(e) => return self.result(c::UNKNOWN, e, None, false),
        };
        let target = park::park_frame_at(sample.cg.size(), display.frame, corner);
        let original = sample.cg;
        self.owned.insert(
            id.window,
            Owned {
                key: Key::from(r),
                id,
                reference,
                original,
                parked: None,
                displays: layout,
                corner,
            },
        );
        if let Err(e) = self.refresh(true) {
            self.owned.remove(&id.window);
            let _ = self.refresh(false);
            return self.result(c::UNKNOWN, e, None, false);
        }
        let o = &self.owned[&id.window];
        let (reason, issued) = native::position(
            &id,
            &o.reference,
            original,
            target,
            control,
            input,
            self.tap.as_ref(),
        );
        if !issued {
            self.owned.remove(&id.window);
            let _ = self.refresh(false);
            return self.result(control.guard().err().unwrap_or(c::UNKNOWN), reason, None, false);
        }
        // A setter timeout is already an issued effect; never resubmit. Read independently.
        let mut previous = None;
        for _ in 0..12 {
            if let Err(status) = control.guard() {
                return self.result(status, reason, None, true);
            }
            if let Ok(s) = native::sample(&id) {
                let o = &self.owned[&id.window];
                if o.reference.matches(&id)
                    && hidden(s.cg, &o.displays, id.display, corner)
                    && native::displays().is_ok_and(|d| d == o.displays)
                {
                    if previous.is_some_and(|p| same(p, s.cg)) {
                        self.owned.get_mut(&id.window).unwrap().parked = Some(s.cg);
                        return match self.refresh(false) {
                            Ok(()) => self.read(r),
                            Err(why) => self.result(c::UNKNOWN, why, Some(s), true),
                        };
                    }
                    previous = Some(s.cg);
                } else {
                    previous = None;
                }
            } else {
                previous = None;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        if let Some(t) = &self.tap {
            t.revoke(POSTCONDITION);
        }
        self.result(
            c::UNKNOWN,
            if reason == 0 { POSTCONDITION } else { reason },
            None,
            true,
        )
    }
    fn restore(&mut self, r: &Request, control: &Control) -> Outcome {
        let id = Member::from(r);
        let Some(o) = self.owned.get(&r.window) else {
            return self.result(c::UNKNOWN, OWNERSHIP_UNKNOWN, None, false);
        };
        let input = native::inputs();
        if o.key != Key::from(r) || o.id != id || !o.reference.matches(&id) {
            return self.result(c::FAIL, IDENTITY, None, true);
        }
        if !r.target.valid() || !same(o.original, rect(r.target)) {
            return self.result(c::FAIL, NO_TARGET, None, true);
        }
        let layout = match native::displays() {
            Ok(d) if d == o.displays => d,
            _ => return self.result(c::UNKNOWN, BAD_LAYOUT, None, true),
        };
        let s = match native::sample(&id) {
            Ok(v) => v,
            Err(e) => return self.result(c::UNKNOWN, e, None, true),
        };
        let mut remaining_reason = 0;
        if !same(s.cg, o.original) {
            if !o.parked.is_some_and(|p| same(p, s.cg)) || !hidden(s.cg, &layout, id.display, o.corner) {
                return self.result(c::UNKNOWN, USER_CHANGED, Some(s), true);
            }
            self.patch.take();
            // Mark the moving receiver uncertain before dispatch; keep other parked ownership until readback.
            if let Ok(p) = self.publication(false) {
                if let Some(t) = &self.tap {
                    let _ = t.publish(Publication { changing: true, ..p });
                }
            }
            let (why, issued) = native::position(&id, &o.reference, s.cg, o.original, control, input, None);
            if !issued {
                return self.result(control.guard().err().unwrap_or(c::UNKNOWN), why, None, true);
            }
            remaining_reason = why;
        }
        let mut first = false;
        for _ in 0..12 {
            if let Err(status) = control.guard() {
                return self.result(status, remaining_reason, None, true);
            }
            if let Ok(after) = native::sample(&id) {
                if same(after.cg, o.original)
                    && o.reference.matches(&id)
                    && native::displays().is_ok_and(|d| d == layout)
                {
                    if first {
                        self.owned.remove(&id.window);
                        let mut result = self.result(c::PASS, 0, Some(after), false);
                        result.flags |= c::VISIBLE;
                        result.native_id = id.native;
                        if let Err(reason) = self.refresh(false) {
                            result.status = c::UNKNOWN;
                            result.detail = reason;
                        }
                        return result;
                    }
                    first = true;
                } else {
                    first = false;
                }
            } else {
                first = false;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        self.result(
            c::UNKNOWN,
            if remaining_reason == 0 {
                POSTCONDITION
            } else {
                remaining_reason
            },
            None,
            true,
        )
    }
}
impl WindowEngine for Corner {
    fn execute(&mut self, r: &Request, control: &Control) -> Outcome {
        if let Err(status) = control.guard() {
            return Outcome::new(status);
        }
        if r.backend != c::CORNER || !r.valid() {
            return Outcome::new(c::FAIL);
        }
        match r.operation {
            c::PROBE => match native::displays().and_then(|_| native::zorder()) {
                Ok(_) => self.result(c::PASS, NEED_INDEPENDENT_READ, None, false),
                Err(e) => self.result(c::UNKNOWN, e, None, false),
            },
            c::HEALTH => self.health(r, control),
            c::READBACK => self.read(r),
            c::HIDE if control.may_write() => self.hide(r, control),
            c::SHOW | c::RESTORE if control.may_write() => self.restore(r, control),
            c::HIDE | c::SHOW | c::RESTORE | c::TRIAL => self.result(c::UNSUPPORTED, 0, None, false),
            _ => self.result(c::FAIL, 0, None, false),
        }
    }
    fn tick(&mut self) {
        if !self.owned.is_empty()
            && self
                .last_refresh
                .is_none_or(|t| t.elapsed() >= Duration::from_millis(80))
        {
            self.last_refresh = Some(Instant::now());
            let _ = self.refresh(false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn display(id: u8, x: f64, y: f64) -> Display {
        Display {
            id: [id; 16],
            frame: Rect::new(x, y, 1400., 900.),
            visible: Rect::new(x, y + 28., 1400., 824.),
        }
    }
    #[test]
    fn clamp_sliver_covers_a_bottom_dock_and_never_a_foreign_display() {
        let a = display(1, 0., 0.);
        let list = [a];
        let (_, c) = scoped(&list, a.id).unwrap();
        assert_eq!(c, park::Corner::BottomRight);
        let parked = Rect::new(1399., a.visible.max_y() - 32., 540., 340.);
        assert!(hidden(parked, &list, a.id, c));
        assert!(!hidden(Rect::new(1350., parked.y, 540., 340.), &list, a.id, c));
        let neighbour = display(2, 1400., 0.);
        assert!(!hidden(parked, &[a, neighbour], a.id, c));
        let (_, opposite) = scoped(&[a, neighbour], a.id).unwrap();
        assert_eq!(opposite, park::Corner::BottomLeft);
        let top = display(3, 1400., -900.);
        assert!(scoped(&[a, neighbour, top], a.id).is_ok());
    }
    #[test]
    fn unknown_display_or_all_four_overlapping_corners_refuse_writes() {
        let d = display(1, 0., 0.);
        let unrelated = [42; 16];
        assert!(scoped(&[d], unrelated).is_err());
        assert!(scoped(&[d, display(2, -1400., 0.), display(3, 1400., 0.)], d.id).is_err());
    }
    #[test]
    fn cross_display_and_parked_restore_origins_are_never_enrolled() {
        let a = display(1, 0., 0.);
        let b = display(2, -1400., 0.);
        let c = park::Corner::BottomRight;
        assert!(origin_safe(Rect::new(400., 120., 600., 400.), &[a, b], a.id, c));
        assert!(!origin_safe(Rect::new(-20., 120., 600., 400.), &[a, b], a.id, c));
        assert!(!origin_safe(Rect::new(1399., 820., 600., 400.), &[a, b], a.id, c));
        assert!(!origin_safe(
            Rect::new(f64::NAN, 120., 600., 400.),
            &[a, b],
            a.id,
            c
        ));
    }
    #[test]
    fn an_unqualified_idle_health_request_never_creates_a_port_or_attests_input_safety() {
        let c = Control {
            epoch: std::sync::Arc::new(1.into()),
            expected: 1,
            cancelled: std::sync::Arc::new(false.into()),
            deadline: Instant::now() + Duration::from_secs(2),
            write: false,
            spaces_route: None,
            corner_input_check: false,
        };
        let receipt = Corner::default().health(&Request::default(), &c);
        assert_eq!((receipt.status, receipt.flags), (c::UNKNOWN, 0));
    }
    #[test]
    fn a_full_window_lease_and_a_truly_empty_engine_health_have_distinct_shapes() {
        let empty = Request {
            backend: c::CORNER,
            operation: c::HEALTH,
            epoch: 1,
            timeout_ms: 200,
            intent: [1; 16],
            ..Default::default()
        };
        let full = Request {
            group: [2; 16],
            display: [3; 16],
            native_space: [4; 16],
            member: [5; 16],
            lifetime: [6; 16],
            generation: [7; 16],
            pid: 40,
            birth: 90,
            window: 71,
            native_id: 12,
            frame: c::Rect {
                x: 1.,
                y: 2.,
                width: 30.,
                height: 20.,
            },
            ..empty
        };
        assert_eq!(health_member(&empty), Ok(None));
        assert_eq!(health_member(&full), Ok(Some(Member::from(&full))));
        for bad in [
            Request { window: 71, ..empty },
            Request {
                generation: [7; 16],
                ..empty
            },
            Request {
                target: full.frame,
                ..empty
            },
            Request { pid: 0, ..full },
            Request { native_id: 0, ..full },
            Request {
                native_space: [0; 16],
                ..full
            },
            Request {
                frame: c::Rect::default(),
                ..full
            },
        ] {
            assert_eq!(health_member(&bad), Err(IDENTITY));
        }
    }
    #[test]
    fn cold_engine_cannot_adopt_a_parked_window_from_numeric_and_journal_ids() {
        const EPOCH: u64 = 18;
        let c = Control {
            epoch: std::sync::Arc::new(EPOCH.into()),
            expected: EPOCH,
            cancelled: std::sync::Arc::new(false.into()),
            deadline: Instant::now() + Duration::from_secs(2),
            write: true,
            spaces_route: None,
            corner_input_check: false,
        };
        let r = Request {
            pid: 9,
            window: 11,
            birth: 3434,
            epoch: EPOCH,
            native_id: 1,
            group: [4; 16],
            member: [2; 16],
            generation: [7; 16],
            lifetime: [8; 16],
            ..Default::default()
        };
        let result = Corner::default().restore(&r, &c);
        assert_eq!(
            (result.status, result.detail, result.owned, result.flags),
            (c::UNKNOWN, OWNERSHIP_UNKNOWN, 0, 0)
        );
    }
    #[test]
    fn member_group_lifetime_and_generation_are_matched_separately_from_pid_and_window() {
        let mut r = Request {
            group: [1; 16],
            lifetime: [2; 16],
            generation: [3; 16],
            member: [4; 16],
            pid: 45,
            window: 77,
            ..Default::default()
        };
        let key = Key::from(&r);
        r.lifetime = [5; 16];
        assert_ne!(key, Key::from(&r));
        r.lifetime = key.lifetime;
        r.generation = [6; 16];
        assert_ne!(key, Key::from(&r));
        r.generation = key.generation;
        r.group = [7; 16];
        assert_ne!(key, Key::from(&r));
        r.group = key.group;
        r.member = [8; 16];
        assert_ne!(key, Key::from(&r));
    }
}
