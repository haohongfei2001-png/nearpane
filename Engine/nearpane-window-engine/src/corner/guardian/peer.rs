// One kernel watch per qualified HIDE ticket. The setter rechecks it after queueing and AX lookup.
use std::sync::{Arc, OnceLock};
#[cfg(all(target_os = "macos", feature = "corner"))]
use std::{
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    sync::atomic::{AtomicBool, Ordering},
};

#[cfg(all(target_os = "macos", feature = "corner"))]
unsafe extern "C" {
    fn np_corner_open_guardian_peer(child: i32, birth: u64) -> i32;
    fn np_corner_guardian_peer_live(queue: i32, child: i32, birth: u64) -> bool;
    fn np_corner_copy_measurement_writer(fd: i32) -> i32;
    fn np_corner_send_measurement(
        fd: i32,
        request: *const super::Request,
        frame: super::Rect,
        owned: u32,
    ) -> bool;
}

#[cfg(all(target_os = "macos", feature = "corner"))]
pub(crate) struct GuardianPeer {
    queue: OwnedFd,
    writer: OwnedFd,
    child: i32,
    birth: u64,
    lost: AtomicBool,
    // Each authenticated HIDE has its own publication, shared only with its ticket
    // and the return witness retained by the worker for this window.
    hide_published: Arc<OnceLock<()>>,
}

#[cfg(all(target_os = "macos", feature = "corner"))]
impl GuardianPeer {
    pub(crate) fn open(child: i32, birth: u64, pipe: i32) -> Option<Self> {
        let fd = unsafe { np_corner_open_guardian_peer(child, birth) };
        if fd < 0 {
            return None;
        }
        let queue = unsafe { OwnedFd::from_raw_fd(fd) };
        let fd = unsafe { np_corner_copy_measurement_writer(pipe) };
        (fd >= 0).then(|| Self {
            queue,
            writer: unsafe { OwnedFd::from_raw_fd(fd) },
            child,
            birth,
            lost: AtomicBool::new(false),
            hide_published: Default::default(),
        })
    }
    pub(crate) fn hide_publication(&self) -> &Arc<OnceLock<()>> {
        &self.hide_published
    }
    pub(crate) fn measured(&self, r: &super::Request, frame: super::Rect, owned: u32) -> bool {
        self.live()
            && unsafe { np_corner_send_measurement(self.writer.as_raw_fd(), r, frame, owned) }
    }
    pub(crate) fn live(&self) -> bool {
        if !self.lost.load(Ordering::Acquire)
            && !unsafe {
                np_corner_guardian_peer_live(self.queue.as_raw_fd(), self.child, self.birth)
            }
        {
            self.lost.store(true, Ordering::Release);
        }
        !self.lost.load(Ordering::Acquire)
    }
}

#[cfg(not(all(target_os = "macos", feature = "corner")))]
pub(crate) enum GuardianPeer {}
#[cfg(not(all(target_os = "macos", feature = "corner")))]
impl GuardianPeer {
    pub(crate) fn open(_: i32, _: u64, _: i32) -> Option<Self> {
        None
    }
    pub(crate) fn hide_publication(&self) -> &Arc<OnceLock<()>> {
        match *self {}
    }
    pub(crate) fn measured(&self, _: &super::Request, _: super::Rect, _: u32) -> bool {
        match *self {}
    }
    pub(crate) fn live(&self) -> bool {
        match *self {}
    }
}
