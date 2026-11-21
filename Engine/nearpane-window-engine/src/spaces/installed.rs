//! A separate, one-use installed-Host experiment. There is deliberately no path
//! from this State, its isolated permit, or this receipt into the engine grant table.
use super::*;
use std::{
    ffi::c_void,
    ptr::NonNull,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
};

#[derive(Default)]
#[repr(C)]
struct Subject {
    pid: i32,
    window: u32,
    birth: u64,
}

#[derive(Default)]
#[repr(C)]
pub(super) struct Receipt {
    size: u32,
    version: u32,
    status: u32,
    detail: u32,
    phase: u32,
    admission: u32,
    refusal: u32,
    host_pid: u32,
    fixture_pid: u32,
    fixture_window: u32,
    canary_window: u32,
    fixture_birth: u64,
    home_id: u64,
    canary_space: u64,
    fixture_space: u64,
    before_proofs: u32,
    parked_proofs: u32,
    returned_proofs: u32,
    final_proofs: u32,
    canary_created: u32,
    canary_restored: u32,
    canary_closed: u32,
    canary_space_gone: u32,
    canary_creates: u32,
    canary_hides: u32,
    canary_shows: u32,
    canary_destroys: u32,
    fixture_creates: u32,
    fixture_hides: u32,
    fixture_shows: u32,
    fixture_destroys: u32,
    held_windows: u32,
    held_spaces: u32,
    outstanding_canary: u32,
    safe_to_rollback: u32,
    before_onscreen: u32,
    parked_onscreen: u32,
    returned_onscreen: u32,
    original_frame: [f64; 4],
}

unsafe extern "C" {
    fn np_stage_fixture_enroll(
        nonce: *const u8,
        panel_only: u32,
        subject: *mut Subject,
        bits: *mut u32,
        reason: *mut u32,
    ) -> *mut c_void;
    fn np_stage_fixture_guard(token: *mut c_void, committing: u32) -> u32;
    fn np_stage_fixture_home_ax(token: *mut c_void) -> i32;
    fn np_stage_fixture_same(token: *mut c_void, element: *mut c_void, frame: *const f64) -> i32;
    fn np_stage_fixture_first_journal(
        token: *mut c_void,
        top: *const Desktop,
        nt: usize,
        all: *const u64,
        na: usize,
        home: u64,
        frame: *const f64,
        members: usize,
    ) -> u32;
    fn np_stage_fixture_journal(
        token: *mut c_void,
        event: u32,
        external: u32,
        number: u32,
        space: u64,
        response: i32,
    ) -> u32;
    fn np_stage_fixture_finish_journal(token: *mut c_void, clean: u32) -> u32;
    fn np_stage_release(token: *mut c_void);
}

struct Enrollment {
    native: NonNull<c_void>,
    window: Window,
    deadline: Instant,
    refused: AtomicU32,
    external: AtomicBool,
    writes: [AtomicU32; 8],
}
// Objective-C enrollment is immutable after acquisition, holds its original AX object,
// and main-queue callbacks only sample it. Counters are atomic for those callbacks.
unsafe impl Send for Enrollment {}
unsafe impl Sync for Enrollment {}
impl Drop for Enrollment {
    fn drop(&mut self) {
        unsafe { np_stage_release(self.native.as_ptr()) }
    }
}
#[derive(Clone)]
pub(super) struct Guard(Arc<Enrollment>);
#[derive(Clone, Copy)]
pub(super) enum Write {
    Create = 0,
    Hide = 1,
    Show = 2,
    Destroy = 3,
}
impl Guard {
    fn enroll(nonce: &Id, panel_only: bool, receipt: &mut Receipt) -> Check<Self> {
        let mut subject = Subject::default();
        let ptr = unsafe {
            np_stage_fixture_enroll(
                nonce.as_ptr(),
                u32::from(panel_only),
                &mut subject,
                &mut receipt.admission,
                &mut receipt.refusal,
            )
        };
        let native = NonNull::new(ptr).ok_or_else(|| {
            if receipt.refusal == 18 {
                receipt.safe_to_rollback = 0;
            }
            Fault(UNSUPPORTED, Why::Identity)
        })?;
        receipt.fixture_pid = subject.pid as u32;
        receipt.fixture_window = subject.window;
        receipt.fixture_birth = subject.birth;
        Ok(Self(Arc::new(Enrollment {
            native,
            window: Window {
                pid: subject.pid,
                birth: subject.birth,
                number: subject.window,
            },
            deadline: Instant::now() + Duration::from_secs(12),
            refused: AtomicU32::new(0),
            external: AtomicBool::new(false),
            writes: Default::default(),
        })))
    }
    pub(super) fn window(&self) -> Window {
        self.0.window
    }
    pub(super) fn same_document(&self, object: *mut c_void, frame: &[f64; 4]) -> bool {
        unsafe { np_stage_fixture_same(self.0.native.as_ptr(), object, frame.as_ptr()) == 1 }
    }
    fn ledger_status(&self, reason: u32) -> Check<()> {
        if reason == 0 {
            return Ok(());
        }
        let _ = self
            .0
            .refused
            .compare_exchange(0, reason, Ordering::SeqCst, Ordering::SeqCst);
        Err(unknown(Why::RestoreFirst))
    }
    pub(super) fn record(&self, event: u32, number: u32, space: u64, response: i32) -> Check<()> {
        let why = unsafe {
            np_stage_fixture_journal(
                self.0.native.as_ptr(),
                event,
                self.0.external.load(Ordering::SeqCst) as u32,
                number,
                space,
                response,
            )
        };
        self.ledger_status(why)
    }
    pub(super) fn issued(&self, op: Write, number: u32, space: u64) -> Check<()> {
        self.active()?;
        let base = usize::from(self.0.external.load(Ordering::SeqCst)) * 4;
        let count = &self.0.writes[base + op as usize];
        if count.load(Ordering::SeqCst) != 0 {
            return Err(fail(Why::Conflict));
        }
        self.record(op as u32, number, space, 0)?;
        self.active()?;
        count
            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
            .map(|_| ())
            .map_err(|_| fail(Why::Conflict))
    }
    pub(super) fn move_issued(
        &self,
        canary: bool,
        mask: u32,
        number: u32,
        space: u64,
    ) -> Check<()> {
        if canary == self.0.external.load(Ordering::SeqCst) {
            return Err(fail(Why::Identity));
        }
        self.issued(
            if mask == 7 { Write::Hide } else { Write::Show },
            number,
            space,
        )
    }
    fn counts(&self, r: &mut Receipt) {
        let v = self.0.writes.each_ref().map(|c| c.load(Ordering::SeqCst));
        [
            r.canary_creates,
            r.canary_hides,
            r.canary_shows,
            r.canary_destroys,
            r.fixture_creates,
            r.fixture_hides,
            r.fixture_shows,
            r.fixture_destroys,
        ] = v;
        r.refusal = self.0.refused.load(Ordering::SeqCst);
    }
}
impl Guard {
    fn verify(&self, committing: bool) -> Check<()> {
        let earlier = self.0.refused.load(Ordering::SeqCst);
        if earlier != 0 {
            return Err(Fault(CANCELLED, Why::Stale));
        }
        let why = if Instant::now() >= self.0.deadline {
            13
        } else {
            unsafe { np_stage_fixture_guard(self.0.native.as_ptr(), u32::from(committing)) }
        };
        if why == 0 {
            Ok(())
        } else {
            let _ = self
                .0
                .refused
                .compare_exchange(0, why, Ordering::SeqCst, Ordering::SeqCst);
            Err(Fault(
                if why == 13 { TIMEOUT } else { CANCELLED },
                Why::Stale,
            ))
        }
    }
}
impl Authority for Guard {
    fn fixture_home_ax(&self) -> Check<()> {
        if unsafe { np_stage_fixture_home_ax(self.0.native.as_ptr()) } == 1 {
            Ok(())
        } else {
            Err(unknown(Why::MinimizedOrAX))
        }
    }
    fn observation(&self) -> Check<()> {
        self.verify(false)
    }
    fn active(&self) -> Check<()> {
        self.verify(true)
    }
    fn retained(&self) -> Option<PanelPermit> {
        Some(PanelPermit::Fixture(self.clone()))
    }
    fn fixture_journal_start(
        &self,
        top: &[Desktop],
        inventory: &[u64],
        home: u64,
        frame: Option<&[f64; 4]>,
        members: usize,
    ) -> Check<()> {
        self.active()?;
        self.ledger_status(unsafe {
            np_stage_fixture_first_journal(
                self.0.native.as_ptr(),
                top.as_ptr(),
                top.len(),
                inventory.as_ptr(),
                inventory.len(),
                home,
                frame.map_or(std::ptr::null(), |r| r.as_ptr()),
                members,
            )
        })
    }
    fn fixture_membership_receipt(&self, w: Window, space: u64, hidden: bool) -> Check<()> {
        self.record(12, w.number, space, i32::from(hidden))
    }
    fn fixture_recovered(&self, external: bool, window: u32, space: u64) -> Check<()> {
        self.record(if external { 14 } else { 13 }, window, space, 1)
    }
}

// All reads use the original enrolled AX object (independently compared in System::see)
// and the exact home/parking IDs. A single direction never establishes membership.
fn proof<P: Platform>(
    state: &State<P>,
    c: i32,
    lease: Lease,
    witness: &P::Witness,
    parking: u64,
    hidden: bool,
    expected: &Seen,
    top: &[Desktop],
    a: &impl Authority,
    count: &mut u32,
    onscreen: &mut u32,
) -> Check<()> {
    for _ in 0..2 {
        state.scope(c, lease.slot.home, top, a)?;
        if !hidden {
            a.fixture_home_ax()?;
        }
        let seen = state.view(c, lease, witness, parking, hidden)?;
        if seen.rect != expected.rect
            || (hidden && seen.visible)
            || (!hidden && seen.visible != expected.visible)
        {
            return Err(unknown(Why::Readback));
        }
        *onscreen = u32::from(seen.visible);
        *count += 1;
    }
    Ok(())
}

fn run_panel<P: Platform>(
    state: &mut State<P>,
    c: i32,
    nonce: Id,
    a: &impl Authority,
    r: &mut Receipt,
) -> Check<()> {
    r.phase = 3;
    r.safe_to_rollback = 0;
    let canary = state.start_canary(c, Route::Bridge, nonce, a);
    if let Some(probe) = &state.launch {
        r.canary_window = probe.lease.map_or(0, |l| l.window.number);
        r.canary_created = u32::from(r.canary_window != 0);
        r.canary_restored = u32::from(probe.restored && probe.lease.is_some());
        r.canary_closed = u32::from(probe.closed && r.canary_created == 1);
        r.canary_space = probe.parking.unwrap_or(0);
        r.canary_space_gone = u32::from(probe.cleaned && r.canary_space != 0);
    }
    canary
}

// This arm has no external Window or callback that could enable external writes.
fn panel_only<P: Platform>(
    state: &mut State<P>,
    nonce: Id,
    a: &impl Authority,
    r: &mut Receipt,
) -> Check<()> {
    let c = state.connect()?;
    let desktops = state.sys.desktops(c)?;
    let mut active = desktops.iter().filter(|d| d.current == 1);
    let d = active.next().ok_or(unknown(Why::Scope))?;
    if d.kind != 0 || active.next().is_some() {
        return Err(unknown(Why::Scope));
    }
    let home = Home {
        display: d.display,
        uuid: d.uuid,
        id: d.id,
    };
    let top = state.topology(c, home)?;
    let inventory = state.sys.all(c)?;
    let members = state.sys.members(c, home.id)?;
    if !inventory.contains(&home.id) {
        return Err(unknown(Why::Topology));
    }
    r.home_id = home.id;
    for _ in 0..2 {
        state.scope(c, home, &top, a)?;
        if state.sys.all(c)? != inventory || state.sys.members(c, home.id)? != members {
            return Err(unknown(Why::Topology));
        }
    }
    a.fixture_journal_start(&top, &inventory, home.id, None, members.len())?;
    let result = run_panel(state, c, nonce, a, r);
    if state.launch.as_ref().is_some_and(|probe| probe.cleaned)
        && state.owned.is_empty()
        && state.slots.is_empty()
    {
        for _ in 0..2 {
            state.scope(c, home, &top, a)?;
            if state.sys.all(c)? != inventory || state.sys.members(c, home.id)? != members {
                return Err(unknown(Why::Cleanup));
            }
            r.final_proofs += 1;
        }
        r.safe_to_rollback = 1;
    }
    result?;
    if r.safe_to_rollback != 1 || r.canary_closed != 1 || r.canary_space_gone != 1 {
        return Err(unknown(Why::Cleanup));
    }
    a.fixture_recovered(false, r.canary_window, r.canary_space)?;
    r.phase = 6;
    Ok(())
}

fn cycle<P: Platform>(
    state: &mut State<P>,
    nonce: Id,
    window: Window,
    a: &impl Authority,
    enter_external: impl FnOnce(),
    r: &mut Receipt,
) -> Check<()> {
    if window.pid <= 1
        || window.pid == std::process::id() as i32
        || window.birth == 0
        || window.number == 0
    {
        return Err(fail(Why::Identity));
    }
    let c = state.connect()?;
    let homes = state.sys.spaces(c, window.number)?;
    if homes.len() != 1 {
        return Err(unknown(Why::Membership));
    }
    let home_id = *homes.first().unwrap();
    let desktops = state.sys.desktops(c)?;
    let candidates: Vec<_> = desktops
        .iter()
        .filter(|d| d.kind == 0 && d.current == 1 && d.id == home_id)
        .collect();
    if candidates.len() != 1 {
        return Err(unknown(Why::Scope));
    }
    let home = Home {
        display: candidates[0].display,
        uuid: candidates[0].uuid,
        id: home_id,
    };
    let lease = Lease {
        window,
        slot: Slot { home, group: nonce },
        member: nonce,
        lifetime: nonce,
        generation: nonce,
    };
    let top = state.topology(c, home)?;
    let inventory = state.sys.all(c)?;
    if !inventory.contains(&home_id) {
        return Err(unknown(Why::Topology));
    }
    let witness = state.sys.bind(window)?;
    let before = state.view(c, lease, &witness, 0, false)?;
    let original_members = state.sys.members(c, home_id)?;
    if !original_members.contains(&u64::from(window.number)) {
        return Err(unknown(Why::Membership));
    }
    r.home_id = home_id;
    r.original_frame = before.rect;
    r.phase = 2;
    proof(
        state,
        c,
        lease,
        &witness,
        0,
        false,
        &before,
        &top,
        a,
        &mut r.before_proofs,
        &mut r.before_onscreen,
    )?;
    if state.sys.members(c, home_id)? != original_members {
        return Err(unknown(Why::Membership));
    }
    a.fixture_journal_start(
        &top,
        &inventory,
        home_id,
        Some(&before.rect),
        original_members.len(),
    )?;
    let canary = run_panel(state, c, nonce, a, r);
    if let Err(fault) = canary {
        if state.launch.as_ref().is_some_and(|p| p.cleaned)
            && state.owned.is_empty()
            && state.slots.is_empty()
        {
            for _ in 0..2 {
                state.scope(c, home, &top, a)?;
                a.fixture_home_ax()?;
                let observed = state.view(c, lease, &witness, 0, false)?;
                if observed.rect != before.rect
                    || observed.visible != before.visible
                    || state.sys.all(c)? != inventory
                    || state.sys.members(c, home_id)? != original_members
                {
                    return Err(fault);
                }
                r.final_proofs += 1;
            }
            r.safe_to_rollback = 1;
        }
        return Err(fault);
    }
    if state.route != Some(Route::Bridge)
        || r.canary_window == window.number
        || r.canary_closed != 1
        || r.canary_space_gone != 1
        || state.sys.all(c)? != inventory
        || state.sys.members(c, home_id)? != original_members
        || !state.owned.is_empty()
        || !state.slots.is_empty()
    {
        return Err(unknown(Why::RestoreFirst));
    }
    a.fixture_recovered(false, r.canary_window, r.canary_space)?;
    // Re-enroll the original fixture witness in place after the Host-only cycle.
    let mut reads = 0;
    let mut on = 2;
    proof(
        state, c, lease, &witness, 0, false, &before, &top, a, &mut reads, &mut on,
    )?;
    enter_external();
    r.phase = 4;
    let parked = (|| {
        let result = state.hide(c, lease, before.rect, Route::Bridge, a);
        r.fixture_space = state.slots.get(&lease.slot).map_or(0, |p| p.id);
        result?;
        if r.fixture_space == 0 || inventory.contains(&r.fixture_space) {
            return Err(unknown(Why::Unowned));
        }
        proof(
            state,
            c,
            lease,
            &witness,
            r.fixture_space,
            true,
            &before,
            &top,
            a,
            &mut r.parked_proofs,
            &mut r.parked_onscreen,
        )?;
        let mut parked_members = original_members.clone();
        parked_members.remove(&u64::from(window.number));
        if state.sys.members(c, home_id)? != parked_members {
            return Err(unknown(Why::Membership));
        }
        Ok(())
    })();
    // Exactly one return/cleanup attempt. State::show checks actual ownership and both
    // endpoints first; a rejected or uncertain move is never issued a second time.
    r.phase = 5;
    let recovered = if state.owned.contains_key(&window) || state.slots.contains_key(&lease.slot) {
        state.show(c, lease, Route::Bridge, a)
    } else {
        Ok(())
    };
    let final_state = (|| {
        recovered?;
        proof(
            state,
            c,
            lease,
            &witness,
            0,
            false,
            &before,
            &top,
            a,
            &mut r.returned_proofs,
            &mut r.returned_onscreen,
        )?;
        for _ in 0..2 {
            state.scope(c, home, &top, a)?;
            if !state.owned.is_empty()
                || !state.slots.is_empty()
                || state.sys.all(c)? != inventory
                || state.sys.members(c, home_id)? != original_members
            {
                return Err(unknown(Why::Cleanup));
            }
            r.final_proofs += 1;
        }
        a.fixture_recovered(true, window.number, r.fixture_space)?;
        r.safe_to_rollback = 1;
        Ok(())
    })();
    parked?;
    final_state?;
    r.phase = 6;
    Ok(())
}

// Preserve the exact retained ObjC and Rust owner until Host exit if reconciliation
// cannot prove a safe end. No equal/alternate nonce or backend can take over.
static RESIDUE: Mutex<Option<State<system::System>>> = Mutex::new(None);
static BUSY: Mutex<()> = Mutex::new(());
fn run_once(nonce: Id, own_panel_only: bool, r: &mut Receipt) -> Check<()> {
    let _serial = BUSY.try_lock().map_err(|_| {
        r.safe_to_rollback = 0;
        r.refusal = 12;
        fail(Why::Conflict)
    })?;
    let mut residue = RESIDUE.lock().map_err(|_| {
        r.safe_to_rollback = 0;
        r.refusal = 12;
        unknown(Why::Uncertain)
    })?;
    if residue.is_some() {
        r.safe_to_rollback = 0;
        r.refusal = 12;
        return Err(unknown(Why::RestoreFirst));
    }
    let guard = Guard::enroll(&nonce, own_panel_only, r)?;
    let mut system = system::System::default();
    system.fixture = Some(guard.clone());
    let mut state = State::new(system);
    let result = if own_panel_only {
        panel_only(&mut state, nonce, &guard, r)
    } else {
        cycle(
            &mut state,
            nonce,
            guard.window(),
            &guard,
            || guard.0.external.store(true, Ordering::SeqCst),
            r,
        )
    };
    guard.counts(r);
    r.held_windows = state.owned.len() as u32;
    r.held_spaces = state.slots.len() as u32;
    r.outstanding_canary = u32::from(state.launch.as_ref().is_some_and(|p| !p.cleaned));
    let no_resource = r.held_spaces == 0 && r.held_windows == 0 && r.outstanding_canary == 0;
    if !no_resource
        || (r.fixture_creates != 0 && r.final_proofs != 2)
        || (state.failed && r.fixture_creates != 0 && r.fixture_space == 0)
    {
        r.safe_to_rollback = 0;
    } else if r.canary_creates == 0 && r.fixture_creates == 0 && r.outstanding_canary == 0 {
        r.safe_to_rollback = 1;
    }
    if matches!(r.refusal, 18 | 19) {
        r.safe_to_rollback = 0;
    }
    let closing = guard.ledger_status(unsafe {
        np_stage_fixture_finish_journal(guard.0.native.as_ptr(), r.safe_to_rollback)
    });
    if closing.is_err() {
        r.safe_to_rollback = 0;
        guard.counts(r);
    }
    if r.safe_to_rollback == 0 {
        *residue = Some(state);
    }
    result.and(closing)
}

#[unsafe(no_mangle)]
pub(super) unsafe extern "C" fn np_spaces_installed_fixture_cycle(
    nonce: *const u8,
    out: *mut Receipt,
) -> i32 {
    unsafe { installed_cycle(nonce, out, false) }
}
#[unsafe(no_mangle)]
pub(super) unsafe extern "C" fn np_spaces_installed_canary(
    nonce: *const u8,
    out: *mut Receipt,
) -> i32 {
    unsafe { installed_cycle(nonce, out, true) }
}
unsafe fn installed_cycle(nonce: *const u8, out: *mut Receipt, own_panel_only: bool) -> i32 {
    if nonce.is_null() || out.is_null() {
        return -1;
    }
    let r = unsafe { &mut *out };
    if r.size != size_of::<Receipt>() as u32 || r.version != 1 {
        return -1;
    }
    let mut id = [0u8; 16];
    unsafe {
        std::ptr::copy_nonoverlapping(nonce, id.as_mut_ptr(), 16);
    }
    *r = Receipt {
        size: size_of::<Receipt>() as u32,
        version: 1,
        status: UNKNOWN,
        phase: 1,
        host_pid: std::process::id(),
        safe_to_rollback: 1,
        before_onscreen: 2,
        parked_onscreen: 2,
        returned_onscreen: 2,
        ..Receipt::default()
    };
    if id == [0; 16] {
        r.refusal = 5;
        return 0;
    }
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        run_once(id, own_panel_only, r)
    })) {
        Ok(Ok(())) => {
            r.status = PASS;
            r.detail = Why::TrialPassed as u32;
        }
        Ok(Err(Fault(status, why))) => {
            r.status = status;
            r.detail = why as u32;
        }
        Err(_) => {
            r.safe_to_rollback = 0;
            r.refusal = 17;
        }
    }
    0
}

#[cfg(test)]
pub(super) fn replay_panel<P: Platform>(
    state: &mut State<P>,
    guard: &impl Authority,
) -> (u32, u32, u32) {
    let mut r = Receipt::default();
    let result = panel_only(state, [42; 16], guard, &mut r);
    (
        result.map_or_else(|fault| fault.0, |_| PASS),
        r.final_proofs,
        r.safe_to_rollback,
    )
}

#[cfg(test)]
pub(super) fn replay<P: Platform>(
    state: &mut State<P>,
    subject: Window,
    guard: &impl Authority,
    entering: impl FnOnce(),
) -> (u32, [u32; 8]) {
    let mut r = Receipt::default();
    let result = cycle(state, [42; 16], subject, guard, entering, &mut r);
    (
        result.map_or_else(|err| err.0, |_| PASS),
        [
            r.before_proofs,
            r.parked_proofs,
            r.returned_proofs,
            r.final_proofs,
            r.canary_closed,
            r.canary_space_gone,
            r.safe_to_rollback,
            r.canary_window,
        ],
    )
}

#[cfg(test)]
mod admission_tests {
    use super::*;
    #[test]
    fn test_executable_cannot_act_as_installed_host_and_invalid_challenge_is_refused() {
        for (nonce, reason) in [([0; 16], 5), ([1; 16], 1)] {
            let mut row = Receipt {
                size: size_of::<Receipt>() as u32,
                version: 1,
                ..Default::default()
            };
            for probe in [
                np_spaces_installed_fixture_cycle,
                np_spaces_installed_canary,
            ] {
                assert_eq!(unsafe { probe(nonce.as_ptr(), &mut row) }, 0);
                assert_ne!(row.status, PASS);
                assert_eq!(row.refusal, reason);
                assert_eq!(
                    (
                        row.canary_creates,
                        row.fixture_creates,
                        row.fixture_hides,
                        row.fixture_shows
                    ),
                    (0, 0, 0, 0)
                );
                assert_eq!(row.safe_to_rollback, 1);
            }
        }
    }
    #[test]
    fn wrong_abi_returns_before_platform_work() {
        let mut row = Receipt::default();
        assert_eq!(
            unsafe { np_spaces_installed_fixture_cycle([3; 16].as_ptr(), &mut row) },
            -1
        );
        assert_eq!(
            (row.admission, row.held_windows, row.held_spaces),
            (0, 0, 0)
        );
    }
}
