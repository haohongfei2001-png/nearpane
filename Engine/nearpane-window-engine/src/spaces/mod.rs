//! Hidden classic Spaces owned by this process, with a behavior-qualified move route.
//! Extracted from Eugene Tiutiunnyk's stage-manager (MIT); see origins/spaces.json.
//! All live state is confined to the WM worker. Durable member and intent authority stays with Swift.
use crate::contract::*;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::{Duration, Instant};

#[cfg(target_os = "macos")]
mod installed;
mod launch;
mod system;
type Id = [u8; 16];
type Check<T> = Result<T, Fault>;
type Rows = BTreeSet<u64>;
const LIMIT: usize = 64;
const DEADLINE: Duration = Duration::from_millis(120);
#[cfg(not(test))]
const GRACE: Duration = Duration::from_millis(40);
const STRIKE_WINDOW: Duration = Duration::from_secs(60);
const STRIKES: usize = 3;

// Stable values for the bounded ABI receipt; no window title or private data.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Why {
    Ready = 200,
    Disabled,
    Build,
    Symbols,
    Connection,
    Topology,
    Identity,
    Membership,
    Scope,
    MinimizedOrAX,
    Unowned,
    Conflict,
    Capacity,
    NoDelivery,
    Uncertain,
    NotEmpty,
    Stale,
    Readback,
    RestoreFirst,
    TrialOwnWindow,
    TrialPassed,
    ClassicRoute,
    BridgeRoute,
    ShowVerified,
    HideVerified,
    Cleanup,
    Health,
    LaunchPassed,
    ProbeClosed,
    ProbeFocus,
}
#[derive(Clone, Copy, Debug)]
struct Fault(u32, Why);
fn unknown(why: Why) -> Fault {
    Fault(UNKNOWN, why)
}
fn fail(why: Why) -> Fault {
    Fault(FAIL, why)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct Window {
    number: u32,
    pid: i32,
    birth: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct Home {
    display: Id,
    uuid: Id,
    id: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct Slot {
    home: Home,
    group: Id,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Lease {
    window: Window,
    slot: Slot,
    member: Id,
    lifetime: Id,
    generation: Id,
}
impl Lease {
    fn from(r: &Request) -> Check<Self> {
        let valid = r.window > 0
            && r.pid > 1
            && r.birth > 0
            && r.native_id > 0
            && [
                r.intent,
                r.group,
                r.display,
                r.native_space,
                r.member,
                r.lifetime,
                r.generation,
            ]
            .iter()
            .all(|id| *id != [0; 16]);
        if !valid {
            return Err(fail(Why::Identity));
        }
        Ok(Self {
            window: Window {
                number: r.window,
                pid: r.pid,
                birth: r.birth,
            },
            slot: Slot {
                home: Home {
                    display: r.display,
                    uuid: r.native_space,
                    id: r.native_id,
                },
                group: r.group,
            },
            member: r.member,
            lifetime: r.lifetime,
            generation: r.generation,
        })
    }
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
struct Desktop {
    display: Id,
    uuid: Id,
    id: u64,
    kind: i32,
    current: u32,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
enum Route {
    Classic = 1,
    Bridge = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Delivery {
    Refused,
    Accepted,
    Uncertain,
}
#[derive(Clone, Copy, Debug)]
struct Seen {
    visible: bool,
    rect: [f64; 4],
}

trait Platform {
    type Witness;
    fn flags(&self) -> u32;
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn target(&self) -> bool;
    fn connection(&self) -> Check<i32>;
    fn desktops(&self, c: i32) -> Check<Vec<Desktop>>;
    /// The sorted full inventory retains the multiplicity of managed full-screen Spaces.
    fn all(&self, c: i32) -> Check<Vec<u64>>;
    fn members(&self, c: i32, space: u64) -> Check<Rows>;
    fn spaces(&self, c: i32, number: u32) -> Check<Rows>;
    fn bind(&self, window: Window) -> Check<Self::Witness>;
    fn bind_minimized(&self, _window: Window) -> Check<Self::Witness> { Err(unknown(Why::MinimizedOrAX)) }
    fn see(&self, w: Window, witness: &Self::Witness) -> Check<Seen>;
    fn minimized(&self, _w: &Self::Witness) -> Check<bool> { Ok(false) }
    fn set_minimized(&mut self, _w: Window, _witness: &Self::Witness, _minimized: bool) -> Delivery { Delivery::Refused }
    fn transparent_canary(&self, _w: &Self::Witness) -> bool {
        false
    }
    fn enrolled_transparent_fixture(&self, _window: Window) -> bool {
        false
    }
    fn canary(&mut self, _op: launch::PanelOp, _a: &impl Authority) -> Check<launch::Panel> {
        Err(Fault(UNSUPPORTED, Why::Disabled))
    }
    fn absent(&self, _number: u32) -> Check<bool> {
        Err(unknown(Why::Readback))
    }
    /// True only when the exact process/window lifetime has ended. A failed query is unknown.
    fn departed(&self, window: Window) -> Check<bool> { self.absent(window.number) }
    fn create(&mut self, c: i32) -> Check<u64>;
    fn destroy(&mut self, c: i32, space: u64) -> Delivery;
    fn move_window(&mut self, c: i32, route: Route, w: Window, target: u64, mask: u32) -> Delivery;
}
trait Authority {
    fn active(&self) -> Check<()>;
    fn observation(&self) -> Check<()>;
    fn fixture_parked_input(&self, _parking: u64) -> Check<()> {
        Ok(())
    }
    fn fixture_companions(&self, _home: u64, _hidden: bool) -> Check<()> {
        Ok(())
    }
    fn fixture_home_ax(&self) -> Check<()> {
        Ok(())
    }
    fn fixture_journal_start(
        &self,
        _top: &[Desktop],
        _inventory: &[u64],
        _home: u64,
        _frame: Option<&[f64; 4]>,
        _members: usize,
    ) -> Check<()> {
        Ok(())
    }
    fn fixture_membership_receipt(&self, _window: Window, _space: u64, _hidden: bool) -> Check<()> {
        Ok(())
    }
    fn fixture_recovered(&self, _external: bool, _window: u32, _space: u64) -> Check<()> {
        Ok(())
    }
    fn approved_route(&self) -> Option<Route> {
        None
    }
    fn retained(&self) -> Option<PanelPermit> {
        None
    }
}
// Issued only for an already authorized callback that opens/closes a Host-owned
// panel. The installed fixture permit never becomes a generic engine Control.
enum PanelPermit {
    Runtime(Control),
    #[cfg(target_os = "macos")]
    Fixture(installed::Guard),
}
impl PanelPermit {
    fn allowed(&self) -> bool {
        match self {
            Self::Runtime(control) => control.may_write(),
            #[cfg(target_os = "macos")]
            Self::Fixture(guard) => guard.active().is_ok(),
        }
    }
}
impl Authority for Control {
    fn approved_route(&self) -> Option<Route> {
        match self.approved_spaces_route()? {
            1 => Some(Route::Classic),
            2 => Some(Route::Bridge),
            _ => None,
        }
    }
    fn retained(&self) -> Option<PanelPermit> {
        Some(PanelPermit::Runtime(self.clone()))
    }
    fn active(&self) -> Check<()> {
        self.observation()?;
        if self.may_write() {
            Ok(())
        } else {
            Err(Fault(UNSUPPORTED, Why::Disabled))
        }
    }
    fn observation(&self) -> Check<()> {
        self.guard().map_err(|s| Fault(s, Why::Stale))
    }
}

struct Passive(Instant);
impl Authority for Passive {
    fn active(&self) -> Check<()> {
        Err(Fault(UNSUPPORTED, Why::Disabled))
    }
    fn observation(&self) -> Check<()> {
        if Instant::now() < self.0 {
            Ok(())
        } else {
            Err(Fault(TIMEOUT, Why::Readback))
        }
    }
}

struct Bound<W> {
    lease: Lease,
    witness: W,
    original: [f64; 4],
    pending_target: std::cell::Cell<Option<u64>>,
}
struct Space {
    id: u64,
    destroy_issued: bool,
    owner: Lease,
}
struct State<P: Platform> {
    sys: P,
    connection: Option<i32>,
    route: Option<Route>,
    owned: BTreeMap<Window, Bound<P::Witness>>,
    slots: BTreeMap<Slot, Space>,
    seen_intents: BTreeSet<Id>,
    strikes: VecDeque<Instant>,
    failed: bool,
    next_tick: Option<Instant>,
    launch: Option<launch::CanaryRun>,
    tick_cursor: usize,
}
impl<P: Platform> State<P> {
    fn new(sys: P) -> Self {
        Self {
            sys,
            connection: None,
            route: None,
            owned: BTreeMap::new(),
            slots: BTreeMap::new(),
            seen_intents: BTreeSet::new(),
            strikes: VecDeque::new(),
            failed: false,
            next_tick: None,
            launch: None,
            tick_cursor: 0,
        }
    }
    fn connect(&mut self) -> Check<i32> {
        if !self.sys.target() {
            return Err(Fault(UNSUPPORTED, Why::Build));
        }
        if self.sys.flags() & 1 == 0 {
            return Err(Fault(UNSUPPORTED, Why::Symbols));
        }
        let c = self.sys.connection()?;
        if self.connection.is_some_and(|old| old != c) {
            self.failed = true;
            return Err(unknown(Why::Connection));
        }
        self.connection = Some(c);
        Ok(c)
    }
    fn topology(&self, c: i32, home: Home) -> Check<Vec<Desktop>> {
        if self.sys.connection()? != c {
            return Err(unknown(Why::Connection));
        }
        let mut list = self.sys.desktops(c)?;
        let mut ids = Rows::new();
        let mut scopes = BTreeSet::new();
        let mut current = BTreeMap::new();
        for d in &list {
            if d.id == 0
                || d.display == [0; 16]
                || d.uuid == [0; 16]
                || !ids.insert(d.id)
                || !scopes.insert((d.display, d.uuid))
            {
                return Err(unknown(Why::Topology));
            }
            *current.entry(d.display).or_insert(0u32) += d.current;
        }
        if !current.values().all(|v| *v == 1)
            || !list.iter().any(|d| {
                d.display == home.display
                    && d.id == home.id
                    && d.uuid == home.uuid
                    && d.kind == 0
            })
        {
            return Err(unknown(Why::Scope));
        }
        // Display enumeration can vary. The order of Spaces within each physical
        // display is user-visible in Mission Control and must survive a transaction.
        list.sort_by_key(|desktop| desktop.display);
        Ok(list)
    }
    fn scope(&self, c: i32, home: Home, top: &[Desktop], a: &impl Authority) -> Check<()> {
        a.observation()?;
        if self.topology(c, home)? != top {
            return Err(unknown(Why::Topology));
        }
        Ok(())
    }
    fn occupants(&self, c: i32, slot: Slot, sid: u64) -> Check<Rows> {
        let set = self.sys.members(c, sid)?;
        if set.iter().any(|id| {
            !self
                .owned
                .values()
                .any(|w| w.lease.slot == slot && u64::from(w.lease.window.number) == *id)
        }) {
            return Err(unknown(Why::NotEmpty));
        }
        Ok(set)
    }
    fn get_slot(
        &mut self,
        c: i32,
        lease: Lease,
        witness: &P::Witness,
        top: &[Desktop],
        a: &impl Authority,
        from_minimized: bool,
    ) -> Check<u64> {
        let slot = lease.slot;
        if let Some(s) = self.slots.get(&slot) {
            let id = s.id;
            if s.destroy_issued || !self.sys.all(c)?.contains(&id) || top.iter().any(|d| d.id == id)
            {
                return Err(unknown(Why::Conflict));
            }
            self.occupants(c, slot, id)?;
            return Ok(id);
        }
        if self.slots.len() >= LIMIT {
            return Err(fail(Why::Capacity));
        }
        let before = self.sys.all(c)?;
        self.scope(c, slot.home, top, a)?;
        if from_minimized { self.minimized_view(c, lease, witness, 0)?; }
        else { self.view(c, lease, witness, 0, false)?; }
        a.active()?;
        let sid = self.sys.create(c).inspect_err(|_| self.failed = true)?;
        // Never claim or destroy a pre-existing ID, even when creation returned it.
        if sid == 0 || before.contains(&sid) || top.iter().any(|d| d.id == sid) {
            self.failed = true;
            return Err(unknown(Why::Conflict));
        }
        self.slots.insert(
            slot,
            Space {
                id: sid,
                destroy_issued: false,
                owner: lease,
            },
        );
        let mut expected = before;
        expected.push(sid);
        expected.sort_unstable();
        if self.sys.all(c)? != expected || !self.sys.members(c, sid)?.is_empty() {
            return Err(unknown(Why::Conflict));
        }
        self.scope(c, slot.home, top, a)?;
        Ok(sid)
    }
    fn cleanup(&mut self, c: i32, slot: Slot, top: &[Desktop], a: &impl Authority) -> Check<()> {
        let Some(s) = self.slots.get(&slot) else {
            return Ok(());
        };
        let sid = s.id;
        if self.owned.values().any(|w| w.lease.slot == slot) {
            return Ok(());
        }
        self.scope(c, slot.home, top, a)?;
        if top.iter().any(|d| d.id == sid) {
            return Err(unknown(Why::Conflict));
        }
        let before = self.sys.all(c)?;
        if !before.contains(&sid) {
            if s.destroy_issued {
                self.slots.remove(&slot);
                return Ok(());
            }
            return Err(unknown(Why::Connection));
        }
        if s.destroy_issued {
            return Err(unknown(Why::Uncertain));
        }
        if !self.sys.members(c, sid)?.is_empty() {
            return Err(unknown(Why::NotEmpty));
        }
        self.scope(c, slot.home, top, a)?;
        if !self.sys.members(c, sid)?.is_empty() {
            return Err(unknown(Why::NotEmpty));
        }
        a.active()?;
        self.slots.get_mut(&slot).unwrap().destroy_issued = true;
        if self.sys.destroy(c, sid) == Delivery::Refused {
            self.slots.get_mut(&slot).unwrap().destroy_issued = false;
            return Err(fail(Why::NoDelivery));
        }
        let mut expected = before;
        expected.retain(|id| *id != sid);
        let until = Instant::now() + DEADLINE;
        loop {
            self.scope(c, slot.home, top, a)?;
            if self.sys.all(c)? == expected {
                self.slots.remove(&slot);
                return Ok(());
            }
            if Instant::now() >= until {
                return Err(unknown(Why::Cleanup));
            }
            std::thread::sleep(Duration::from_millis(4));
        }
    }
    fn view(&self, c: i32, lease: Lease, w: &P::Witness, sid: u64, hidden: bool) -> Check<Seen> {
        let window = lease.window;
        if self.sys.minimized(w)? { return Err(unknown(Why::MinimizedOrAX)); }
        let target = if hidden { sid } else { lease.slot.home.id };
        let a = self.sys.see(window, w)?;
        let membership = self.sys.spaces(c, window.number)?;
        if membership != Rows::from([target])
            || !self
                .sys
                .members(c, target)?
                .contains(&u64::from(window.number))
        {
            return Err(unknown(Why::Membership));
        }
        let other = if hidden { lease.slot.home.id } else { sid };
        if other != 0
            && self
                .sys
                .members(c, other)?
                .contains(&u64::from(window.number))
        {
            return Err(unknown(Why::Membership));
        }
        let b = self.sys.see(window, w)?;
        let home_visible = self.sys.desktops(c)?.iter().any(|d| {
            d.display == lease.slot.home.display && d.id == lease.slot.home.id && d.current == 1
        });
        if a.rect != b.rect
            || a.visible != b.visible
            || (!self.sys.transparent_canary(w)
                && b.visible == hidden
                && (hidden || (home_visible && !self.sys.enrolled_transparent_fixture(window))))
        {
            return Err(unknown(Why::Readback));
        }
        Ok(b)
    }
    fn minimized_view(&self, c: i32, lease: Lease, w: &P::Witness, sid: u64) -> Check<Seen> {
        let seen = self.sys.see(lease.window, w)?;
        if seen.visible || !self.sys.minimized(w)? { return Err(unknown(Why::MinimizedOrAX)); }
        let membership = self.sys.spaces(c, lease.window.number)?;
        let valid = if sid == 0 {
            membership.is_empty() || membership == Rows::from([lease.slot.home.id])
        } else { membership == Rows::from([sid]) };
        if !valid || (sid != 0 && !self.sys.members(c, sid)?.contains(&u64::from(lease.window.number))) {
            return Err(unknown(Why::Membership));
        }
        Ok(seen)
    }
    fn moved(
        &mut self,
        c: i32,
        lease: Lease,
        sid: u64,
        hidden: bool,
        route: Route,
        top: &[Desktop],
        a: &impl Authority,
    ) -> Check<()> {
        let bound = self.owned.get(&lease.window).ok_or(fail(Why::Unowned))?;
        if bound.lease != lease {
            return Err(fail(Why::Identity));
        }
        self.occupants(c, lease.slot, sid)?;
        let original = self.view(c, lease, &bound.witness, sid, !hidden)?;
        if hidden && original.rect != bound.original {
            return Err(unknown(Why::Identity));
        }
        self.scope(c, lease.slot.home, top, a)?;
        #[cfg(test)]
        let grace = Duration::from_millis(4);
        #[cfg(not(test))]
        let grace = GRACE;
        let latest = self.sys.see(lease.window, &bound.witness)?;
        if latest.visible != original.visible || latest.rect != original.rect {
            return Err(unknown(Why::Identity));
        }
        if self.sys.spaces(c, lease.window.number)?
            != Rows::from([if hidden { lease.slot.home.id } else { sid }])
        {
            return Err(unknown(Why::Membership));
        }
        a.active()?;
        let target = if hidden { sid } else { lease.slot.home.id };
        let mask = if hidden { 7 } else { 15 };
        if bound.pending_target.get() == Some(target) {
            return Err(unknown(Why::Uncertain));
        }
        bound.pending_target.set(Some(target));
        if self.sys.move_window(c, route, lease.window, target, mask) == Delivery::Refused {
            bound.pending_target.set(None);
            return Err(fail(Why::NoDelivery));
        }
        let started = Instant::now();
        let until = started + DEADLINE;
        let mut hit = 0;
        let mut missed = false;
        loop {
            self.scope(c, lease.slot.home, top, a)?;
            match self.view(c, lease, &bound.witness, sid, hidden) {
                Ok(seen) if seen.rect == original.rect => {
                    hit += 1;
                    if hit >= 2 {
                        break;
                    }
                }
                Err(Fault(_, Why::Membership | Why::Readback)) => {
                    hit = 0;
                    missed |= started.elapsed() >= grace;
                }
                Err(e) => {
                    self.failed = true;
                    return Err(e);
                }
                _ => {
                    self.failed = true;
                    return Err(unknown(Why::Identity));
                }
            }
            if Instant::now() >= until {
                self.failed = true;
                return Err(Fault(TIMEOUT, Why::Uncertain));
            }
            std::thread::sleep(Duration::from_millis(4));
        }
        bound.pending_target.set(None);
        a.fixture_membership_receipt(lease.window, target, hidden)?;
        if missed {
            self.record_late(self.sys.now());
        }
        Ok(())
    }
    fn hide(
        &mut self,
        c: i32,
        lease: Lease,
        expected: [f64; 4],
        route: Route,
        a: &impl Authority,
    ) -> Check<()> {
        let top = self.topology(c, lease.slot.home)?;
        // A normal hide belongs to the ordinary Desktop currently shown. Merely
        // changing Desktops never moves a window or rewrites another Desktop's group.
        if !top.iter().any(|d| d.id == lease.slot.home.id && d.current == 1) {
            return Err(unknown(Why::Scope));
        }
        if self.owned.len() >= LIMIT
            || self.owned.contains_key(&lease.window)
            || self.owned.values().any(|w| {
                w.lease.window.number == lease.window.number
                    || w.lease.member == lease.member
                    || w.lease.lifetime == lease.lifetime
            })
        {
            return Err(fail(Why::Conflict));
        }
        let witness = self.sys.bind(lease.window)?;
        let original = self.view(c, lease, &witness, 0, false)?;
        if original.rect != expected {
            return Err(unknown(Why::Identity));
        }
        let sid = self.get_slot(c, lease, &witness, &top, a, false)?;
        self.owned.insert(
            lease.window,
            Bound {
                lease,
                witness,
                original: original.rect,
                pending_target: std::cell::Cell::new(None),
            },
        );
        self.moved(c, lease, sid, true, route, &top, a)
    }
    fn hide_minimized(&mut self, c: i32, lease: Lease, expected: [f64; 4], route: Route, a: &impl Authority) -> Check<()> {
        let top = self.topology(c, lease.slot.home)?;
        if !top.iter().any(|d| d.id == lease.slot.home.id && d.current == 1)
            || self.owned.len() >= LIMIT || self.owned.contains_key(&lease.window)
            || self.owned.values().any(|w| w.lease.window.number == lease.window.number
                || w.lease.member == lease.member || w.lease.lifetime == lease.lifetime) {
            return Err(fail(Why::Conflict));
        }
        let witness = self.sys.bind_minimized(lease.window)?;
        let before = self.minimized_view(c, lease, &witness, 0)?;
        if before.rect != expected { return Err(unknown(Why::Identity)); }
        let sid = self.get_slot(c, lease, &witness, &top, a, true)?;
        self.owned.insert(lease.window, Bound { lease, witness, original: before.rect,
            pending_target: std::cell::Cell::new(None) });
        let bound = &self.owned[&lease.window];
        self.scope(c, lease.slot.home, &top, a)?;
        a.active()?;
        bound.pending_target.set(Some(sid));
        if self.sys.move_window(c, route, lease.window, sid, 7) == Delivery::Refused {
            bound.pending_target.set(None); return Err(fail(Why::NoDelivery));
        }
        let until = Instant::now() + DEADLINE;
        loop {
            self.scope(c, lease.slot.home, &top, a)?;
            if self.minimized_view(c, lease, &bound.witness, sid).is_ok() { break; }
            if Instant::now() >= until { return Err(unknown(Why::Membership)); }
            std::thread::sleep(Duration::from_millis(4));
        }
        bound.pending_target.set(None);
        // Clearing Dock minimization is safe only after exclusive hidden-Space
        // membership is independently observed. Never reveal first and hide later.
        a.active()?;
        if self.sys.set_minimized(lease.window, &bound.witness, false) == Delivery::Refused {
            return Err(fail(Why::NoDelivery));
        }
        let until = Instant::now() + DEADLINE;
        let mut consecutive = 0;
        loop {
            self.scope(c, lease.slot.home, &top, a)?;
            if self.view(c, lease, &bound.witness, sid, true).is_ok() { consecutive += 1; }
            else { consecutive = 0; }
            if consecutive == 2 { return Ok(()); }
            if Instant::now() >= until { return Err(unknown(Why::Readback)); }
            std::thread::sleep(Duration::from_millis(4));
        }
    }
    fn restore_member(
        &mut self,
        c: i32,
        lease: Lease,
        route: Route,
        top: &[Desktop],
        a: &impl Authority,
    ) -> Check<()> {
        let sid = self.slots.get(&lease.slot).ok_or(fail(Why::Unowned))?.id;
        let Some(saved) = self.owned.get(&lease.window) else {
            if self
                .slots
                .get(&lease.slot)
                .is_some_and(|s| s.owner == lease)
                && self
                    .owned
                    .values()
                    .all(|other| other.lease.slot != lease.slot)
            {
                return Ok(());
            }
            return Err(fail(Why::Unowned));
        };
        if saved.lease != lease {
            return Err(fail(Why::Identity));
        }
        if self.sys.minimized(&saved.witness)? {
            // An interrupted mini adoption still belongs to this lease. Return its
            // real Space membership while preserving its existing Dock minimization.
            self.scope(c, lease.slot.home, top, a)?;
            a.active()?;
            if self.sys.move_window(c, route, lease.window, lease.slot.home.id, 15) == Delivery::Refused {
                return Err(fail(Why::NoDelivery));
            }
            let until = Instant::now() + DEADLINE;
            loop {
                self.scope(c, lease.slot.home, top, a)?;
                let membership = self.sys.spaces(c, lease.window.number)?;
                if !membership.contains(&sid) && !self.sys.members(c, sid)?.contains(&u64::from(lease.window.number))
                    && self.minimized_view(c, lease, &saved.witness, 0).is_ok() { break; }
                if Instant::now() >= until { return Err(unknown(Why::RestoreFirst)); }
                std::thread::sleep(Duration::from_millis(4));
            }
            self.owned.remove(&lease.window);
            if let Some(s) = self.slots.get_mut(&lease.slot) { s.owner = lease; }
            return Ok(());
        }
        // A failed callback may have completed. Reconcile twice without replaying the move.
        if self
            .view(c, lease, &saved.witness, sid, false)
            .is_ok()
        {
            self.scope(c, lease.slot.home, top, a)?;
            self.view(c, lease, &saved.witness, sid, false)?;
        } else {
            self.moved(c, lease, sid, false, route, top, a)?;
        }
        self.owned.remove(&lease.window);
        if let Some(s) = self.slots.get_mut(&lease.slot) {
            s.owner = lease;
        }
        Ok(())
    }
    fn show(&mut self, c: i32, lease: Lease, route: Route, a: &impl Authority) -> Check<()> {
        let top = self.topology(c, lease.slot.home)?;
        self.restore_member(c, lease, route, &top, a)?;
        self.cleanup(c, lease.slot, &top, a)
    }
    fn read(&self, c: i32, lease: Lease, a: &impl Authority) -> Check<(Seen, bool)> {
        let top = self.topology(c, lease.slot.home)?;
        if let Some(saved) = self.owned.get(&lease.window) {
            if saved.lease != lease {
                return Err(fail(Why::Identity));
            }
            let sid = self.slots.get(&lease.slot).ok_or(unknown(Why::Unowned))?.id;
            let m = self.sys.spaces(c, lease.window.number)?;
            let hidden = m == Rows::from([sid]);
            let seen = self.view(c, lease, &saved.witness, sid, hidden)?;
            self.scope(c, lease.slot.home, &top, a)?;
            Ok((seen, hidden))
        } else {
            let w = self.sys.bind(lease.window)?;
            let seen = self.view(c, lease, &w, 0, false)?;
            self.scope(c, lease.slot.home, &top, a)?;
            Ok((seen, false))
        }
    }
    fn trial(
        &mut self,
        c: i32,
        lease: Lease,
        expected: [f64; 4],
        route: Route,
        a: &impl Authority,
    ) -> Check<()> {
        if lease.window.pid != std::process::id() as i32
            || !self.owned.is_empty()
            || !self.slots.is_empty()
        {
            return Err(fail(Why::TrialOwnWindow));
        }
        if self.sys.flags() & (if route == Route::Classic { 2 } else { 4 }) == 0 {
            return Err(Fault(UNSUPPORTED, Why::Symbols));
        }
        // A new trial is a new intent. No alternative route is attempted after ambiguous delivery.
        self.route = None;
        let hidden = self.hide(c, lease, expected, route, a);
        let restored = if self.owned.contains_key(&lease.window) {
            self.show(c, lease, route, a)
        } else if self.slots.contains_key(&lease.slot) {
            let top = self.topology(c, lease.slot.home)?;
            self.cleanup(c, lease.slot, &top, a)
        } else {
            Ok(())
        };
        if restored.is_err() || !self.slots.is_empty() || !self.owned.is_empty() {
            self.failed = true;
            self.route = Some(route);
            return Err(unknown(Why::RestoreFirst));
        }
        hidden?;
        restored?;
        if self.failed {
            return Err(fail(Why::Health));
        }
        self.route = Some(route);
        Ok(())
    }
    /// While windows are parked, read one enrolled window per tick. No timer, system
    /// read or reference survives an empty state. Recovery still requires Swift's
    /// original member identity and a fresh authorization for each system write.
    fn observe_health(&mut self) {
        if self.owned.is_empty() || self.failed || self.route.is_none() {
            return;
        }
        let now = Instant::now();
        if self.next_tick.is_some_and(|t| now < t) {
            return;
        }
        self.next_tick = Some(now + Duration::from_millis(350));
        self.reap_departed();
        if self.owned.is_empty() { return; }
        let index = self.tick_cursor % self.owned.len();
        self.tick_cursor = index + 1;
        let lease = self.owned.values().nth(index).unwrap().lease;
        let result = (|| -> Check<()> {
            let c = self.connection.ok_or(unknown(Why::Connection))?;
            let sid = self.slots.get(&lease.slot).ok_or(unknown(Why::Unowned))?.id;
            let deadline = Passive(now + Duration::from_millis(650));
            self.occupants(c, lease.slot, sid)?;
            if !self.read(c, lease, &deadline)?.1 {
                return Err(unknown(Why::Membership));
            }
            Ok(())
        })();
        if result.is_err() {
            self.failed = true;
        }
    }

    fn record_late(&mut self, now: Instant) {
        self.strikes
            .retain(|t| now.duration_since(*t) < STRIKE_WINDOW);
        self.strikes.push_back(now);
        if self.strikes.len() >= STRIKES {
            self.failed = true;
        }
    }

    fn reap_departed(&mut self) {
        let gone: Vec<_> = self.owned.keys().copied()
            .filter(|w| self.sys.departed(*w).is_ok_and(|gone| gone)).collect();
        for window in gone { self.owned.remove(&window); }
    }

    /// Shutdown is driven by retained leases, so closed windows or a changed UI
    /// roster cannot strand the remaining windows. Each surviving window is still
    /// checked against its process birth, AX reference and hidden Space membership.
    fn release_all(&mut self, c: i32, a: &impl Authority) -> Check<()> {
        a.active()?;
        if self.launch.as_ref().is_some_and(|p| !p.cleaned) {
            let route = a.approved_route().ok_or(Fault(UNSUPPORTED, Why::Disabled))?;
            self.finish_canary(c, route, a)?;
        }
        self.reap_departed();
        let route = self.route.or_else(|| a.approved_route())
            .ok_or(Fault(UNSUPPORTED, Why::Disabled))?;
        let leases: Vec<_> = self.owned.values().map(|b| b.lease).collect();
        let mut error = None;
        for lease in leases {
            if let Err(e) = self.show(c, lease, route, a) { error = Some(e); }
        }
        let empty: Vec<_> = self.slots.keys().copied()
            .filter(|slot| !self.owned.values().any(|b| b.lease.slot == *slot)).collect();
        for slot in empty {
            match self.topology(c, slot.home).and_then(|top| self.cleanup(c, slot, &top, a)) {
                Ok(()) => (), Err(e) => error = Some(e),
            }
        }
        if let Some(error) = error { return Err(error); }
        if !self.owned.is_empty() || !self.slots.is_empty() { return Err(unknown(Why::RestoreFirst)); }
        Ok(())
    }

    fn run(&mut self, r: &Request, a: &impl Authority) -> Outcome {
        let mut out = Outcome::new(UNKNOWN);
        let mut detail = Why::Ready;
        let res = (|| -> Check<()> {
            a.observation()?;
            let c = self.connect()?;
            self.reap_departed();
            if r.operation == RELEASE_SPACES {
                if !r.valid() { return Err(fail(Why::Identity)); }
                self.release_all(c, a)?;
                out.status = PASS;
                out.flags = MEMBERSHIP_VALID;
                detail = Why::Cleanup;
                return Ok(());
            }
            if r.operation == PROBE {
                // Symbol availability is diagnostic only; no operating capability or health is granted.
                let flags = self.sys.flags();
                out.status = if self.route.is_some() && !self.failed {
                    PASS
                } else {
                    UNKNOWN
                };
                if out.status == PASS {
                    out.flags = HEALTHY;
                }
                detail = if flags & 4 != 0 {
                    Why::BridgeRoute
                } else if flags & 2 != 0 {
                    Why::ClassicRoute
                } else {
                    Why::Symbols
                };
                return Ok(());
            }
            if r.operation == HEALTH {
                if self.route.is_none() || self.failed {
                    return Err(unknown(Why::RestoreFirst));
                }
                for saved in self.owned.values() {
                    if !self.read(c, saved.lease, a)?.1 {
                        return Err(unknown(Why::Membership));
                    }
                }
                for (&slot, space) in &self.slots {
                    self.occupants(c, slot, space.id)?;
                    if !self.sys.all(c)?.contains(&space.id) {
                        return Err(unknown(Why::Membership));
                    }
                }
                out.flags = HEALTHY;
                out.status = PASS;
                detail = Why::Health;
                return Ok(());
            }
            if matches!(r.operation, LAUNCH | CLEAN_LAUNCH) {
                if !r.valid() {
                    return Err(fail(Why::Identity));
                }
                let route = a
                    .approved_route()
                    .ok_or(Fault(UNSUPPORTED, Why::Disabled))?;
                a.active()?;
                if r.operation == LAUNCH {
                    self.start_canary(c, route, r.intent, a)?;
                } else {
                    self.finish_canary(c, route, a)?;
                }
                let proof = self.launch.as_ref().ok_or(unknown(Why::Readback))?;
                out.native_id = proof.home.map_or(0, |h| h.id);
                out.flags = CG_VALID | MEMBERSHIP_VALID | PROBE_CLEAN_FLAGS;
                if r.operation == LAUNCH {
                    out.flags |= HEALTHY;
                }
                out.status = PASS;
                detail = if r.operation == LAUNCH {
                    Why::LaunchPassed
                } else {
                    Why::ProbeClosed
                };
                return Ok(());
            }
            if self.launch.as_ref().is_some_and(|p| !p.cleaned) {
                return Err(unknown(Why::RestoreFirst));
            }
            let lease = Lease::from(r)?;
            let requested = [r.frame.x, r.frame.y, r.frame.width, r.frame.height];
            if r.operation == READBACK {
                let (s, hidden) = self.read(c, lease, a)?;
                out.frame = Rect {
                    x: s.rect[0],
                    y: s.rect[1],
                    width: s.rect[2],
                    height: s.rect[3],
                };
                out.flags = AX_VALID
                    | CG_VALID
                    | MEMBERSHIP_VALID
                    | if hidden { HIDDEN | OWNED } else { VISIBLE };
                out.native_id = if hidden {
                    self.slots[&lease.slot].id
                } else {
                    lease.slot.home.id
                };
                out.status = PASS;
                return Ok(());
            }
            a.active()?;
            if r.operation == TRIAL && lease.window.pid != std::process::id() as i32 {
                return Err(fail(Why::TrialOwnWindow));
            }
            if r.operation != TRIAL && self.route.is_none() {
                return Err(Fault(UNSUPPORTED, Why::Disabled));
            }
            if let Some(saved) = self.owned.get(&lease.window) {
                if saved.lease != lease || (r.operation == HIDE && saved.original != requested) {
                    return Err(unknown(Why::Identity));
                }
            }
            if self.seen_intents.len() >= 65536 || !self.seen_intents.insert(r.intent) {
                return Err(fail(Why::Stale));
            }
            if r.operation == TRIAL {
                if self.failed {
                    return Err(unknown(Why::RestoreFirst));
                }
                let route = if r.flags & TRIAL_CLASSIC != 0 {
                    Route::Classic
                } else {
                    Route::Bridge
                };
                self.trial(c, lease, requested, route, a)?;
                detail = Why::TrialPassed;
                out.flags = HEALTHY | VISIBLE | AX_VALID | CG_VALID | MEMBERSHIP_VALID;
            } else {
                let route = self.route.ok_or(Fault(UNSUPPORTED, Why::Disabled))?;
                if self.failed && r.operation != RESTORE {
                    return Err(unknown(Why::RestoreFirst));
                }
                match r.operation {
                    HIDE | HIDE_MINIMIZED => {
                        if r.operation == HIDE_MINIMIZED { self.hide_minimized(c, lease, requested, route, a)?; }
                        else { self.hide(c, lease, requested, route, a)?; }
                        detail = Why::HideVerified;
                        out.flags = HIDDEN | OWNED;
                    }
                    SHOW | RESTORE => {
                        let remains_minimized = self.owned.get(&lease.window)
                            .map(|b| self.sys.minimized(&b.witness)).transpose()?.unwrap_or(false);
                        self.show(c, lease, route, a)?;
                        // An interrupted yellow-button adoption can return to its
                        // original Dock state. That is clean release, not visible-window success.
                        if remains_minimized { return Err(unknown(Why::MinimizedOrAX)); }
                        detail = Why::ShowVerified;
                        out.flags = VISIBLE;
                    }
                    _ => return Err(Fault(UNSUPPORTED, Why::Disabled)),
                }
                out.flags |= AX_VALID | CG_VALID | MEMBERSHIP_VALID;
            }
            out.native_id = if out.flags & HIDDEN != 0 {
                self.slots.get(&lease.slot).ok_or(unknown(Why::Unowned))?.id
            } else {
                lease.slot.home.id
            };
            out.status = PASS;
            Ok(())
        })();
        if let Err(Fault(s, d)) = res {
            if matches!(r.operation, HEALTH | HIDE | HIDE_MINIMIZED | SHOW)
                && (!self.owned.is_empty() || !self.slots.is_empty())
            {
                self.failed = true;
            }
            out.status = s;
            detail = d;
        }
        out.detail = detail as u32;
        out.owned = (self.owned.len()
            + self
                .slots
                .values()
                .filter(|s| !self.owned.values().any(|w| w.lease.slot == s.owner.slot))
                .count()) as u32;
        if self.launch.as_ref().is_some_and(|p| !p.cleaned) {
            out.owned = out.owned.saturating_add(1);
        }
        if out.owned > 0 {
            out.flags |= OWNED;
        }
        out
    }
}
pub struct Spaces(State<system::System>);
impl Spaces {
    pub fn candidate() -> Self {
        Self(State::new(system::System { candidate: true, ..Default::default() }))
    }
}
impl Default for Spaces {
    fn default() -> Self {
        Self(State::new(system::System::default()))
    }
}
impl WindowEngine for Spaces {
    fn execute(&mut self, r: &Request, c: &Control) -> Outcome {
        self.0.run(r, c)
    }
    fn tick(&mut self) {
        self.0.observe_health()
    }
}

#[cfg(test)]
mod tests;
