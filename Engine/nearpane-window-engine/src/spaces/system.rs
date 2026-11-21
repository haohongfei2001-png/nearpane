//! Fixed-width bindings to the native calls. The worker never sends the retained AX object across the ABI.
use super::*;
#[cfg(target_os = "macos")]
use std::ffi::c_void;

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct WindowRow {
        number: u32,
        pid: i32,
        birth: u64,
        onboard: u32,
        layer: u32,
        rect: [f64; 4],
    }
    unsafe extern "C" {
        fn np_stage_symbols() -> i32;
        fn np_stage_target_build() -> i32;
        #[cfg(feature = "isolated-fixtures")]
        fn np_stage_hosted_self_birth() -> u64;
        #[cfg(feature = "isolated-fixtures")]
        fn np_is_enrolled_fixture(pid: i32, birth: u64) -> bool;
        fn np_stage_connection() -> i32;
        fn np_stage_desktops(c: i32, out: *mut Desktop, n: u32) -> i32;
        fn np_stage_all_spaces(c: i32, out: *mut u64, n: u32) -> i32;
        fn np_stage_membership(c: i32, w: u32, out: *mut u64, n: u32) -> i32;
        fn np_stage_occupants(c: i32, s: u64, out: *mut u64, n: u32) -> i32;
        fn np_stage_window(w: u32, out: *mut WindowRow) -> i32;
        fn np_stage_bind(w: u32, pid: i32, birth: u64) -> *mut c_void;
        fn np_stage_check_bound(
            witness: *mut c_void,
            w: u32,
            pid: i32,
            birth: u64,
            on_screen: u32,
        ) -> i32;
        fn np_stage_release(witness: *mut c_void);
        fn np_stage_create(c: i32, s: *mut u64) -> i32;
        fn np_stage_destroy(c: i32, s: u64) -> i32;
        fn np_stage_move(c: i32, route: u32, w: u32, s: u64, mask: u32) -> i32;
    }
    fn numbers<const N: usize>(read: impl FnOnce(*mut u64, u32) -> i32) -> Check<Rows> {
        let mut data = [0; N];
        let len = usize::try_from(read(data.as_mut_ptr(), N as u32))
            .map_err(|_| unknown(Why::Readback))?;
        let items = data.get(..len).ok_or(unknown(Why::Readback))?;
        let result: Rows = items.iter().copied().collect();
        if result.contains(&0) || result.len() != len {
            return Err(unknown(Why::Readback));
        }
        Ok(result)
    }
    fn delivery(value: i32) -> Delivery {
        match value {
            1 => Delivery::Accepted,
            0 => Delivery::Refused,
            _ => Delivery::Uncertain,
        }
    }
    pub(crate) struct Witness(std::ptr::NonNull<c_void>);
    // The opaque reference is held by one WM worker, never accessed concurrently.
    unsafe impl Send for Witness {}
    impl Drop for Witness {
        fn drop(&mut self) {
            unsafe { np_stage_release(self.0.as_ptr()) }
        }
    }
    impl Platform for System {
        type Witness = Witness;
        fn flags(&self) -> u32 {
            unsafe { np_stage_symbols() as u32 }
        }
        fn target(&self) -> bool {
            if unsafe { np_stage_target_build() == 1 } {
                return true;
            }
            // The ordinary library has no cross-build execution path. A separately
            // compiled, enrolled, disposable hosted fixture can collect comparison data.
            #[cfg(feature = "isolated-fixtures")]
            {
                let birth = unsafe { np_stage_hosted_self_birth() };
                birth != 0 && unsafe { np_is_enrolled_fixture(std::process::id() as i32, birth) }
            }
            #[cfg(not(feature = "isolated-fixtures"))]
            false
        }
        fn connection(&self) -> Check<i32> {
            let c = unsafe { np_stage_connection() };
            if c > 0 {
                Ok(c)
            } else {
                Err(unknown(Why::Connection))
            }
        }
        fn desktops(&self, c: i32) -> Check<Vec<Desktop>> {
            let mut rows = [Desktop::default(); 512];
            let n = unsafe { np_stage_desktops(c, rows.as_mut_ptr(), rows.len() as u32) };
            if n <= 0 || n as usize > rows.len() {
                return Err(unknown(Why::Topology));
            }
            Ok(rows[..n as usize].to_vec())
        }
        fn all(&self, c: i32) -> Check<Rows> {
            numbers::<1024>(|p, n| unsafe { np_stage_all_spaces(c, p, n) })
        }
        fn members(&self, c: i32, space: u64) -> Check<Rows> {
            numbers::<8192>(|p, n| unsafe { np_stage_occupants(c, space, p, n) })
        }
        fn spaces(&self, c: i32, w: u32) -> Check<Rows> {
            numbers::<128>(|p, n| unsafe { np_stage_membership(c, w, p, n) })
        }
        fn bind(&self, w: Window) -> Check<Witness> {
            std::ptr::NonNull::new(unsafe { np_stage_bind(w.number, w.pid, w.birth) })
                .map(Witness)
                .ok_or(unknown(Why::MinimizedOrAX))
        }
        fn see(&self, w: Window, lease: &Witness) -> Check<Seen> {
            let mut row = WindowRow::default();
            if unsafe { np_stage_window(w.number, &mut row) } != 1
                || row.number != w.number
                || row.pid != w.pid
                || row.birth != w.birth
                || row.layer != 1
                || row.onboard > 1
                || unsafe {
                    np_stage_check_bound(lease.0.as_ptr(), w.number, w.pid, w.birth, row.onboard)
                } != 1
            {
                return Err(unknown(Why::Identity));
            }
            Ok(Seen {
                visible: row.onboard == 1,
                rect: row.rect,
            })
        }
        fn create(&mut self, c: i32) -> Check<u64> {
            let mut id = 0;
            let status = unsafe { np_stage_create(c, &mut id) };
            if status == 1 && id > 0 {
                Ok(id)
            } else {
                Err(if status == 0 {
                    fail(Why::NoDelivery)
                } else {
                    unknown(Why::Uncertain)
                })
            }
        }
        fn destroy(&mut self, c: i32, s: u64) -> Delivery {
            delivery(unsafe { np_stage_destroy(c, s) })
        }
        fn move_window(&mut self, c: i32, route: Route, w: Window, s: u64, mask: u32) -> Delivery {
            delivery(unsafe { np_stage_move(c, route as u32, w.number, s, mask) })
        }
    }
}
pub(super) struct System;
#[cfg(not(target_os = "macos"))]
impl Platform for System {
    type Witness = ();
    fn flags(&self) -> u32 {
        0
    }
    fn target(&self) -> bool {
        false
    }
    fn connection(&self) -> Check<i32> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn desktops(&self, _: i32) -> Check<Vec<Desktop>> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn all(&self, _: i32) -> Check<Rows> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn members(&self, _: i32, _: u64) -> Check<Rows> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn spaces(&self, _: i32, _: u32) -> Check<Rows> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn bind(&self, _: Window) -> Check<()> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn see(&self, _: Window, _: &()) -> Check<Seen> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn create(&mut self, _: i32) -> Check<u64> {
        Err(Fault(UNSUPPORTED, Why::Build))
    }
    fn destroy(&mut self, _: i32, _: u64) -> Delivery {
        Delivery::Refused
    }
    fn move_window(&mut self, _: i32, _: Route, _: Window, _: u64, _: u32) -> Delivery {
        Delivery::Refused
    }
}
