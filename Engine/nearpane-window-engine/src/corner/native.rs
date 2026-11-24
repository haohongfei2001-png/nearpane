//! Values copied from the macOS SDK shim, in Quartz global top-left logical points.
use super::{geometry::Rect, sliver, tap::{SurfaceWatch, Tap}};
use crate::contract::{Control, Request};
use std::ffi::c_void;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub(super) struct Display {
    pub id: [u8; 16],
    pub frame: Rect,
    pub visible: Rect,
}
#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub(super) struct Member {
    pub pid: i32,
    pub window: u32,
    pub birth: u64,
    pub native: u64,
    pub display: [u8; 16],
    pub space: [u8; 16],
}
impl From<&Request> for Member {
    fn from(r: &Request) -> Self {
        Self {
            pid: r.pid,
            window: r.window,
            birth: r.birth,
            native: r.native_id,
            display: r.display,
            space: r.native_space,
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub(super) struct Sample {
    pub ax: Rect,
    pub cg: Rect,
    pub minimized: u32,
    pub onscreen: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Row {
    id: u32,
    pid: i32,
    frame: Rect,
    alpha: f64,
    layer: i64,
}
#[repr(C)]
#[derive(Default)]
struct Dock {
    pid: i32,
    count: u32,
    bars: [Rect; 16],
}

unsafe extern "C" {
    fn np_corner_displays(rows: *mut Display, capacity: u32, count: *mut u32) -> u32;
    fn np_corner_sample(id: *const Member, result: *mut Sample) -> u32;
    fn np_corner_zorder(rows: *mut Row, capacity: u32, count: *mut u32, dock: *mut Dock) -> u32;
    fn np_corner_retain_window(id: *const Member) -> *mut c_void;
    fn np_corner_same_window(id: *const Member, retained: *mut c_void) -> i32;
    fn np_corner_inputs(output: *mut u32);
    fn np_corner_park_access() -> u32;
    fn np_corner_signed_fingerprint(pid: i32, birth: u64, digest: *mut u8) -> i32;
    #[cfg(feature = "isolated-fixtures")]
    fn np_is_enrolled_fixture(pid: i32, birth: u64) -> bool;
    fn np_corner_release_window(retained: *mut c_void);
    fn np_corner_position(
        id: *const Member,
        retained: *mut c_void,
        before: Rect,
        target: Rect,
        purpose: u32,
        guard: extern "C" fn(*mut c_void) -> u32,
        context: *mut c_void,
        issued: *mut u32,
    ) -> u32;
}
pub(super) type Inputs = [u32; 13];
#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct PatchMember {
    pub member: Member,
    pub frame: Rect,
}
unsafe extern "C" {
    fn np_corner_patch_material() -> *mut c_void;
    fn np_corner_patch_material_end(material: *mut c_void);
    fn np_corner_patch_session(material: *mut c_void, context: *const c_void,
                               interrupted: unsafe extern "C" fn(*const c_void, u32)) -> *mut c_void;
    fn np_corner_patch_publish(session: *mut c_void, members: *const PatchMember, count: u32);
    fn np_corner_patch_verified(session: *mut c_void, member: *const PatchMember) -> bool;
    fn np_corner_patch_prepare_source(session: *mut c_void, home: *const Member, footprint: Rect, prepare: bool) -> u32;
    fn np_corner_patch_sites(home: *const Member, footprints: *const Rect, count: u32,
                             first_is_alternate: bool, reasons: *mut u32) -> u32;
    fn np_corner_patch_end(session: *mut c_void);
}
pub(super) struct PatchMaterial(std::ptr::NonNull<c_void>);
pub(super) fn check_patch_sites(home: &Member, footprints: &[Rect], first_is_alternate: bool) -> Result<Vec<u32>, u32> {
    let mut reasons = vec![0; footprints.len()];
    match unsafe {
        np_corner_patch_sites(home, footprints.as_ptr(), footprints.len() as u32, first_is_alternate, reasons.as_mut_ptr())
    } {
        0 => Ok(reasons),
        reason => Err(reason),
    }
}
impl PatchMaterial {
    pub fn new() -> Option<Self> {
        std::ptr::NonNull::new(unsafe { np_corner_patch_material() }).map(Self)
    }
    pub fn source(&self, home: &Member, footprint: Rect, prepare: bool) -> u32 {
        unsafe { np_corner_patch_prepare_source(self.0.as_ptr(), home, footprint, prepare) }
    }
}
impl Drop for PatchMaterial {
    fn drop(&mut self) { unsafe { np_corner_patch_material_end(self.0.as_ptr()) } }
}
pub(super) struct PatchSession {
    session: std::ptr::NonNull<c_void>,
    _watch: SurfaceWatch,
}
impl PatchSession {
    pub fn new(material: &PatchMaterial, tap: &Tap) -> Option<Self> {
        let watch = tap.watch_surface();
        let session = std::ptr::NonNull::new(unsafe {
            np_corner_patch_session(material.0.as_ptr(), watch.context(), SurfaceWatch::interrupted)
        })?;
        Some(Self { session, _watch: watch })
    }
    pub fn publish(&self, members: &[PatchMember]) {
        unsafe { np_corner_patch_publish(self.session.as_ptr(), members.as_ptr(), members.len() as u32) }
    }
    pub fn verified(&self, member: Member, frame: Rect) -> bool {
        unsafe { np_corner_patch_verified(self.session.as_ptr(), &PatchMember { member, frame }) }
    }
}
impl Drop for PatchSession {
    fn drop(&mut self) { unsafe { np_corner_patch_end(self.session.as_ptr()) } }
}
pub(super) fn inputs() -> Inputs {
    let mut state = [0; 13];
    unsafe { np_corner_inputs(state.as_mut_ptr()) };
    state
}
pub(super) fn park_access() -> Result<(), u32> {
    let code = unsafe { np_corner_park_access() };
    if code == 0 { Ok(()) } else { Err(code) }
}
fn fingerprint(member: &Member) -> Option<[u8; 32]> {
    let mut bytes = [0; 32];
    (unsafe { np_corner_signed_fingerprint(member.pid, member.birth, bytes.as_mut_ptr()) == 1 })
        .then_some(bytes)
}
fn active_grant(member: &Member, captured: [u8; 32], control: &Control) -> bool {
    if !control.may_write() || fingerprint(member) != Some(captured) {
        return false;
    }
    #[cfg(feature = "isolated-fixtures")]
    {
        unsafe { np_is_enrolled_fixture(member.pid, member.birth) }
    }
    #[cfg(not(feature = "isolated-fixtures"))]
    {
        // Ordinary mode cannot acquire a writable Control. Only Gate 0's compiled,
        // explicitly reviewed evidence for this backend can create one in this build.
        true
    }
}

pub(super) fn displays() -> Result<Vec<Display>, u32> {
    let mut rows = [Display::default(); 32];
    let mut count = 0;
    // SAFETY: the shim writes at most capacity fixed-layout value records.
    let reason = unsafe { np_corner_displays(rows.as_mut_ptr(), rows.len() as u32, &mut count) };
    if reason != 0 {
        return Err(reason);
    }
    let list = rows.get(..count as usize).ok_or(9u32)?;
    if list.is_empty()
        || list
            .iter()
            .any(|r| r.id == [0; 16] || list.iter().filter(|d| d.id == r.id).count() != 1)
    {
        return Err(9);
    }
    Ok(list.to_vec())
}
pub(super) fn sample(member: &Member) -> Result<Sample, u32> {
    let mut result = Sample::default();
    let reason = unsafe { np_corner_sample(member, &mut result) };
    if reason == 0 { Ok(result) } else { Err(reason) }
}
pub(super) fn zorder() -> Result<(Vec<sliver::Listed>, sliver::DockBar), u32> {
    let mut rows = vec![Row::default(); 2048];
    let mut count = 0;
    let mut dock = Dock::default();
    let reason = unsafe { np_corner_zorder(rows.as_mut_ptr(), rows.len() as u32, &mut count, &mut dock) };
    if reason != 0 {
        return Err(reason);
    }
    let list = rows.get(..count as usize).ok_or(14u32)?;
    let bars = dock.bars.get(..dock.count as usize).ok_or(12u32)?;
    Ok((
        list.iter()
            .map(|r| sliver::Listed {
                id: r.id,
                pid: r.pid,
                bounds: r.frame,
                alpha: r.alpha,
                layer: r.layer,
            })
            .collect(),
        sliver::DockBar {
            pid: Some(dock.pid),
            bars: bars.to_vec(),
        },
    ))
}

/// An AX object is never sent over the ABI or persisted. Only the engine's WM thread owns it.
pub(super) struct Reference(std::ptr::NonNull<c_void>, [u8; 32]);
impl Reference {
    pub fn acquire(id: &Member) -> Result<Self, u32> {
        let signed = fingerprint(id).ok_or(3u32)?;
        std::ptr::NonNull::new(unsafe { np_corner_retain_window(id) })
            .map(|w| Self(w, signed))
            .ok_or(3)
    }
    pub fn matches(&self, id: &Member) -> bool {
        unsafe { np_corner_same_window(id, self.0.as_ptr()) == 1 }
    }
}
impl Drop for Reference {
    fn drop(&mut self) {
        unsafe { np_corner_release_window(self.0.as_ptr()) }
    }
}

pub(super) enum Move<'a> {
    Park(&'a super::tap::Tap),
    Restore,
}

pub(super) fn position(
    id: &Member,
    reference: &Reference,
    before: Rect,
    target: Rect,
    control: &Control,
    input: Inputs,
    purpose: Move<'_>,
) -> (u32, bool) {
    struct Grant<'a> {
        control: &'a Control,
        id: &'a Member,
        signer: [u8; 32],
        input: Inputs,
        tap: Option<&'a super::tap::Tap>,
    }
    extern "C" fn admitted(raw: *mut c_void) -> u32 {
        // The C shim invokes this synchronously after reacquiring both systems' window identity.
        let grant = unsafe { &*raw.cast::<Grant>() };
        (grant.control.guard().is_ok()
            && active_grant(grant.id, grant.signer, grant.control)
            && grant.control.may_write()
            && grant.tap.is_none_or(|tap| tap.health().is_ok())
            && inputs() == grant.input) as u32
    }
    let (op, tap) = match purpose {
        Move::Park(tap) => (1, Some(tap)),
        Move::Restore => (2, None),
    };
    let mut context = Grant {
        control,
        id,
        signer: reference.1,
        input,
        tap,
    };
    let mut issued = 0;
    let reason = unsafe {
        np_corner_position(
            id,
            reference.0.as_ptr(),
            before,
            target,
            op,
            admitted,
            (&mut context as *mut Grant).cast(),
            &mut issued,
        )
    };
    (reason, issued != 0)
}
