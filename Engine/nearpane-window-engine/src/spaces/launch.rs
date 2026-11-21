// An approved physical evidence route can be armed only by its own one-shot AppKit probe.
// The request names no user window. The retained canary and original inventory also govern recovery.
use super::*;

#[derive(Clone, Copy, Eq, PartialEq)]
#[repr(u32)]
pub(super) enum PanelOp {
    Prepare = 0,
    Open = 1,
    Read = 2,
    Close = 3,
}
#[derive(Copy, Clone, Default)]
#[repr(C)]
pub(super) struct Panel {
    pub number: u32,
    pub pid: i32,
    pub birth: u64,
    pub opened: u32,
    pub registered: u32,
    pub absent: u32,
    pub focus_same: u32,
    pub close_issued: u32,
}
impl Panel {
    pub fn window(self) -> Option<Window> {
        (self.number > 0 && self.birth > 0 && self.pid == std::process::id() as i32).then_some(
            Window {
                number: self.number,
                pid: self.pid,
                birth: self.birth,
            },
        )
    }
}
pub(super) struct CanaryRun {
    route: Route,
    initial: Rows,
    topology: Vec<Desktop>,
    pub home: Option<Home>,
    pub(super) lease: Option<Lease>,
    frame: Option<[f64; 4]>,
    pub(super) parking: Option<u64>,
    pub(super) restored: bool,
    close_sent: bool,
    pub cleaned: bool,
}
fn fixed(top: &[Desktop], current: &[Desktop]) -> bool {
    let mut before = top.to_vec();
    let mut after = current.to_vec();
    before.sort();
    after.sort();
    before == after
}
impl<P: Platform> State<P> {
    pub(super) fn start_canary(
        &mut self,
        c: i32,
        route: Route,
        intent: Id,
        a: &impl Authority,
    ) -> Check<()> {
        a.active()?;
        if self.launch.is_some()
            || self.route.is_some()
            || self.failed
            || !self.owned.is_empty()
            || !self.slots.is_empty()
        {
            return Err(fail(Why::Stale));
        }
        if self.sys.flags() & (if route == Route::Classic { 2 } else { 4 }) == 0 {
            return Err(Fault(UNSUPPORTED, Why::Symbols));
        }
        let top = self.sys.desktops(c)?;
        let all = self.sys.all(c)?;
        if top.is_empty() || all.is_empty() {
            return Err(unknown(Why::Topology));
        }
        let before = self.sys.canary(PanelOp::Prepare, a)?;
        if before.absent != 1 || before.opened != 0 || before.focus_same != 1 {
            return Err(unknown(Why::ProbeFocus));
        }
        self.launch = Some(CanaryRun {
            route,
            initial: all,
            topology: top,
            home: None,
            lease: None,
            frame: None,
            parking: None,
            restored: false,
            close_sent: false,
            cleaned: false,
        });
        let action = (|| -> Check<()> {
            a.active()?;
            let p = self.sys.canary(PanelOp::Open, a)?;
            let window = p.window().ok_or(unknown(Why::Identity))?;
            if p.registered != 1 || p.focus_same != 1 {
                return Err(unknown(Why::ProbeFocus));
            }
            let native = self.sys.spaces(c, window.number)?;
            if native.len() != 1 {
                return Err(unknown(Why::Membership));
            }
            let native_id = *native.first().unwrap();
            let state = self.launch.as_ref().unwrap();
            let matching: Vec<_> = state
                .topology
                .iter()
                .filter(|d| d.kind == 0 && d.current == 1 && d.id == native_id)
                .collect();
            if matching.len() != 1 || !state.initial.contains(&native_id) {
                return Err(unknown(Why::Scope));
            }
            let d = matching[0];
            let home = Home {
                display: d.display,
                uuid: d.uuid,
                id: d.id,
            };
            let lease = Lease {
                window,
                slot: Slot {
                    home,
                    group: intent,
                },
                member: intent,
                lifetime: intent,
                generation: intent,
            };
            self.launch.as_mut().unwrap().home = Some(home);
            self.launch.as_mut().unwrap().lease = Some(lease);
            let w = self.sys.bind(window)?;
            if !self.sys.transparent_canary(&w) {
                return Err(fail(Why::TrialOwnWindow));
            }
            let original = self.view(c, lease, &w, 0, false)?;
            self.launch.as_mut().unwrap().frame = Some(original.rect);
            let hidden = self.hide(c, lease, original.rect, route, a);
            let sid = self.slots.get(&lease.slot).map(|s| s.id);
            self.launch.as_mut().unwrap().parking = sid;
            hidden?;
            let sid = sid.ok_or(unknown(Why::Unowned))?;
            let read = self.view(c, lease, &w, sid, true)?;
            if read.rect != original.rect {
                return Err(unknown(Why::Identity));
            }
            Ok(())
        })();
        // There is no route authority while cleanup is incomplete, even if a move returned success.
        let cleanup = self.finish_canary(c, route, a);
        action?;
        cleanup?;
        if self.failed {
            return Err(unknown(Why::Health));
        }
        self.route = Some(route);
        Ok(())
    }
    pub(super) fn finish_canary(&mut self, c: i32, route: Route, a: &impl Authority) -> Check<()> {
        a.active()?;
        let Some(run) = self.launch.as_ref() else {
            // The worker never acquired a panel or created a Space. Independently bound
            // empty AppKit registry, membership inventory and unchanged focus must still agree.
            if self.route.is_some() || !self.owned.is_empty() || !self.slots.is_empty() {
                return Err(fail(Why::Conflict));
            }
            let before = self.sys.all(c)?;
            let top = self.sys.desktops(c)?;
            let panel = self.sys.canary(PanelOp::Prepare, a)?;
            let after = self.sys.canary(PanelOp::Read, a)?;
            if before.is_empty()
                || self.sys.all(c)? != before
                || !fixed(&top, &self.sys.desktops(c)?)
                || [panel, after]
                    .iter()
                    .any(|p| p.opened != 0 || p.absent != 1 || p.focus_same != 1)
            {
                return Err(unknown(Why::Cleanup));
            }
            self.launch = Some(CanaryRun {
                route,
                initial: before,
                topology: top,
                home: None,
                lease: None,
                frame: None,
                parking: None,
                restored: true,
                close_sent: false,
                cleaned: true,
            });
            return Ok(());
        };
        if run.route != route
            || self.sys.connection()? != c
            || !fixed(&run.topology, &self.sys.desktops(c)?)
        {
            return Err(unknown(Why::Topology));
        }
        let (lease, frame) = (run.lease, run.frame);
        if !run.restored {
            let p = self.sys.canary(PanelOp::Read, a)?;
            if p.focus_same != 1 {
                return Err(unknown(Why::ProbeFocus));
            }
            if let Some(lease) = lease {
                if p.window() != Some(lease.window) || p.registered != 1 {
                    return Err(unknown(Why::Identity));
                }
                if self.owned.contains_key(&lease.window) {
                    self.show(c, lease, route, a)?;
                } else if self.slots.contains_key(&lease.slot) {
                    let top = self.topology(c, lease.slot.home)?;
                    self.cleanup(c, lease.slot, &top, a)?;
                }
                let w = self.sys.bind(lease.window)?;
                if !self.sys.transparent_canary(&w) {
                    return Err(fail(Why::TrialOwnWindow));
                }
                for _ in 0..2 {
                    let seen = self.view(c, lease, &w, 0, false)?;
                    if frame.is_some_and(|original| seen.rect != original) {
                        return Err(unknown(Why::Identity));
                    }
                }
            } else if !self.owned.is_empty() || !self.slots.is_empty() {
                return Err(unknown(Why::RestoreFirst));
            }
            self.launch.as_mut().unwrap().restored = true;
        }
        let pending = self.launch.as_ref().unwrap();
        let before_close = self.sys.canary(PanelOp::Read, a)?;
        // A serialized main-thread read can prove an earlier queued callback expired
        // before it called close. An issued close is only observed, never resent.
        if before_close.absent != 1 && (!pending.close_sent || before_close.close_issued == 0) {
            a.active()?;
            self.launch.as_mut().unwrap().close_sent = true;
            self.sys.canary(PanelOp::Close, a)?;
        }
        // A close is never reissued. Recheck the original Space set and independently
        // prove the exact AppKit window and its CG number both disappeared.
        let end = Instant::now() + DEADLINE;
        let mut streak = 0;
        loop {
            a.observation()?;
            let run = self.launch.as_ref().unwrap();
            let p = self.sys.canary(PanelOp::Read, a)?;
            let absent = p.number == 0 || self.sys.absent(p.number)?;
            let top = self.sys.desktops(c)?;
            if p.focus_same == 1
                && p.registered == 0
                && p.absent == 1
                && absent
                && {
                    let current = self.sys.all(c)?;
                    current == run.initial && run.parking.is_none_or(|id| !current.contains(&id))
                }
                && fixed(&run.topology, &top)
                && self.slots.is_empty()
                && self.owned.is_empty()
            {
                streak += 1;
                if streak == 2 {
                    break;
                }
            } else {
                streak = 0;
            }
            if Instant::now() >= end {
                return Err(unknown(Why::Cleanup));
            }
            std::thread::sleep(Duration::from_millis(4));
        }
        self.launch.as_mut().unwrap().cleaned = true;
        Ok(())
    }
}
