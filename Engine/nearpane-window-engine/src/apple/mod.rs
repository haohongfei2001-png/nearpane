//! Apple Stage Manager mirror. All observations are supplied by the caller;
//! this module has no WindowServer, Accessibility, input or preference writer.
use crate::contract::Rect;
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{LazyLock, Mutex};

mod grouping;
mod merge;
mod mirror;
#[cfg(test)]
mod tests;

const VERSION: u32 = 1;
const INVALID: u32 = 1;
const CLOSED: u32 = 2;
const SCOPE_CHANGED: u32 = 3;
const CAPACITY: u32 = 4;
const UNAVAILABLE: u32 = 5;
const STALE: u32 = 6;
const INTERNAL: u32 = 7;
const CURRENT: u32 = 1;
const STRIP: u32 = 2;
const REMEMBERED: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Scope {
    pub size: u32,
    pub version: u32,
    pub display_uuid: [u8; 16],
    pub native_space_id: u64,
}
impl Scope {
    fn valid(self) -> bool {
        self.size as usize == size_of::<Self>()
            && self.version == VERSION
            && self.display_uuid != [0; 16]
            && self.native_space_id != 0
    }
}
#[repr(C)]
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Listed {
    pub window: u32,
    pub pid: i32,
    pub layer: i32,
    pub onscreen: u32,
    pub frame: Rect,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct AxMember {
    pub item: u32,
    pub window: u32,
    pub frame: Rect,
}
#[repr(C)]
pub struct Input {
    pub size: u32,
    pub version: u32,
    pub scope: Scope,
    pub sample_time_ns: u64,
    pub display_frame: Rect,
    pub manager_pid: i32,
    pub ax_available: u32,
    pub transition_began: u32,
    pub listed_count: u32,
    pub managed_count: u32,
    pub ax_count: u32,
    pub listed: *const Listed,
    pub managed: *const u32,
    pub ax_members: *const AxMember,
}
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Member {
    pub ordinal: u32,
    pub role: u32,
    pub window: u32,
    pub confirmed_by_ax: u32,
    pub group_frame: Rect,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ResultInfo {
    pub size: u32,
    pub version: u32,
    pub member_count: u32,
    pub settled: u32,
    pub disagreement: u32,
    pub trusted_ax: u32,
    pub strip_shown: i32,
}
impl Default for ResultInfo {
    fn default() -> Self {
        Self {
            size: size_of::<Self>() as u32,
            version: VERSION,
            member_count: 0,
            settled: 0,
            disagreement: 0,
            trusted_ax: 0,
            strip_shown: -1,
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
struct Group {
    windows: Vec<u32>,
    frame: Rect,
}
struct Session {
    scope: Scope,
    state: mirror::State,
}
struct Registry {
    next: u64,
    sessions: BTreeMap<u64, Session>,
}
static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(|| {
    Mutex::new(Registry {
        next: 0,
        sessions: BTreeMap::new(),
    })
});
fn ffi(body: impl FnOnce() -> Result<(), u32>) -> u32 {
    catch_unwind(AssertUnwindSafe(body)).map_or(INTERNAL, |r| r.err().unwrap_or(0))
}
fn pointer<T>(p: *const T) -> bool {
    !p.is_null() && p.is_aligned()
}
// All versioned records start with two uint32_t values. Reject a foreign layout
// before forming a reference that would require the complete v1 allocation.
unsafe fn header_matches<T>(p: *const T) -> bool {
    let header = p.cast::<u32>();
    unsafe { header.read() as usize == size_of::<T>() && header.add(1).read() == VERSION }
}
unsafe fn slice<'a, T>(p: *const T, n: u32, limit: u32) -> Result<&'a [T], u32> {
    if n == 0 {
        return Ok(&[]);
    }
    if n > limit || !pointer(p) {
        return Err(INVALID);
    }
    Ok(unsafe { std::slice::from_raw_parts(p, n as usize) })
}

/// Caller owns aligned, initialized scope storage and disjoint writable handle storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_apple_mirror_create(scope: *const Scope, handle: *mut u64) -> u32 {
    ffi(|| {
        if !pointer(scope) || !pointer(handle) {
            return Err(INVALID);
        }
        unsafe {
            handle.write(0);
        }
        if !unsafe { header_matches(scope) } {
            return Err(INVALID);
        }
        let scope = unsafe { *scope };
        if !scope.valid() {
            return Err(INVALID);
        }
        let mut registry = REGISTRY.lock().map_err(|_| INTERNAL)?;
        if registry.sessions.len() >= 64 {
            return Err(CAPACITY);
        }
        let id = registry.next.checked_add(1).ok_or(CAPACITY)?;
        registry.next = id;
        registry.sessions.insert(
            id,
            Session {
                scope,
                state: mirror::State::default(),
            },
        );
        unsafe { handle.write(id) }
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn np_apple_mirror_destroy(handle: u64) -> u32 {
    ffi(|| {
        REGISTRY
            .lock()
            .map_err(|_| INTERNAL)?
            .sessions
            .remove(&handle)
            .map(|_| ())
            .ok_or(CLOSED)
    })
}

/// All supplied arrays must remain valid for the call; output storage must not alias any input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_apple_mirror_read_v1(
    handle: u64,
    input: *const Input,
    members: *mut Member,
    capacity: u32,
    result: *mut ResultInfo,
) -> u32 {
    ffi(|| {
        if !pointer(input) || !pointer(result) || (capacity > 0 && !pointer(members)) {
            return Err(INVALID);
        }
        if !unsafe { header_matches(input) && header_matches(result.cast_const()) } {
            return Err(INVALID);
        }
        let i = unsafe { &*input };
        if !i.scope.valid()
            || !i.display_frame.valid()
            || i.sample_time_ns == 0
            || i.ax_available > 1
            || i.transition_began > 1
            || (i.ax_available == 0 && i.ax_count != 0)
        {
            return Err(INVALID);
        }
        unsafe { result.write(ResultInfo::default()) }
        let listed = unsafe { slice(i.listed, i.listed_count, 8192)? };
        let managed = unsafe { slice(i.managed, i.managed_count, 1024)? };
        let ax = unsafe { slice(i.ax_members, i.ax_count, 2048)? };
        if managed.contains(&0) {
            return Err(INVALID);
        }
        let managed: BTreeSet<_> = managed.iter().copied().collect();
        let mut registry = REGISTRY.lock().map_err(|_| INTERNAL)?;
        let session = registry.sessions.get_mut(&handle).ok_or(CLOSED)?;
        if i.scope != session.scope {
            return Err(SCOPE_CHANGED);
        }
        if i.sample_time_ns <= session.state.time {
            return Err(STALE);
        }
        if i.manager_pid <= 0 {
            // WindowManager may relaunch. Never reuse its old strip or AX confidence after this gap.
            session.state = mirror::State::unavailable(i.sample_time_ns);
            return Err(UNAVAILABLE);
        }
        let (next, rows, info) = session.state.fold(i, listed, &managed, ax)?;
        if rows.len() > capacity as usize {
            unsafe {
                (*result).member_count = rows.len() as u32;
            }
            return Err(CAPACITY);
        }
        if !rows.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(rows.as_ptr(), members, rows.len());
            }
        }
        unsafe {
            result.write(info);
        }
        session.state = next;
        Ok(())
    })
}
