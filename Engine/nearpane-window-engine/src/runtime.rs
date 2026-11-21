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
}
#[derive(Hash, Eq, PartialEq)]
struct Lease {
    member: [u8; 16],
    lifetime: [u8; 16],
    display: [u8; 16],
    native_space: [u8; 16],
    pid: i32,
    birth: u64,
    window: u32,
}
impl From<&Request> for Lease {
    fn from(r: &Request) -> Self {
        Self {
            member: r.member,
            lifetime: r.lifetime,
            display: r.display,
            native_space: r.native_space,
            pid: r.pid,
            birth: r.birth,
            window: r.window,
        }
    }
}
#[derive(Default)]
struct State {
    tickets: HashMap<u64, Ticket>,
    owner: Option<u32>,
    unresolved: HashSet<Lease>,
    health_lost: bool,
    running: Option<u64>,
    closed: bool,
}
impl State {
    fn can_run_probe(&self, r: &Request) -> bool {
        match r.operation {
            LAUNCH => self.owner.is_none(),
            // The backend also proves the no-panel/no-space case following a pre-dispatch denial.
            CLEAN_LAUNCH => self.owner.is_none() || self.unresolved.contains(&Lease::from(r)),
            _ => true,
        }
    }
    fn record_write(&mut self, request: &Request, result: &Outcome) {
        let lease = Lease::from(request);
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
            return;
        }
        if result.owned > 0 || result.flags & OWNED != 0 || result.status == UNKNOWN {
            self.owner = Some(request.backend);
        }
        if result.status == UNKNOWN || (canary && (result.owned != 0 || result.flags & OWNED != 0))
        {
            self.unresolved.insert(lease);
            return;
        }
        if matches!(request.operation, RESTORE | SHOW)
            && result.status == PASS
            && result.flags & VISIBLE != 0
            && result.flags & OWNED == 0
        {
            self.unresolved.remove(&lease);
            if result.owned == 0 && self.unresolved.is_empty() {
                self.owner = None;
                self.health_lost = false;
            }
        }
    }
}
struct Job {
    id: u64,
    r: Request,
    began: Instant,
    cancelled: Arc<AtomicBool>,
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
        let state = Arc::new(Mutex::new(State::default()));
        let epoch = Arc::new(AtomicU64::new(1));
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
            },
        );
        if let Err(error) = self.tx.try_send(Job {
            id,
            r,
            began,
            cancelled,
        }) {
            s.tickets.remove(&id);
            return Err(match error {
                mpsc::TrySendError::Full(_) => BUSY,
                mpsc::TrySendError::Disconnected(_) => CLOSED,
            });
        }
        Ok(id)
    }
    pub fn poll(&self, id: u64) -> Result<Receipt, u32> {
        let mut s = lock(&self.state);
        let t = s.tickets.get(&id).ok_or(NO_TICKET)?;
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
            let status = if t.may_have_dispatched {
                UNKNOWN
            } else if revoked {
                CANCELLED
            } else {
                TIMEOUT
            };
            let outcome = Outcome::new(status);
            if t.may_have_dispatched {
                s.record_write(&request, &outcome);
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
            && (config.allows(&r)
                || (qualified.is_some_and(|g| g.backend == r.backend) && r.operation != TRIAL)),
        spaces_route: qualified.and_then(|g| g.spaces_route),
        corner_input_check: r.operation == HEALTH
            && r.backend == CORNER
            && (qualified.is_some_and(|g| g.backend == CORNER)
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
    let mut result = if let Err(e) = control.guard() {
        Outcome::new(e)
    } else if r.writes() && !may_enter {
        Outcome::new(UNSUPPORTED)
    } else if let Some(b) = backends.get(r.backend) {
        catch_unwind(AssertUnwindSafe(|| b.execute(&r, &control))).unwrap_or(Outcome::new(UNKNOWN))
    } else {
        Outcome::new(UNSUPPORTED)
    };
    if let Err(e) = control.guard() {
        result.status = if may_enter { UNKNOWN } else { e };
    }
    let mut s = lock(shared);
    s.running = None;
    if may_enter {
        s.record_write(&r, &result);
    }
    if let Some(t) = s.tickets.get_mut(&job.id) {
        t.result = Some(terminal(r, result, job.began.elapsed()));
    }
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
        s.record_write(&unrelated, &Outcome::new(UNKNOWN));
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
    fn restoring_a_sibling_does_not_release_an_ambiguous_lease() {
        let mut s = State::default();
        let mut r = Request {
            backend: CORNER,
            operation: HIDE,
            member: [1; 16],
            lifetime: [2; 16],
            ..Default::default()
        };
        s.record_write(&r, &Outcome::new(UNKNOWN));
        let visible = Outcome {
            status: PASS,
            flags: VISIBLE,
            ..Default::default()
        };
        r.operation = RESTORE;
        r.lifetime = [3; 16];
        s.record_write(&r, &visible);
        assert_eq!(s.owner, Some(CORNER));
        assert_eq!(s.unresolved.len(), 1);
        r.lifetime = [2; 16];
        s.record_write(&r, &visible);
        assert_eq!(s.owner, None);
        assert!(s.unresolved.is_empty());
    }
}
