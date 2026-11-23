// One kernel watch per qualified HIDE ticket. The setter rechecks it after queueing and AX lookup.
#[cfg(all(target_os = "macos", feature = "corner"))]
use std::{
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    sync::atomic::{AtomicBool, Ordering},
};

#[cfg(all(target_os = "macos", feature = "corner"))]
unsafe extern "C" {
    fn np_corner_open_guardian_peer(child: i32, birth: u64) -> i32;
    fn np_corner_guardian_peer_live(queue: i32, child: i32, birth: u64) -> bool;
}

#[cfg(all(target_os = "macos", feature = "corner"))]
pub(crate) struct GuardianPeer {
    queue: OwnedFd,
    child: i32,
    birth: u64,
    lost: AtomicBool,
}

#[cfg(all(target_os = "macos", feature = "corner"))]
impl GuardianPeer {
    pub(crate) fn open(child: i32, birth: u64) -> Option<Self> {
        let fd = unsafe { np_corner_open_guardian_peer(child, birth) };
        (fd >= 0).then(|| Self {
            // The successful native call transfers this unique close-on-exec descriptor.
            queue: unsafe { OwnedFd::from_raw_fd(fd) },
            child,
            birth,
            lost: AtomicBool::new(false),
        })
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
    pub(crate) fn open(_: i32, _: u64) -> Option<Self> {
        None
    }
    pub(crate) fn live(&self) -> bool {
        match *self {}
    }
}
