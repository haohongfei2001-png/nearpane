//! C records contain no pointers or padding-dependent semantic values.
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::Instant;

pub const ABI: u32 = 1;
pub const CORNER: u32 = 1;
pub const SPACES: u32 = 2;
pub const PROBE: u32 = 1;
pub const READBACK: u32 = 2;
pub const HIDE: u32 = 3;
pub const SHOW: u32 = 4;
pub const RESTORE: u32 = 5;
pub const HEALTH: u32 = 6;
pub const TRIAL: u32 = 7;
pub const LAUNCH: u32 = 8;
pub const CLEAN_LAUNCH: u32 = 9;
pub const PASS: u32 = 0;
pub const FAIL: u32 = 1;
pub const UNKNOWN: u32 = 2;
pub const UNSUPPORTED: u32 = 3;
pub const TIMEOUT: u32 = 4;
pub const CANCELLED: u32 = 5;
pub const VISIBLE: u32 = 1;
pub const HIDDEN: u32 = 2;
pub const AX_VALID: u32 = 4;
pub const CG_VALID: u32 = 8;
pub const INPUT_SAFE: u32 = 16;
pub const MEMBERSHIP_VALID: u32 = 32;
pub const HEALTHY: u32 = 64;
pub const OWNED: u32 = 128;
pub const PROBE_RESTORED: u32 = 256;
pub const PROBE_CLOSED: u32 = 512;
pub const PROBE_SPACE_DESTROYED: u32 = 1024;
pub const PROBE_CLEAN_FLAGS: u32 = PROBE_RESTORED | PROBE_CLOSED | PROBE_SPACE_DESTROYED;
pub const TRIAL_CLASSIC: u32 = 1 << 16;
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub fn valid(self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|x| x.is_finite())
            && self.width > 0.0
            && self.height > 0.0
    }
}
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Process {
    pub pid: i32,
    pub reserved: u32,
    pub birth: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Config {
    pub size: u32,
    pub version: u32,
    pub mode: u32,
    pub process_count: u32,
    pub processes: [Process; 2],
}
#[repr(C)]
#[derive(Default, Debug, Clone, Copy)]
pub struct Request {
    pub size: u32,
    pub version: u32,
    pub backend: u32,
    pub operation: u32,
    pub flags: u32,
    pub timeout_ms: u32,
    pub intent: [u8; 16],
    pub group: [u8; 16],
    pub display: [u8; 16],
    pub native_space: [u8; 16],
    pub member: [u8; 16],
    pub lifetime: [u8; 16],
    pub generation: [u8; 16],
    pub pid: i32,
    pub window: u32,
    pub birth: u64,
    pub native_id: u64,
    pub epoch: u64,
    pub frame: Rect,
    pub target: Rect,
}
impl Request {
    pub fn writes(&self) -> bool {
        matches!(self.operation, HIDE | SHOW | RESTORE | TRIAL | LAUNCH | CLEAN_LAUNCH)
    }
    pub fn valid(&self) -> bool {
        if !matches!(self.backend, CORNER | SPACES)
            || !(PROBE..=CLEAN_LAUNCH).contains(&self.operation)
            || self.intent == [0; 16]
            || self.epoch == 0
            || !(1..=10_000).contains(&self.timeout_ms)
        {
            return false;
        }
        if self.flags != 0
            && !(self.backend == SPACES && self.operation == TRIAL && self.flags == TRIAL_CLASSIC)
        {
            return false;
        }
        if matches!(self.operation, PROBE | HEALTH) {
            return true;
        }
        if matches!(self.operation, LAUNCH | CLEAN_LAUNCH) {
            return self.backend == SPACES && self.flags == 0 && self.pid == 0 && self.window == 0
                && self.birth == 0 && self.native_id == 0 && self.frame == Rect::default()
                && self.target == Rect::default() && [self.group,self.display,self.native_space,
                    self.member,self.lifetime,self.generation].iter().all(|id| *id == [0;16]);
        }
        self.pid > 0
            && self.birth > 0
            && self.window > 0
            && self.native_id != 0
            && self.frame.valid()
            && [
                self.group,
                self.display,
                self.native_space,
                self.member,
                self.lifetime,
                self.generation,
            ]
            .iter()
            .all(|id| *id != [0; 16])
    }
}
#[derive(Clone)]
pub struct Control {
    pub(crate) epoch: Arc<AtomicU64>,
    pub(crate) expected: u64,
    pub(crate) cancelled: Arc<AtomicBool>,
    pub(crate) deadline: Instant,
    pub(crate) write: bool,
    pub(crate) spaces_route: Option<u32>,
}
impl Control {
    pub fn guard(&self) -> Result<(), u32> {
        if self.cancelled.load(Ordering::Acquire)
            || self.epoch.load(Ordering::Acquire) != self.expected
        {
            Err(CANCELLED)
        } else if Instant::now() >= self.deadline {
            Err(TIMEOUT)
        } else {
            Ok(())
        }
    }
    pub fn may_write(&self) -> bool {
        self.write && self.guard().is_ok()
    }
    pub fn approved_spaces_route(&self) -> Option<u32> {
        self.spaces_route.filter(|_| self.may_write())
    }
}
#[derive(Clone, Copy, Default, Debug)]
pub struct Outcome {
    pub status: u32,
    pub flags: u32,
    pub detail: u32,
    pub owned: u32,
    pub native_id: u64,
    pub frame: Rect,
}
impl Outcome {
    pub fn new(status: u32) -> Self {
        Self {
            status,
            ..Self::default()
        }
    }
}
pub trait WindowEngine {
    fn execute(&mut self, request: &Request, control: &Control) -> Outcome;
    fn tick(&mut self) {}
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Receipt {
    pub size: u32,
    pub version: u32,
    pub status: u32,
    pub flags: u32,
    pub detail: u32,
    pub owned: u32,
    pub native_id: u64,
    pub epoch: u64,
    pub elapsed_ns: u64,
    pub intent: [u8; 16],
    pub frame: Rect,
}
