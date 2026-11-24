use crate::contract::*;
use std::{
    collections::{HashMap, HashSet},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

pub const OK: u32 = 0;
pub const INVALID: u32 = 1;
pub const INCOMPATIBLE: u32 = 2;
pub const CLOSED: u32 = 3;
pub const BUSY: u32 = 4;
pub const PENDING: u32 = 5;
pub const NO_TICKET: u32 = 6;
pub const INTERNAL: u32 = 7;
const LIMIT: usize = 32;
const ACQUISITION_EPOCH: u64 = 1;
const CORNER_READBACK_GRACE: Duration = Duration::from_millis(500);
const INTERRUPTED_CORNER_PARK: u32 = 51;

fn qualified_write(grant: Option<crate::Grant>, r: &Request) -> bool {
    if r.backend != CORNER || !grant.is_some_and(|g| g.backend == CORNER) {
        return false;
    }
    match r.operation {
        HIDE | SHOW => r.epoch == ACQUISITION_EPOCH,
        RESTORE => true,
        _ => false,
    }
}
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
pub fn next(id: &AtomicU64) -> Result<u64, u32> {
    id.fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| v.checked_add(1))
        .map_err(|_| INTERNAL)
}
#[cfg(all(target_os = "macos", feature = "isolated-fixtures"))]
unsafe extern "C" {
    fn np_is_enrolled_fixture(pid: i32, birth: u64) -> bool;
}
fn trusted(_p: Process) -> bool {
    #[cfg(all(target_os = "macos", feature = "isolated-fixtures"))]
    {
        return unsafe { np_is_enrolled_fixture(_p.pid, _p.birth) };
    }
    #[allow(unreachable_code)]
    false
}
impl Config {
    pub fn valid(&self) -> bool {
        if self.mode == 0 {
            return self.process_count == 0 && self.processes == [Process::default(); 2];
        }
        if self.mode != 1
            || !cfg!(feature = "isolated-fixtures")
            || !(1..=2).contains(&self.process_count)
        {
            return false;
        }
        let (enrolled, unused) = self.processes.split_at(self.process_count as usize);
        enrolled
            .iter()
            .all(|p| p.pid > 0 && p.birth > 0 && p.reserved == 0 && trusted(*p))
            && (enrolled.len() != 2 || enrolled[0].pid != enrolled[1].pid)
            && unused.iter().all(|p| *p == Process::default())
    }
    fn allows(&self, r: &Request) -> bool {
        // There is no approved physical-build qualification in this revision.
        self.mode == 1
            && self.processes[..self.process_count as usize]
                .iter()
                .any(|p| p.pid == r.pid && p.birth == r.birth && trusted(*p))
    }
}
struct Ticket {
    cancelled: Arc<AtomicBool>,
    result: Option<Receipt>,
    request: Request,
    began: Instant,
    may_have_dispatched: bool,
    readback_until: Option<Instant>,
}
#[derive(Hash, Eq, PartialEq)]
struct Lease {
    backend: u32,
    group: [u8; 16],
    generation: [u8; 16],
    member: [u8; 16],
    lifetime: [u8; 16],
    display: [u8; 16],
    native_space: [u8; 16],
    native_id: u64,
    pid: i32,
    birth: u64,
    window: u32,
}
impl From<&Request> for Lease {
    fn from(r: &Request) -> Self {
        Self {
            backend: r.backend,
            group: r.group,
            generation: r.generation,
            member: r.member,
            lifetime: r.lifetime,
            display: r.display,
            native_space: r.native_space,
            native_id: r.native_id,
            pid: r.pid,
            birth: r.birth,
            window: r.window,
        }
    }
}
#[derive(Default)]
struct State {
    tickets: HashMap<u64, Ticket>,
    // Qualified Corner only. An accepted or withdrawn HIDE stays spent even after its ticket is polled.
    corner_hides: Option<HashSet<[u8; 16]>>,
    owner: Option<u32>,
    unresolved: HashSet<Lease>,
    health_lost: bool,
    running: Option<u64>,
    closed: bool,
}
impl State {
    fn unused_hide(&mut self, intent: [u8; 16]) -> Result<(), u32> {
        let spent = self.corner_hides.as_mut().ok_or(INCOMPATIBLE)?;
        if spent.contains(&intent) {
            return Err(BUSY);
        }
        spent.try_reserve(1).map_err(|_| BUSY)
    }
    fn can_run_probe(&self, r: &Request) -> bool {
        match r.operation {
            LAUNCH => self.owner.is_none(),
            RESTORE if r.epoch != ACQUISITION_EPOCH => self.owner == Some(r.backend),
            // The backend also proves the no-panel/no-space case following a pre-dispatch denial.
            CLEAN_LAUNCH => self.owner.is_none() || self.unresolved.contains(&Lease::from(r)),
            _ => true,
        }
    }
    fn record_write(&mut self, request: &Request, mut result: Outcome) -> Outcome {
        let lease = Lease::from(request);
        let restoring = matches!(request.operation, RESTORE | SHOW);
        let visible = VISIBLE | AX_VALID | CG_VALID | MEMBERSHIP_VALID;
        if restoring
            && result.status == PASS
            && (request.native_id == 0
                || result.native_id != request.native_id
                || result.flags & (visible | HIDDEN | OWNED) != visible)
        {
            result.status = UNKNOWN;
        }
        let canary = matches!(request.operation, LAUNCH | CLEAN_LAUNCH);
        if canary
            && result.status == PASS
            && result.owned == 0
            && result.flags & (PROBE_CLEAN_FLAGS | MEMBERSHIP_VALID | OWNED | HIDDEN)
                == PROBE_CLEAN_FLAGS | MEMBERSHIP_VALID
        {
            self.unresolved.remove(&lease);
            // Canary cleanup never releases another window's owner or its unknown leases.
            if request.operation == CLEAN_LAUNCH && self.unresolved.is_empty() {
                self.owner = None;
                self.health_lost = false;
            }
            return result;
        }
        if result.owned > 0 || result.flags & OWNED != 0 || result.status == UNKNOWN {
            self.owner = Some(request.backend);
        }
        if result.status == UNKNOWN || (canary && (result.owned != 0 || result.flags & OWNED != 0))
        {
            self.unresolved.insert(lease);
            return result;
        }
        if restoring && result.status == PASS {
            self.unresolved.remove(&lease);
            if result.owned == 0 && self.unresolved.is_empty() {
                self.owner = None;
                self.health_lost = false;
            }
        }
        result
    }
    fn finish_job(
        &mut self,
        id: u64,
        r: Request,
        control: &Control,
        may_enter: bool,
        mut result: Outcome,
        elapsed: Duration,
    ) {
        self.running = None;
        // Poll can already have consumed a timeout or a revoked ticket. Serialize the final
        // epoch/deadline check with that terminal publication and the ownership update.
        let interrupted = control.guard().err();
        let lost_guardian = may_enter && control.guardian.as_ref().is_some_and(|peer| !peer.live());
        if interrupted.is_some() || lost_guardian {
            if may_enter && r.backend == CORNER && r.operation == HIDE {
                let reason = if result.detail == 0 { INTERRUPTED_CORNER_PARK } else { result.detail };
                result = result.only_for_corner_recovery(r.native_id, reason);
            } else {
                result.status = if may_enter { UNKNOWN } else { interrupted.unwrap_or(UNKNOWN) };
            }
        }
        if may_enter {
            result = self.record_write(&r, result);
        }
        if let Some(t) = self.tickets.get_mut(&id) {
            t.result = Some(terminal(r, result, elapsed));
        }
    }
}
struct Job {
    id: u64,
    r: Request,
    began: Instant,
    cancelled: Arc<AtomicBool>,
    guardian: Option<Arc<GuardianPeer>>,
}
pub struct Session {
    tx: mpsc::SyncSender<Job>,
    state: Arc<Mutex<State>>,
    pub epoch: Arc<AtomicU64>,
    sequence: AtomicU64,
}
struct Backends {
    #[cfg(feature = "corner")]
    corner: crate::corner::Corner,
    #[cfg(feature = "spaces")]
    spaces: crate::spaces::Spaces,
}
impl Backends {
    fn new() -> Self {
        Self {
            #[cfg(feature = "corner")]
            corner: Default::default(),
            #[cfg(feature = "spaces")]
            spaces: Default::default(),
        }
    }
    fn get(&mut self, backend: u32) -> Option<&mut dyn WindowEngine> {
        match backend {
            #[cfg(feature = "corner")]
            CORNER => Some(&mut self.corner),
            #[cfg(feature = "spaces")]
            SPACES => Some(&mut self.spaces),
            _ => None,
        }
    }
}
#[cfg(target_os = "macos")]
fn pump_run_loop() {
    use std::ffi::c_void;
    unsafe extern "C" {
        static kCFRunLoopDefaultMode: *const c_void;
        fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, once: u8) -> i32;
    }
    unsafe {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, 1);
    }
}
#[cfg(not(target_os = "macos"))]
fn pump_run_loop() {}
impl Session {
    pub(super) fn create(config: Config, qualified: Option<crate::Grant>) -> Result<Self, u32> {
        let state = Arc::new(Mutex::new(State {
            corner_hides: qualified
                .filter(|g| g.backend == CORNER)
                .map(|_| HashSet::new()),
            ..Default::default()
        }));
        let epoch = Arc::new(AtomicU64::new(ACQUISITION_EPOCH));
        let (tx, rx) = mpsc::sync_channel(LIMIT);
        let shared = state.clone();
        let live_epoch = epoch.clone();
        thread::Builder::new()
            .name("Nearpane.WindowEngine".into())
            .spawn(move || {
                let mut backends = Backends::new();
                loop {
                    let owner = lock(&shared).owner;
                    let job = if let Some(owner) = owner {
                        pump_run_loop();
                        if let Some(b) = backends.get(owner) {
                            if catch_unwind(AssertUnwindSafe(|| b.tick())).is_err() {
                                lock(&shared).health_lost = true;
                            }
                        }
                        match rx.recv_timeout(Duration::from_millis(32)) {
                            Ok(job) => job,
                            Err(mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(_) => break,
                        }
                    } else {
                        match rx.recv() {
                            Ok(job) => job,
                            Err(_) => break,
                        }
                    };
                    process(&config, qualified, &shared, &live_epoch, &mut backends, job);
                }
            })
            .map_err(|_| INTERNAL)?;
        Ok(Self {
            tx,
            state,
            epoch,
            sequence: AtomicU64::new(1),
        })
    }
    pub fn submit(&self, r: Request) -> Result<u64, u32> {
        self.enqueue(r, None)
    }
    pub fn submit_corner_hide(&self, r: Request, child: i32, birth: u64, writer: i32) -> Result<u64, u32> {
        if !r.valid() || r.backend != CORNER || r.operation != HIDE || child <= 1 || birth == 0 {
            return Err(INVALID);
        }
        if writer < 0 || lock(&self.state).corner_hides.is_none() || r.epoch != ACQUISITION_EPOCH {
            return Err(INCOMPATIBLE);
        }
        let peer = GuardianPeer::open(child, birth, writer).ok_or(INCOMPATIBLE)?;
        self.enqueue(r, Some(Arc::new(peer)))
    }
    fn enqueue(&self, r: Request, guardian: Option<Arc<GuardianPeer>>) -> Result<u64, u32> {
        if !r.valid() || r.epoch != self.epoch.load(Ordering::Acquire) {
            return Err(INVALID);
        }
        let mut s = lock(&self.state);
        if s.closed {
            return Err(CLOSED);
        }
        if s.tickets.len() >= LIMIT {
            return Err(BUSY);
        }
        let track = r.backend == CORNER && r.operation == HIDE && s.corner_hides.is_some();
        if track {
            s.unused_hide(r.intent)?;
        }
        let id = next(&self.sequence)?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let began = Instant::now();
        s.tickets.insert(
            id,
            Ticket {
                cancelled: cancelled.clone(),
                result: None,
                request: r,
                began,
                may_have_dispatched: false,
                readback_until: None,
            },
        );
        if let Err(error) = self.tx.try_send(Job {
            id,
            r,
            began,
            cancelled,
            guardian,
        }) {
            s.tickets.remove(&id);
            return Err(match error {
                mpsc::TrySendError::Full(_) => BUSY,
                mpsc::TrySendError::Disconnected(_) => CLOSED,
            });
        }
        if track {
            s.corner_hides.as_mut().unwrap().insert(r.intent);
        }
        Ok(id)
    }
    /// An exclusion on the original handle, never permission to write on the replacement epoch.
    pub fn fence_unsubmitted_corner_hide(&self, r: Request) -> Result<(), u32> {
        if !r.valid()
            || r.pid <= 1
            || r.backend != CORNER
            || r.operation != HIDE
            || r.epoch != ACQUISITION_EPOCH
        {
            return Err(INVALID);
        }
        let mut s = lock(&self.state);
        if s.closed {
            return Err(CLOSED);
        }
        s.unused_hide(r.intent)?;
        s.corner_hides.as_mut().unwrap().insert(r.intent);
        Ok(())
    }
    pub fn poll(&self, id: u64) -> Result<Receipt, u32> {
        let mut s = lock(&self.state);
        let active_corner = s.running == Some(id) && s.corner_hides.is_some();
        let t = s.tickets.get_mut(&id).ok_or(NO_TICKET)?;
        let r = if let Some(r) = t.result {
            r
        } else {
            let request = t.request;
            let elapsed = t.began.elapsed();
            let revoked = t.cancelled.load(Ordering::Acquire)
                || self.epoch.load(Ordering::Acquire) != request.epoch;
            if !revoked && elapsed < Duration::from_millis(request.timeout_ms.into()) {
                return Err(PENDING);
            }
            t.cancelled.store(true, Ordering::Release);
            if active_corner && t.may_have_dispatched && request.backend == CORNER && request.operation == HIDE {
                // Revoke new effects immediately. Give the in-flight AX setter a bounded
                // interval to return its measured postimage to the original Guardian.
                let now = Instant::now();
                let deadline = t.began + Duration::from_millis(request.timeout_ms.into());
                let until = t.readback_until.get_or_insert(now.min(deadline) + CORNER_READBACK_GRACE);
                if now < *until {
                    return Err(PENDING);
                }
            }
            let status = if t.may_have_dispatched {
                UNKNOWN
            } else if revoked {
                CANCELLED
            } else {
                TIMEOUT
            };
            let outcome = Outcome::new(status);
            if t.may_have_dispatched {
                s.record_write(&request, outcome);
            }
            terminal(request, outcome, elapsed)
        };
        s.tickets.remove(&id);
        Ok(r)
    }
    pub fn cancel(&self, id: u64) -> Result<(), u32> {
        let s = lock(&self.state);
        let t = s.tickets.get(&id).ok_or(NO_TICKET)?;
        t.cancelled.store(true, Ordering::Release);
        Ok(())
    }
    pub fn close(&self) -> Result<(), u32> {
        let mut s = lock(&self.state);
        if !s.tickets.is_empty()
            || s.running.is_some()
            || s.owner.is_some()
            || !s.unresolved.is_empty()
            || s.health_lost
        {
            return Err(BUSY);
        }
        s.closed = true;
        Ok(())
    }
}
fn process(
    config: &Config,
    qualified: Option<crate::Grant>,
    shared: &Mutex<State>,
    epoch: &Arc<AtomicU64>,
    backends: &mut Backends,
    job: Job,
) {
    let r = job.r;
    let control = Control {
        epoch: epoch.clone(),
        expected: r.epoch,
        cancelled: job.cancelled,
        deadline: job.began + Duration::from_millis(r.timeout_ms as u64),
        write: r.writes()
            && (config.allows(&r) || qualified_write(qualified, &r))
            && !(qualified.is_some() && r.operation == HIDE && job.guardian.is_none()),
        guardian: job.guardian,
        spaces_route: None, // Product handles have no native Space migration route.
        corner_input_check: r.operation == HEALTH
            && r.backend == CORNER
            && ((r.epoch == ACQUISITION_EPOCH && qualified.is_some_and(|g| g.backend == CORNER))
                || (config.mode == 1 && config.valid() && (r.pid == 0 || config.allows(&r)))),
    };
    let may_enter = {
        let mut s = lock(shared);
        let allowed = r.writes()
            && control.may_write()
            && s.owner.is_none_or(|b| b == r.backend)
            && ((s.unresolved.is_empty() && !s.health_lost)
                || matches!(r.operation, RESTORE | CLEAN_LAUNCH))
            && s.can_run_probe(&r);
        let Some(ticket) = s.tickets.get_mut(&job.id) else {
            return;
        };
        ticket.may_have_dispatched = allowed;
        s.running = Some(job.id);
        allowed
    };
    let result = if let Err(e) = control.guard() {
        Outcome::new(e)
    } else if r.writes() && !may_enter {
        Outcome::new(UNSUPPORTED)
    } else if let Some(b) = backends.get(r.backend) {
        catch_unwind(AssertUnwindSafe(|| b.execute(&r, &control))).unwrap_or(Outcome::new(UNKNOWN))
    } else {
        Outcome::new(UNSUPPORTED)
    };
    lock(shared).finish_job(job.id, r, &control, may_enter, result, job.began.elapsed());
}
fn terminal(r: Request, result: Outcome, elapsed: Duration) -> Receipt {
    Receipt {
        size: size_of::<Receipt>() as u32,
        version: ABI,
        status: result.status,
        flags: result.flags,
        detail: result.detail,
        owned: result.owned,
        native_id: result.native_id,
        epoch: r.epoch,
        elapsed_ns: elapsed.as_nanos().min(u64::MAX as u128) as u64,
        intent: r.intent,
        frame: result.frame,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn idle_corner_lane() -> (Session, mpsc::Receiver<Job>, Request) {
        // No worker or window system is involved. Tests drive the actual synchronized ticket entry points.
        let (tx, rx) = mpsc::sync_channel(LIMIT);
        let session = Session {
            tx,
            state: Arc::new(Mutex::new(State {
                corner_hides: Some(HashSet::new()),
                ..Default::default()
            })),
            epoch: Arc::new(AtomicU64::new(1)),
            sequence: AtomicU64::new(1),
        };
        let r = Request {
            backend: CORNER,
            operation: HIDE,
            intent: [1; 16],
            group: [2; 16],
            display: [3; 16],
            native_space: [4; 16],
            member: [5; 16],
            lifetime: [6; 16],
            generation: [7; 16],
            pid: 231,
            birth: 123,
            window: 41,
            native_id: 9,
            timeout_ms: 500,
            epoch: 1,
            frame: Rect {
                x: 5.,
                y: 9.,
                width: 640.,
                height: 380.,
            },
            ..Default::default()
        };
        (session, rx, r)
    }
    #[test]
    fn qualified_hide_without_a_guardian_never_enters_the_backend() {
        let (session, rx, request) = idle_corner_lane();
        assert_eq!(session.submit_corner_hide(request, 0, 1, -1), Err(INVALID));
        assert_eq!(session.submit_corner_hide(request, 42, 0, -1), Err(INVALID));
        assert_eq!(
            session.submit_corner_hide(request, std::process::id() as i32, 1, -1),
            Err(INCOMPATIBLE)
        );
        let id = session.submit(request).unwrap();
        let read_only = Config {
            size: 48,
            version: ABI,
            mode: 0,
            process_count: 0,
            processes: [Process::default(); 2],
        };
        let grant = Some(crate::Grant {
            backend: CORNER,
            evidence: [1; 16],
        });
        process(
            &read_only,
            grant,
            &session.state,
            &session.epoch,
            &mut Backends::new(),
            rx.recv().unwrap(),
        );
        assert_eq!(session.poll(id).unwrap().status, UNSUPPORTED);
        let state = lock(&session.state);
        assert!(state.owner.is_none() && state.unresolved.is_empty());
    }
    #[test]
    fn withdrawal_and_ticket_admission_have_one_winner() {
        let (session, rx, r) = idle_corner_lane();
        let gate = std::sync::Barrier::new(2);
        let (submitted, withdrawn) = std::thread::scope(|t| {
            let submit = t.spawn(|| {
                gate.wait();
                session.submit(r)
            });
            gate.wait();
            let fence = session.fence_unsubmitted_corner_hide(r);
            (submit.join().unwrap(), fence)
        });
        assert_ne!(submitted.is_ok(), withdrawn.is_ok());
        assert_eq!(rx.try_recv().is_ok(), submitted.is_ok());
        assert_eq!(session.submit(r), Err(BUSY));
        assert_eq!(session.fence_unsubmitted_corner_hide(r), Err(BUSY));
    }
    #[test]
    fn accepted_and_consumed_unknown_or_cancelled_ticket_permanently_prevents_withdrawal() {
        for dispatched in [false, true] {
            let (session, _rx, r) = idle_corner_lane();
            let id = session.submit(r).unwrap();
            lock(&session.state)
                .tickets
                .get_mut(&id)
                .unwrap()
                .may_have_dispatched = dispatched;
            session.cancel(id).unwrap();
            assert_eq!(
                session.poll(id).unwrap().status,
                if dispatched { UNKNOWN } else { CANCELLED }
            );
            assert!(lock(&session.state).tickets.is_empty());
            assert_eq!(session.fence_unsubmitted_corner_hide(r), Err(BUSY));
        }
    }
    #[test]
    fn only_original_qualified_hide_can_exclude_an_intent_after_revocation() {
        let (session, rx, r) = idle_corner_lane();
        session.epoch.store(2, Ordering::Release);
        for invalid in [
            Request { epoch: 2, ..r },
            Request {
                operation: RESTORE,
                ..r
            },
            Request {
                generation: [0; 16],
                ..r
            },
            Request {
                backend: SPACES,
                ..r
            },
        ] {
            assert_eq!(session.fence_unsubmitted_corner_hide(invalid), Err(INVALID));
        }
        assert_eq!(session.fence_unsubmitted_corner_hide(r), Ok(()));
        assert_eq!(session.submit(r), Err(INVALID));
        assert_eq!(session.submit(Request { epoch: 2, ..r }), Err(BUSY));
        assert!(rx.try_recv().is_err() && lock(&session.state).owner.is_none());
        session.close().unwrap();
        assert_eq!(session.fence_unsubmitted_corner_hide(r), Err(CLOSED));
        let (readonly, _rx, r) = idle_corner_lane();
        lock(&readonly.state).corner_hides = None;
        assert_eq!(readonly.fence_unsubmitted_corner_hide(r), Err(INCOMPATIBLE));
    }
    #[test]
    fn cleanup_after_a_denied_startup_cannot_release_a_business_window() {
        let mut s = State::default();
        let cleanup = Request {
            operation: CLEAN_LAUNCH,
            backend: SPACES,
            ..Default::default()
        };
        assert!(s.can_run_probe(&cleanup));
        let unrelated = Request {
            operation: HIDE,
            backend: SPACES,
            member: [3; 16],
            ..Default::default()
        };
        s.record_write(&unrelated, Outcome::new(UNKNOWN));
        assert!(!s.can_run_probe(&cleanup));
        assert!(s.owner.is_some() && !s.unresolved.is_empty());
    }
    #[test]
    fn bounded_queue_and_terminal_timeout_do_not_depend_on_a_stalled_worker() {
        let (tx, _rx) = mpsc::sync_channel(LIMIT);
        let session = Session {
            tx,
            state: Default::default(),
            epoch: Arc::new(AtomicU64::new(1)),
            sequence: AtomicU64::new(1),
        };
        let req = Request {
            operation: HEALTH,
            backend: CORNER,
            intent: [1; 16],
            timeout_ms: 1000,
            epoch: 1,
            ..Default::default()
        };
        let ids: Vec<_> = (0..LIMIT).map(|_| session.submit(req).unwrap()).collect();
        assert_eq!(session.submit(req), Err(BUSY));
        let id = ids[0];
        lock(&session.state).tickets.get_mut(&id).unwrap().began =
            Instant::now() - Duration::from_secs(2);
        assert_eq!(session.poll(id).unwrap().status, TIMEOUT);
        session.cancel(ids[1]).unwrap();
        assert_eq!(session.poll(ids[1]).unwrap().status, CANCELLED);
        let mut s = lock(&session.state);
        let t = s.tickets.get_mut(&ids[2]).unwrap();
        t.may_have_dispatched = true;
        t.cancelled.store(true, Ordering::Release);
        drop(s);
        assert_eq!(session.poll(ids[2]).unwrap().status, UNKNOWN);
        assert_eq!(lock(&session.state).owner, Some(CORNER));
        assert_eq!(session.close(), Err(BUSY));
    }
    #[test]
    fn returning_a_different_member_or_group_generation_cannot_release_the_original_lease() {
        let mut s = State::default();
        let original = Request {
            backend: CORNER,
            operation: HIDE,
            member: [1; 16],
            lifetime: [2; 16],
            group: [3; 16],
            generation: [4; 16],
            display: [5; 16],
            native_space: [6; 16],
            native_id: 7,
            pid: 40,
            birth: 90,
            window: 71,
            ..Default::default()
        };
        s.record_write(&original, Outcome::new(UNKNOWN));
        let r = Request {
            operation: RESTORE,
            intent: [24; 16],
            epoch: 2,
            ..original
        };
        let visible = Outcome {
            status: PASS,
            flags: VISIBLE | AX_VALID | CG_VALID | MEMBERSHIP_VALID,
            native_id: original.native_id,
            ..Default::default()
        };
        for other in [
            Request {
                member: [8; 16],
                ..r
            },
            Request {
                lifetime: [9; 16],
                ..r
            },
            Request {
                group: [8; 16],
                ..r
            },
            Request {
                generation: [9; 16],
                ..r
            },
            Request {
                display: [8; 16],
                ..r
            },
            Request {
                native_space: [9; 16],
                ..r
            },
            Request { native_id: 10, ..r },
            Request { pid: 81, ..r },
            Request { birth: 91, ..r },
            Request { window: 72, ..r },
        ] {
            s.record_write(
                &other,
                Outcome {
                    native_id: other.native_id,
                    ..visible
                },
            );
            assert_eq!(s.owner, Some(CORNER));
            assert_eq!(s.unresolved.len(), 1);
        }
        for bad in [
            Outcome {
                native_id: original.native_id + 1,
                ..visible
            },
            Outcome {
                flags: visible.flags | HIDDEN,
                ..visible
            },
            Outcome {
                flags: visible.flags | OWNED,
                ..visible
            },
            Outcome {
                flags: visible.flags & !AX_VALID,
                ..visible
            },
            Outcome {
                flags: visible.flags & !CG_VALID,
                ..visible
            },
            Outcome {
                flags: visible.flags & !MEMBERSHIP_VALID,
                ..visible
            },
            Outcome {
                flags: visible.flags & !VISIBLE,
                ..visible
            },
        ] {
            assert_eq!(s.record_write(&r, bad).status, UNKNOWN);
            assert_eq!(s.owner, Some(CORNER));
            assert_eq!(s.unresolved.len(), 1);
        }
        assert_eq!(s.record_write(&r, visible).status, PASS);
        assert_eq!(s.owner, None);
        assert!(s.unresolved.is_empty());
    }

    #[test]
    fn a_revoked_product_owner_can_restore_but_cannot_rearm_itself_with_the_next_epoch() {
        for backend in [CORNER, SPACES] {
            let grant = Some(crate::Grant {
                backend,
                evidence: [1; 16],
            });
            for operation in [HIDE, SHOW, LAUNCH, RESTORE, CLEAN_LAUNCH, TRIAL] {
                let r = Request {
                    backend,
                    operation,
                    epoch: ACQUISITION_EPOCH,
                    ..Default::default()
                };
                assert_eq!(
                    qualified_write(grant, &r),
                    backend == CORNER && matches!(operation, HIDE | SHOW | RESTORE)
                );
                let next = Request {
                    epoch: ACQUISITION_EPOCH + 1,
                    ..r
                };
                assert_eq!(
                    qualified_write(grant, &next),
                    backend == CORNER && operation == RESTORE
                );
                assert!(!qualified_write(None, &next));
                assert!(!qualified_write(
                    grant,
                    &Request {
                        backend: if backend == CORNER { SPACES } else { CORNER },
                        ..r
                    }
                ));
            }
        }
    }

    #[test]
    fn a_revoked_inflight_park_delivers_only_an_exact_recovery_frame() {
        let (session, rx, r) = idle_corner_lane();
        let id = session.submit(r).unwrap();
        let job = rx.recv().unwrap();
        {
            let mut s = lock(&session.state);
            s.running = Some(id);
            s.tickets.get_mut(&id).unwrap().may_have_dispatched = true;
        }
        session.cancel(id).unwrap();
        assert!(matches!(session.poll(id), Err(PENDING)));
        let control = Control {
            epoch: session.epoch.clone(), expected: r.epoch, cancelled: job.cancelled,
            deadline: Instant::now() + Duration::from_secs(1), write: true,
            spaces_route: None, corner_input_check: false, guardian: None,
        };
        assert!(!control.may_write());
        let identity = AX_VALID | CG_VALID | MEMBERSHIP_VALID | OWNED;
        let measured = Outcome {
            status: PASS, flags: identity | HIDDEN | INPUT_SAFE, owned: 1, native_id: r.native_id,
            frame: Rect { x: 1399., y: 850., ..r.frame }, ..Default::default()
        };
        lock(&session.state).finish_job(id, r, &control, true, measured, Duration::ZERO);
        let receipt = session.poll(id).unwrap();
        assert_eq!(receipt.status, UNKNOWN);
        assert_eq!(receipt.flags, identity | CORNER_RECOVERY_FRAME);
        assert_eq!((receipt.native_id, receipt.frame), (r.native_id, measured.frame));
        assert_eq!(session.close(), Err(BUSY));
        for stale in [
            Outcome { native_id: r.native_id + 1, ..measured },
            Outcome { flags: measured.flags & !MEMBERSHIP_VALID, ..measured },
            Outcome { flags: measured.flags | VISIBLE, ..measured },
            Outcome { frame: Rect::default(), ..measured },
            Outcome { owned: 0, ..measured },
        ] {
            let late = stale.only_for_corner_recovery(r.native_id, INTERRUPTED_CORNER_PARK);
            assert_eq!((late.status, late.flags, late.native_id, late.frame), (UNKNOWN, OWNED, 0, Rect::default()));
        }
    }
    #[test]
    fn a_stalled_corner_setter_releases_its_ticket_but_keeps_ownership_after_the_grace() {
        let (session, _rx, r) = idle_corner_lane();
        let id = session.submit(r).unwrap();
        let mut s = lock(&session.state);
        s.running = Some(id);
        let ticket = s.tickets.get_mut(&id).unwrap();
        ticket.may_have_dispatched = true;
        ticket.began = Instant::now() - Duration::from_millis(r.timeout_ms.into()) - CORNER_READBACK_GRACE;
        drop(s);
        let receipt = session.poll(id).unwrap();
        assert_eq!((receipt.status, receipt.flags), (UNKNOWN, 0));
        assert!(matches!(session.poll(id), Err(NO_TICKET)));
        assert_eq!(session.close(), Err(BUSY));
    }
    #[test]
    fn a_late_visible_callback_cannot_retire_ownership_after_poll_returned_unknown() {
        let (tx, _rx) = mpsc::sync_channel(LIMIT);
        let session = Session {
            tx,
            state: Default::default(),
            epoch: Arc::new(ACQUISITION_EPOCH.into()),
            sequence: AtomicU64::new(1),
        };
        let r = Request {
            operation: RESTORE,
            backend: CORNER,
            intent: [1; 16],
            group: [2; 16],
            member: [3; 16],
            generation: [4; 16],
            lifetime: [5; 16],
            display: [6; 16],
            native_space: [7; 16],
            pid: 40,
            birth: 90,
            window: 71,
            native_id: 7,
            epoch: ACQUISITION_EPOCH,
            timeout_ms: 1000,
            frame: Rect {
                x: 5.,
                y: 5.,
                width: 100.,
                height: 100.,
            },
            ..Default::default()
        };
        let id = session.submit(r).unwrap();
        let cancelled = {
            let mut s = lock(&session.state);
            s.running = Some(id);
            let t = s.tickets.get_mut(&id).unwrap();
            t.may_have_dispatched = true;
            t.cancelled.clone()
        };
        session.cancel(id).unwrap();
        assert_eq!(session.poll(id).unwrap().status, UNKNOWN);
        let control = Control {
            epoch: session.epoch.clone(),
            expected: r.epoch,
            cancelled,
            deadline: Instant::now() + Duration::from_secs(5),
            write: true,
            spaces_route: None,
            corner_input_check: false,
            guardian: None,
        };
        let visible = Outcome {
            status: PASS,
            flags: VISIBLE | AX_VALID | CG_VALID | MEMBERSHIP_VALID,
            native_id: r.native_id,
            ..Default::default()
        };
        lock(&session.state).finish_job(id, r, &control, true, visible, Duration::ZERO);
        assert!(matches!(session.poll(id), Err(NO_TICKET)));
        assert_eq!(session.close(), Err(BUSY));
        // A separate, fresh restore of this exact lease carries new independent evidence.
        let newer = Request {
            intent: [8; 16],
            ..r
        };
        assert_eq!(
            lock(&session.state).record_write(&newer, visible).status,
            PASS
        );
        assert_eq!(session.close(), Ok(()));
    }
}
