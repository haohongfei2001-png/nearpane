//! Nearpane's C ABI. An accepted submission owns a ticket until the caller polls its terminal
//! receipt. Swift owns all durable group state. No AX, CF or Rust-owned object crosses the ABI.
pub mod contract;
#[cfg(feature = "corner")]
mod corner;
mod runtime;
#[cfg(feature = "spaces")]
mod spaces;

// Optional backend builds expose the same ABI and never dereference caller storage here.
#[cfg(not(all(feature = "spaces", target_os = "macos")))]
#[unsafe(no_mangle)]
pub extern "C" fn np_spaces_installed_fixture_cycle(
    _nonce: *const u8,
    _receipt: *mut std::ffi::c_void,
) -> i32 {
    -1
}
#[cfg(not(all(feature = "spaces", target_os = "macos")))]
#[unsafe(no_mangle)]
pub extern "C" fn np_spaces_installed_canary(
    _nonce: *const u8,
    _receipt: *mut std::ffi::c_void,
) -> i32 {
    -1
}

use contract::*;
use runtime::*;
use std::{
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

struct Handle {
    worker: Arc<Session>,
    writable: bool,
}
static REGISTRY: OnceLock<Mutex<HashMap<u64, Handle>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn registry() -> &'static Mutex<HashMap<u64, Handle>> {
    REGISTRY.get_or_init(Default::default)
}
fn find(handle: u64) -> Result<Arc<Session>, u32> {
    lock(registry())
        .get(&handle)
        .map(|h| h.worker.clone())
        .ok_or(CLOSED)
}
fn boundary(action: impl FnOnce() -> Result<(), u32>) -> u32 {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(())) => OK,
        Ok(Err(code)) => code,
        Err(_) => INTERNAL,
    }
}
// The caller guarantees readable/writable storage of at least its declared length.
// Inspect only the common two-word prefix until that contract is validated.
unsafe fn header<T>(p: *const T) -> Result<(), u32> {
    if p.is_null() || !p.is_aligned() {
        return Err(INVALID);
    }
    let words = p.cast::<u32>();
    if unsafe { words.read() } < size_of::<T>() as u32 || unsafe { words.add(1).read() } != ABI {
        return Err(INCOMPATIBLE);
    }
    Ok(())
}
fn output<T>(p: *mut T) -> Result<(), u32> {
    if p.is_null() || !p.is_aligned() {
        Err(INVALID)
    } else {
        Ok(())
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn np_engine_version() -> u32 {
    ABI
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_create(config: *const Config, out: *mut u64) -> u32 {
    boundary(|| {
        output(out)?;
        unsafe {
            out.write(0);
            header(config)?
        };
        let config = unsafe { config.read() };
        if !config.valid() {
            return Err(INVALID);
        }
        let id = create_session(config, None)?;
        unsafe { out.write(id) };
        Ok(())
    })
}
fn create_session(config: Config, qualified: Option<Grant>) -> Result<u64, u32> {
    let mut map = lock(registry());
    let writable = config.mode != 0 || qualified.is_some();
    if map.len() >= 32 || (writable && map.values().any(|h| h.writable)) {
        return Err(BUSY);
    }
    let id = next(&NEXT)?;
    map.insert(
        id,
        Handle {
            worker: Arc::new(Session::create(config, qualified)?),
            writable,
        },
    );
    Ok(id)
}

// Only reviewed physical evidence IDs belong here. The signed Swift Host authenticates the
// detached measurement and matches its final CDHash, system, display and consent before calling.
// A Host digest never needs to be embedded into the very binary it identifies.
#[derive(Clone, Copy)]
struct Grant {
    backend: u32,
    evidence: [u8; 16],
    spaces_route: Option<u32>,
}
const REVIEWED: &[Grant] = &[];
fn reviewed(backend: u32, evidence: [u8; 16]) -> Option<Grant> {
    REVIEWED.iter().copied().find(|g| {
        g.backend == backend
            && g.evidence == evidence
            && matches!(
                (g.backend, g.spaces_route),
                (CORNER, None) | (SPACES, Some(1 | 2))
            )
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_evidence_is_reviewed(backend: u32, evidence: *const u8) -> bool {
    !evidence.is_null()
        && reviewed(backend, unsafe { evidence.cast::<[u8; 16]>().read() }).is_some()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_create_qualified(
    backend: u32,
    evidence: *const u8,
    out: *mut u64,
) -> u32 {
    boundary(|| {
        output(out)?;
        unsafe { out.write(0) };
        if evidence.is_null() || !matches!(backend, CORNER | SPACES) {
            return Err(INVALID);
        }
        let id = unsafe { evidence.cast::<[u8; 16]>().read() };
        let grant = reviewed(backend, id).ok_or(INCOMPATIBLE)?;
        let config = Config {
            size: size_of::<Config>() as u32,
            version: ABI,
            mode: 0,
            process_count: 0,
            processes: [Process::default(); 2],
        };
        let handle = create_session(config, Some(grant))?;
        unsafe { out.write(handle) };
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_epoch(handle: u64, out: *mut u64) -> u32 {
    boundary(|| {
        output(out)?;
        unsafe { out.write(find(handle)?.epoch.load(Ordering::Acquire)) };
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_submit(
    handle: u64,
    request: *const Request,
    out: *mut u64,
) -> u32 {
    boundary(|| {
        output(out)?;
        unsafe {
            out.write(0);
            header(request)?
        };
        let id = find(handle)?.submit(unsafe { request.read() })?;
        unsafe { out.write(id) };
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_fence_unsubmitted_corner_hide(
    handle: u64,
    request: *const Request,
) -> u32 {
    boundary(|| {
        unsafe { header(request)? };
        find(handle)?.fence_unsubmitted_corner_hide(unsafe { request.read() })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_engine_poll(handle: u64, ticket: u64, receipt: *mut Receipt) -> u32 {
    boundary(|| {
        unsafe { header(receipt)? };
        let r = find(handle)?.poll(ticket)?;
        unsafe { receipt.write(r) };
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn np_engine_cancel(handle: u64, ticket: u64) -> u32 {
    boundary(|| find(handle)?.cancel(ticket))
}
#[unsafe(no_mangle)]
pub extern "C" fn np_engine_revoke(handle: u64) -> u32 {
    boundary(|| next(&find(handle)?.epoch).map(|_| ()))
}
#[unsafe(no_mangle)]
pub extern "C" fn np_engine_destroy(handle: u64) -> u32 {
    boundary(|| {
        let mut map = lock(registry());
        map.get(&handle).ok_or(CLOSED)?.worker.close()?;
        map.remove(&handle);
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn versioned_layout() {
        assert_eq!(
            (
                size_of::<Config>(),
                size_of::<Request>(),
                size_of::<Receipt>()
            ),
            (48, 232, 96)
        );
        assert_eq!(std::mem::offset_of!(Request, birth), 144);
        assert_eq!(std::mem::offset_of!(Receipt, frame), 64);
    }
    #[test]
    fn panic_is_terminal_without_unwinding() {
        assert_eq!(boundary(|| panic!("test panic")), INTERNAL);
    }
    #[test]
    fn rejects_invalid_buffers_and_caps_fixture_authority() {
        let mut handle = 7;
        assert_eq!(
            unsafe { np_engine_create(std::ptr::null(), &mut handle) },
            INVALID
        );
        assert_eq!(handle, 0);
        let mut cfg = Config {
            size: 48,
            version: 99,
            mode: 0,
            process_count: 0,
            processes: [Process::default(); 2],
        };
        assert_eq!(unsafe { np_engine_create(&cfg, &mut handle) }, INCOMPATIBLE);
        cfg.version = ABI;
        cfg.mode = 1;
        assert_eq!(unsafe { np_engine_create(&cfg, &mut handle) }, INVALID);
        assert_eq!(np_engine_destroy(0), CLOSED);
    }
    #[test]
    fn serial_ticket_retains_result_and_never_reuses_closed_handle() {
        let cfg = Config {
            size: 48,
            version: ABI,
            mode: 0,
            process_count: 0,
            processes: [Process::default(); 2],
        };
        let mut h = 0;
        assert_eq!(unsafe { np_engine_create(&cfg, &mut h) }, OK);
        let mut r = Request {
            size: size_of::<Request>() as u32,
            version: ABI,
            intent: [1; 16],
            epoch: 1,
            operation: HEALTH,
            backend: CORNER,
            timeout_ms: 800,
            ..Default::default()
        };
        let mut ticket = 0;
        assert_eq!(unsafe { np_engine_submit(h, &r, &mut ticket) }, OK);
        assert_eq!(np_engine_destroy(h), BUSY);
        let mut receipt = Receipt::default();
        assert_eq!(
            unsafe { np_engine_poll(h, ticket, &mut receipt) },
            INCOMPATIBLE
        );
        receipt.size = size_of::<Receipt>() as u32;
        receipt.version = ABI;
        for _ in 0..1000 {
            let code = unsafe { np_engine_poll(h, ticket, &mut receipt) };
            if code == OK {
                break;
            }
            assert_eq!(code, PENDING);
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(receipt.intent, r.intent);
        assert_eq!(
            unsafe { np_engine_poll(h, ticket, &mut receipt) },
            NO_TICKET
        );
        assert_eq!(np_engine_revoke(h), OK);
        assert_eq!(unsafe { np_engine_submit(h, &r, &mut ticket) }, INVALID);
        r.epoch = 2;
        r.operation = HIDE;
        assert_eq!(unsafe { np_engine_submit(h, &r, &mut ticket) }, INVALID);
        assert_eq!(np_engine_destroy(h), OK);
        assert_eq!(np_engine_destroy(h), CLOSED);
    }
}
