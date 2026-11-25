//! Observe native stage minimization. Apple's WindowManager and the owning app
//! retain the shortcut, button, Dock animation and window. Returning a change
//! only asks the Host to reread the arrangement.

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Window {
    pub pid: i32,
    pub window: u32,
    pub birth: u64,
}

const MINIATURIZED: u32 = 1;
const DEMINIATURIZED: u32 = 2;
const SNAPSHOT: u32 = 3;
const NORMAL: u32 = 1;
const MINIMIZED: u32 = 2;
const APPLE_MANAGED: u32 = 1;

/// Receives just the registered identity, the independent AX read and its
/// notification kind. Unknown, contradictory and duplicate changes do not
/// invalidate the mirror. The Host also takes periodic WindowServer reads.
#[unsafe(no_mangle)]
pub extern "C" fn np_apple_native_minimize_change_v1(
    event: u32,
    registered: Window,
    current: Window,
    previous: u32,
    observed: u32,
    scope: u32,
) -> u32 {
    if scope != APPLE_MANAGED
        || registered.pid <= 1
        || registered.birth == 0
        || registered.window == 0
        || current != registered
        || previous > MINIMIZED
        || previous == observed
    {
        return 0;
    }
    match (event, observed) {
        (MINIATURIZED | SNAPSHOT, MINIMIZED) => 1,
        (DEMINIATURIZED | SNAPSHOT, NORMAL) => 2,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: Window = Window {
        pid: 45,
        window: 103,
        birth: 91_220,
    };

    #[test]
    fn the_ax_event_must_match_the_live_attribute() {
        let change = |event, prev, state| {
            np_apple_native_minimize_change_v1(event, W, W, prev, state, APPLE_MANAGED)
        };
        assert_eq!(change(MINIATURIZED, NORMAL, MINIMIZED), 1);
        assert_eq!(change(DEMINIATURIZED, MINIMIZED, NORMAL), 2);
        assert_eq!(change(MINIATURIZED, 0, MINIMIZED), 1);
        assert_eq!(change(MINIATURIZED, 0, NORMAL), 0);
        assert_eq!(change(DEMINIATURIZED, 0, MINIMIZED), 0);
        assert_eq!(change(MINIATURIZED, NORMAL, 0), 0);
        assert_eq!(change(DEMINIATURIZED, MINIMIZED, 3), 0);
        assert_eq!(change(SNAPSHOT, MINIMIZED, MINIMIZED), 0);
        assert_eq!(change(SNAPSHOT, NORMAL, MINIMIZED), 1);
        assert_eq!(change(SNAPSHOT, MINIMIZED, NORMAL), 2);
    }

    #[test]
    fn a_recycled_pid_number_or_non_native_route_cannot_claim_the_event() {
        for other in [
            Window { pid: 46, ..W },
            Window { birth: 1, ..W },
            Window { window: 102, ..W },
        ] {
            assert_eq!(
                np_apple_native_minimize_change_v1(
                    MINIATURIZED,
                    W,
                    other,
                    0,
                    MINIMIZED,
                    APPLE_MANAGED
                ),
                0
            );
        }
        for scope in [0, 2, u32::MAX] {
            assert_eq!(
                np_apple_native_minimize_change_v1(MINIATURIZED, W, W, NORMAL, MINIMIZED, scope),
                0
            );
        }
        for event in [0, 4, u32::MAX] {
            assert_eq!(
                np_apple_native_minimize_change_v1(event, W, W, NORMAL, MINIMIZED, APPLE_MANAGED),
                0
            );
        }
    }
}
