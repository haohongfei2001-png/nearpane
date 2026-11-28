// A selected route is initialized by its own one-shot AppKit probe.
// The own-window result is not evidence that third-party windows can be moved.
// The request names no user window. The retained canary and original inventory also govern recovery.
use super::*;

// Initial home discovery includes two main-queue AppKit/focus observations,
// each bounded to 300 ms by np_stage_launch_call, plus Space readback. It is
// not the 120 ms acknowledgement deadline for an already-issued Space move.
const HOME_DISCOVERY_BUDGET: Duration = Duration::from_millis(650);

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
    pub focus_read_error: i32,
}
impl Panel {
    fn focus_confirmed(self) -> bool {
        self.focus_same == 1 && self.focus_read_error == 0
    }
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
    initial: Vec<u64>,
    topology: Vec<Desktop>,
    pub home: Option<Home>,
    pub(super) opened_window: Option<Window>,
    pub(super) lease: Option<Lease>,
    frame: Option<[f64; 4]>,
    pub(super) parking: Option<u64>,
    pub(super) restored: bool,
    close_sent: bool,
    pub(super) closed: bool,
    pub cleaned: bool,
}
fn fixed(top: &[Desktop], current: &[Desktop]) -> bool {
    let mut before = top.to_vec();
    let mut after = current.to_vec();
    before.sort_by_key(|desktop| desktop.display);
    after.sort_by_key(|desktop| desktop.display);
    before == after
}
fn trace_result(phase: &str, result: &Check<()>, run: Option<&CanaryRun>) {
    if std::env::var_os("NP_SPACES_LAUNCH_TRACE").is_none() { return; }
    let (status, detail) = result.as_ref().map_or_else(|Fault(status, why)| (*status, *why as u32), |_| (PASS, Why::Ready as u32));
    eprintln!("{{\"event\":\"spacesLaunchEngine\",\"phase\":\"{phase}\",\"status\":{status},\"detail\":{detail},\"window\":{},\"home\":{},\"parking\":{}}}",
        run.and_then(|r| r.opened_window).map_or(0, |w| w.number),
        run.and_then(|r| r.home).map_or(0, |h| h.id),run.and_then(|r| r.parking).unwrap_or(0));
}
impl<P: Platform> State<P> {
    fn panel_home(&mut self, c: i32, window: Window, a: &impl Authority) -> Check<Home> {
        let started = self.sys.now();
        let deadline = started + HOME_DISCOVERY_BUDGET;
        let mut previous = None;
        let mut observed_home = None;
        let mut iteration = 0u32;
        let mut waited = Duration::ZERO;
        loop {
            iteration += 1;
            a.active()?;
            if self.sys.now() >= deadline {
                return Err(unknown(Why::Membership));
            }
            let panel_began = self.sys.now();
            let panel = self.sys.canary(PanelOp::Read, a)?;
            let panel_read = self.sys.now();
            // Only the platform's retained Finder desktop role-read gap can
            // wait. A changed object/owner or contradictory Boolean/error pair
            // is a refusal, including when another field is unavailable.
            let missing_role = panel.focus_same == 0 && panel.focus_read_error == -25204 &&
                panel.opened == 1 && panel.absent == 0;
            if panel.window() != Some(window) || panel.registered != 1 ||
                (!panel.focus_confirmed() && !missing_role) {
                return Err(unknown(Why::ProbeFocus));
            }
            if panel_read >= deadline {
                return Err(unknown(Why::Membership));
            }
            let baseline = self.launch.as_ref().ok_or(unknown(Why::Stale))?;
            if self.sys.connection()? != c || !fixed(&baseline.topology, &self.sys.desktops(c)?) {
                return Err(unknown(Why::Topology));
            }
            let ids = self.sys.spaces(c, window.number)?;
            if std::env::var_os("NP_SPACES_LAUNCH_TRACE").is_some() {
                eprintln!("{{\"event\":\"spacesLaunchHome\",\"phase\":\"membership\",\"window\":{},\"memberships\":{:?},\"currentOrdinary\":{:?}}}",
                    window.number,ids.iter().copied().collect::<Vec<_>>(),
                    baseline.topology.iter().filter(|d| d.kind==0 && d.current==1).map(|d| d.id).collect::<Vec<_>>());
            }
            if ids.len() > 1 {
                return Err(unknown(Why::Membership));
            }
            // On 26A428 orderFront can register a panel before its first WindowServer membership exists.
            let mut confirmed = None;
            let mut reverse_contains = None;
            if let Some(&id) = ids.first() {
                let mut matches = baseline
                    .topology
                    .iter()
                    .filter(|d| d.kind == 0 && d.current == 1 && d.id == id);
                let desktop = matches.next().ok_or(unknown(Why::Scope))?;
                if matches.next().is_some() || !baseline.initial.contains(&id) {
                    return Err(unknown(Why::Scope));
                }
                let contains = self.sys.members(c, id)?.contains(&u64::from(window.number));
                reverse_contains = Some(contains);
                if contains {
                    confirmed = Some(Home {
                        display: desktop.display,
                        uuid: desktop.uuid,
                        id,
                    });
                }
            }
            if let Some(home) = confirmed {
                if observed_home.is_some_and(|original| original != home) {
                    return Err(unknown(Why::Scope));
                }
                observed_home = Some(home);
            }
            // Even a complete membership read cannot fill a missing focus
            // observation. Keep checking positive topology/identity conflicts
            // above, then require two new complete samples after this gap.
            if missing_role { confirmed = None; }
            let now = self.sys.now();
            let expired = now >= deadline;
            if std::env::var_os("NP_SPACES_LAUNCH_TRACE").is_some() {
                eprintln!("{{\"event\":\"spacesLaunchHome\",\"phase\":\"sample\",\"window\":{},\"confirmedHome\":{},\"previousHome\":{},\"deadlineReached\":{},\"twoMatchingHomes\":{},\"iteration\":{},\"elapsedMS\":{},\"budgetMS\":{},\"waitMS\":{},\"panelReadMS\":{},\"systemReadMS\":{},\"reverseContains\":{},\"focusSame\":{},\"focusReadError\":{}}}",
                    window.number,confirmed.map_or(0,|h|h.id),previous.map_or(0,|h:Home|h.id),expired,
                    confirmed.is_some() && confirmed==previous,iteration,now.saturating_duration_since(started).as_millis(),
                    HOME_DISCOVERY_BUDGET.as_millis(),waited.as_millis(),panel_read.saturating_duration_since(panel_began).as_millis(),
                    now.saturating_duration_since(panel_read).as_millis(),
                    reverse_contains.map_or("null".to_owned(),|value|value.to_string()),
                    panel.focus_same,panel.focus_read_error);
            }
            if expired {
                return Err(unknown(Why::Membership));
            }
            if let (Some(_), Some(second)) = (previous, confirmed) {
                return Ok(second);
            }
            previous = confirmed;
            let wait_began = self.sys.now();
            self.sys.wait(Duration::from_millis(4));
            waited = self.sys.now().saturating_duration_since(wait_began);
        }
    }

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
        if before.absent != 1 || before.opened != 0 || !before.focus_confirmed() {
            return Err(unknown(Why::ProbeFocus));
        }
        self.launch = Some(CanaryRun {
            route,
            initial: all,
            topology: top,
            home: None,
            opened_window: None,
            lease: None,
            frame: None,
            parking: None,
            restored: false,
            close_sent: false,
            closed: false,
            cleaned: false,
        });
        let mut phase = "open";
        let action = (|| -> Check<()> {
            a.active()?;
            let p = self.sys.canary(PanelOp::Open, a)?;
            let window = p.window().ok_or(unknown(Why::Identity))?;
            if p.registered != 1 || !p.focus_confirmed() {
                return Err(unknown(Why::ProbeFocus));
            }
            self.launch.as_mut().unwrap().opened_window = Some(window);
            phase = "panel-home";
            let home = self.panel_home(c, window, a)?;
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
            phase = "bind";
            let w = self.sys.bind(window)?;
            if !self.sys.transparent_canary(&w) {
                return Err(fail(Why::TrialOwnWindow));
            }
            phase = "initial-visible-view";
            let original = self.view(c, lease, &w, 0, false)?;
            self.launch.as_mut().unwrap().frame = Some(original.rect);
            phase = "hide";
            let hidden = self.hide(c, lease, original.rect, route, a);
            let sid = self.slots.get(&lease.slot).map(|s| s.id);
            self.launch.as_mut().unwrap().parking = sid;
            hidden?;
            let sid = sid.ok_or(unknown(Why::Unowned))?;
            phase = "hidden-view";
            let read = self.view(c, lease, &w, sid, true)?;
            if read.rect != original.rect {
                return Err(unknown(Why::Identity));
            }
            Ok(())
        })();
        trace_result(phase, &action, self.launch.as_ref());
        // There is no route authority while cleanup is incomplete, even if a move returned success.
        let cleanup = self.finish_canary(c, route, a, true);
        trace_result("finish-canary", &cleanup, self.launch.as_ref());
        action?;
        cleanup?;
        if self.failed {
            return Err(unknown(Why::Health));
        }
        self.route = Some(route);
        Ok(())
    }
    pub(super) fn finish_canary(&mut self, c: i32, route: Route, a: &impl Authority, require_focus: bool) -> Check<()> {
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
                    .any(|p| p.opened != 0 || p.absent != 1 || (require_focus && !p.focus_confirmed()))
            {
                return Err(unknown(Why::Cleanup));
            }
            self.launch = Some(CanaryRun {
                route,
                initial: before,
                topology: top,
                home: None,
                opened_window: None,
                lease: None,
                frame: None,
                parking: None,
                restored: true,
                close_sent: false,
                closed: false,
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
            if require_focus && !p.focus_confirmed() {
                return Err(unknown(Why::ProbeFocus));
            }
            if let Some(lease) = lease {
                if p.window() != Some(lease.window) || p.registered != 1 {
                    if std::env::var_os("NP_SPACES_LAUNCH_TRACE").is_some() {
                        eprintln!("{{\"event\":\"spacesLaunchRestorePanel\",\"window\":{},\"observedWindow\":{},\"observedPID\":{},\"observedBirth\":{},\"registered\":{}}}",
                            lease.window.number,p.number,p.pid,p.birth,p.registered);
                    }
                    return Err(unknown(Why::Identity));
                }
                if self.owned.contains_key(&lease.window) || self.slots.contains_key(&lease.slot) {
                    let top = self.topology(c, lease.slot.home)?;
                    let result = self.restore_member(c, lease, route, &top, a);
                    trace_result("restore-member", &result, self.launch.as_ref());
                    result?;
                }
                let w = self.sys.bind(lease.window).inspect_err(|&fault| trace_fault("canary-rebind", lease, 0, fault))?;
                if !self.sys.transparent_canary(&w) {
                    return Err(fail(Why::TrialOwnWindow));
                }
                for _ in 0..2 {
                    let seen = self.view(c, lease, &w, 0, false).inspect_err(|&fault| trace_fault("canary-returned-view", lease, 0, fault))?;
                    if frame.is_some_and(|original| seen.rect != original) {
                        trace_geometry("canary-returned-frame", lease, Seen { rect: frame.unwrap(), ..seen }, seen);
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
        let end = self.sys.now() + DEADLINE;
        let mut streak = 0;
        let mut last_absence_fault = None;
        loop {
            a.observation()?;
            let run = self.launch.as_ref().unwrap();
            let p = self.sys.canary(PanelOp::Read, a)?;
            let number = lease.map_or(p.number, |l| l.window.number);
            if require_focus && !p.focus_confirmed() {
                return Err(unknown(Why::ProbeFocus));
            }
            if p.number != 0 && p.number != number {
                return Err(unknown(Why::Identity));
            }
            if !fixed(&run.topology, &self.sys.desktops(c)?) {
                return Err(unknown(Why::Topology));
            }
            let cg_absent = if p.registered == 0 && p.absent == 1 {
                match if number == 0 { Ok(true) } else { self.sys.absent(number) } {
                    Ok(absent) => {
                        last_absence_fault = None;
                        absent
                    }
                    Err(fault @ Fault(UNKNOWN, Why::Readback)) => {
                        // The CG description and on-screen list can disagree just
                        // after this one issued close. Unknown is not absence:
                        // retain the Space and observe within the original budget.
                        trace_result("close-cg-readback", &Err(fault), Some(run));
                        last_absence_fault = Some(fault);
                        false
                    }
                    Err(fault) => return Err(fault),
                }
            } else {
                false
            };
            if cg_absent {
                self.launch.as_mut().unwrap().closed = true;
                // Only reclaim the private Space after both AppKit and WindowServer
                // acknowledge the close. A pending close retains the slot for recovery.
                if let Some(l) = lease.filter(|l| self.slots.contains_key(&l.slot)) {
                    let top = self.topology(c, l.slot.home)?;
                    self.cleanup(c, l.slot, &top, a)?;
                }
                let run = self.launch.as_ref().unwrap();
                if self.sys.all(c)? == run.initial && self.slots.is_empty() && self.owned.is_empty()
                {
                    streak += 1;
                    if streak == 2 {
                        break;
                    }
                } else {
                    streak = 0;
                }
            } else {
                streak = 0;
            }
            if self.sys.now() >= end {
                return Err(last_absence_fault.unwrap_or(unknown(Why::Cleanup)));
            }
            self.sys.wait(Duration::from_millis(4));
        }
        self.launch.as_mut().unwrap().cleaned = true;
        Ok(())
    }
}
