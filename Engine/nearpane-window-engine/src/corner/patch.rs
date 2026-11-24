// Adapted from stage-manager, copyright (c) 2026 Eugene Tiutiunnyk. See LICENSE-MIT.
//! Optional patch geometry and Z-order proof on the independent listed slivers.
use super::geometry::Rect;
use std::collections::HashSet;
/// How far (points) a window's shadow reaches past each side of its frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reach {
    /// Past its left edge.
    pub left: f64,
    /// Above its top edge.
    pub top: f64,
    /// Past its right edge.
    pub right: f64,
    /// Below its bottom edge.
    pub bottom: f64,
}

impl Reach {
    /// The same reach on every side (`[windows] corner_patch_reach` set to a number).
    pub const fn even(r: f64) -> Self {
        Self {
            left: r,
            top: r,
            right: r,
            bottom: r,
        }
    }

    /// Each side kept within 0..=400 pt; a side that is no number takes [`DEFAULT_REACH`]'s.
    pub fn clean(self) -> Self {
        let side = |v: f64, d: f64| if v.is_finite() { v.clamp(0.0, 400.0) } else { d };
        let d = DEFAULT_REACH;
        Self {
            left: side(self.left, d.left),
            top: side(self.top, d.top),
            right: side(self.right, d.right),
            bottom: side(self.bottom, d.bottom),
        }
    }

    /// Each side the larger of the two.
    pub fn max(self, o: Self) -> Self {
        Self {
            left: self.left.max(o.left),
            top: self.top.max(o.top),
            right: self.right.max(o.right),
            bottom: self.bottom.max(o.bottom),
        }
    }

    /// `r` grown by the reach on each side.
    pub fn grow(self, r: Rect) -> Rect {
        Rect::new(
            r.x - self.left,
            r.y - self.top,
            r.w + self.left + self.right,
            r.h + self.top + self.bottom,
        )
    }
}

// An inactive shadow falls downward: least above, most below, the same left and right.
const _: () = assert!(DEFAULT_REACH.top < DEFAULT_REACH.left && DEFAULT_REACH.left < DEFAULT_REACH.bottom);
const _: () = assert!(DEFAULT_REACH.left == DEFAULT_REACH.right);

impl Default for Reach {
    fn default() -> Self {
        DEFAULT_REACH
    }
}

/// The shadow's reach of a parked window, which is inactive (its app not frontmost, never
/// key): `[windows] corner_patch_reach = "auto"`, the default. Measured on the owner's Mac
/// (10-30, `stage-manager probe-shadow`, Studio Display at 2x, a titled and a toolbar window
/// alike): an inactive window's shadow falls downward, so it reaches least above the window
/// and most below it, and it ends there, whatever its alpha. Its whole extent, not where one
/// window's shadow fades under 2/255 (18, 11, 18, 25): parked windows share the corner and
/// their faint tails add up (the owner's 14 showed a darker edge outside an 18 pt patch; 16 stacked
/// probe windows reach 16/255 at the extent, `probe-shadow --stack 16`). The corner that shows
/// of a window parked bottom-right is its top-left.
pub const DEFAULT_REACH: Reach = Reach {
    left: 22.0,
    top: 16.0,
    right: 22.0,
    bottom: 30.0,
};

/// An active window's shadow, the largest (the reach used everywhere before the per-side
/// one, unmeasured): a window macOS raised and activated in the corner during a switch
/// ([`switch_cover`]) may wear it.
pub const ACTIVE_REACH: Reach = Reach::even(60.0);

/// The patch's rectangle: every sliver (`slivers`: parked windows' bounds as listed) that
/// shows on `display`, grown by `reach` on each side (the window's shadow, [`Reach::grow`]),
/// rounded out to whole points (so the picture's crop, whole pixels, is exactly the panel's
/// size), kept on the display. `None` when no sliver shows.
pub fn patch_rect(slivers: &[Rect], display: Rect, reach: Reach) -> Option<Rect> {
    let reach = reach.clean();
    let mut out: Option<Rect> = None;
    for s in slivers.iter().filter_map(|s| s.intersect(&display)) {
        let grown = reach.grow(s);
        out = Some(match out {
            None => grown,
            Some(u) => union(u, grown),
        });
    }
    out.and_then(|r| r.intersect(&display))
        .map(whole_points)
        .and_then(|r| r.intersect(&display))
}

/// `r` grown to whole points on every side.
fn whole_points(r: Rect) -> Rect {
    let (x, y) = (r.x.floor(), r.y.floor());
    Rect::new(x, y, r.max_x().ceil() - x, r.max_y().ceil() - y)
}

/// The rectangle to use: the one in use (`prev`) while it still covers `next` and is at most
/// `slack` bigger on each side (a sliver that came and went), else `next`. The slack is the
/// shadow's reach on that side, so a small patch stays small.
pub fn steady_rect(prev: Option<Rect>, next: Rect, slack: Reach) -> Rect {
    let slack = slack.clean();
    match prev {
        Some(p)
            if p.contains_rect(&next)
                && next.x - p.x <= slack.left
                && next.y - p.y <= slack.top
                && p.max_x() - next.max_x() <= slack.right
                && p.max_y() - next.max_y() <= slack.bottom =>
        {
            p
        }
        _ => next,
    }
}

fn union(a: Rect, b: Rect) -> Rect {
    let x = a.x.min(b.x);
    let y = a.y.min(b.y);
    Rect::new(x, y, a.max_x().max(b.max_x()) - x, a.max_y().max(b.max_y()) - y)
}

/// One window of the window server's on-screen list, front to back, as [`ordered_right`]
/// needs it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Listed {
    /// `CGWindowID`.
    pub id: u32,
    /// Window layer (0: normal windows).
    pub layer: i64,
    /// Bounds, top-left origin.
    pub bounds: Rect,
    /// Drawn (alpha above 0) and another app's (this app's own windows never count).
    pub drawn: bool,
}

impl Listed {
    /// Whether the window counts for the patch at `rect`: a normal window, drawn, another
    /// app's, reaching the rectangle. The one filter for [`ordered_right`],
    /// [`would_be_right`] and [`PatchFacts::shown`] (with the parked ones left out).
    pub fn counts(&self, rect: Rect) -> bool {
        self.layer == 0 && self.drawn && self.bounds.intersect(&rect).is_some()
    }
}

/// True when the patch (`patch`, at `rect`) sits above every parked window (`parked`) that
/// reaches its rectangle and below every other window that does ([`Listed::counts`]): what
/// ordering it relative to the topmost parked window should give. False when the patch is
/// not listed.
pub fn ordered_right(front_to_back: &[Listed], patch: u32, rect: Rect, parked: &HashSet<u32>) -> bool {
    let Some(at) = front_to_back.iter().position(|w| w.id == patch) else {
        return false;
    };
    front_to_back
        .iter()
        .enumerate()
        .filter(|(_, w)| w.id != patch && w.counts(rect))
        .all(|(i, w)| if parked.contains(&w.id) { i > at } else { i < at })
}

/// Whether ordering the patch (`patch`, at `rect`) just above `above` could be right: the
/// list with the patch taken out and put back just above `above`, checked by
/// [`ordered_right`]. False when a shown window reaching the rectangle sits below `above`
/// (or a parked one above it), or `above` is not listed: then no order against `above` is
/// right, and the patch must not show to find out. Only whether macOS honours the order
/// across apps is left for a live show to tell.
pub fn would_be_right(
    front_to_back: &[Listed],
    patch: u32,
    above: u32,
    rect: Rect,
    parked: &HashSet<u32>,
) -> bool {
    let mut list: Vec<Listed> = front_to_back.iter().filter(|w| w.id != patch).copied().collect();
    let Some(at) = list.iter().position(|w| w.id == above) else {
        return false;
    };
    list.insert(
        at,
        Listed {
            id: patch,
            layer: 0,
            bounds: rect,
            drawn: true,
        },
    );
    ordered_right(&list, patch, rect, parked)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipped_stable_patch_never_orders_over_an_active_peer() {
        let screen = Rect::new(0., 0., 1400., 900.);
        let sliver = Rect::new(1399., 820., 320., 200.);
        let patch = patch_rect(&[sliver], screen, DEFAULT_REACH).unwrap();
        assert!(screen.contains_rect(&patch));
        assert!(patch.contains_rect(&screen.intersect(&sliver).unwrap()));
        assert_eq!(steady_rect(Some(patch), patch, DEFAULT_REACH), patch);
        let parked: HashSet<u32> = [99].into_iter().collect();
        let row = |id| Listed {
            id,
            layer: 0,
            bounds: patch,
            drawn: true,
        };
        assert!(would_be_right(&[row(88), row(99)], 77, 99, patch, &parked));
        assert!(!would_be_right(&[row(99), row(88)], 77, 99, patch, &parked));
    }
}

// Private, read-only interface used by the AppKit patch and the independently
// sampled image verifier. It never orders a window or grants a window lease.
#[cfg(target_os = "macos")]
mod native_plan {
    use super::*;
    #[repr(C)]
    pub struct Row {
        id: u32,
        pid: i32,
        frame: Rect,
        alpha: f64,
        layer: i64,
    }
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn np_corner_patch_bounds(
        frames: *const Rect,
        count: u32,
        display: Rect,
        out: *mut Rect,
    ) -> bool {
        if frames.is_null() || out.is_null() || !(1..=64).contains(&count) || display.is_degenerate() {
            return false;
        }
        let frames = unsafe { std::slice::from_raw_parts(frames, count as usize) };
        if frames.iter().any(|r| {
            r.is_degenerate()
                || r.intersect(&display)
                    .is_none_or(|sliver| sliver.w > super::super::park::PARK_SLIVER)
        }) {
            return false;
        }
        let Some(r) = patch_rect(frames, display, DEFAULT_REACH) else {
            return false;
        };
        if r.w > 200. || r.h > 320. {
            return false;
        }
        unsafe { out.write(r) };
        true
    }
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn np_corner_patch_order(
        rows: *const Row,
        length: u32,
        ids: *const u32,
        count: u32,
        patch: u32,
        above: u32,
        frame: Rect,
        preflight: bool,
    ) -> bool {
        if rows.is_null()
            || ids.is_null()
            || !(1..=8192).contains(&length)
            || !(1..=64).contains(&count)
            || patch == 0
            || frame.is_degenerate()
        {
            return false;
        }
        let raw = unsafe { std::slice::from_raw_parts(rows, length as usize) };
        let ids = unsafe { std::slice::from_raw_parts(ids, count as usize) };
        let parked: HashSet<_> = ids.iter().copied().collect();
        if parked.len() != ids.len()
            || parked.contains(&0)
            || parked.contains(&patch)
            || !parked.contains(&above)
        {
            return false;
        }
        let listed: Vec<_> = raw
            .iter()
            .map(|r| Listed {
                id: r.id,
                layer: r.layer,
                bounds: r.frame,
                drawn: r.alpha > 0.,
            })
            .collect();
        let witnesses: Vec<_> = listed.iter().filter(|w| parked.contains(&w.id)).collect();
        if witnesses.len() != parked.len()
            || witnesses.first().map(|w| w.id) != Some(above)
            || witnesses.iter().map(|w| w.id).collect::<HashSet<_>>() != parked
            || !witnesses.iter().all(|w| w.counts(frame))
        {
            return false;
        }
        if preflight {
            would_be_right(&listed, patch, above, frame, &parked)
        } else {
            let mut sheets = raw.iter().filter(|w| w.id == patch);
            sheets.next().is_some_and(|w| w.layer == 0 && w.alpha == 1. && w.frame == frame)
                && sheets.next().is_none() && ordered_right(&listed, patch, frame, &parked)
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn single_and_joint_plans_require_unique_present_slivers_and_a_real_order_anchor() {
            let screen = Rect::new(0., 0., 1000., 800.);
            let parked = Rect::new(999., 770., 440., 320.);
            let mut frame = Rect::default();
            assert!(unsafe { np_corner_patch_bounds(&parked, 1, screen, &mut frame) });
            let r = |id| Row {
                id,
                pid: 11,
                frame,
                alpha: 1.,
                layer: 0,
            };
            let rows = [r(91), r(42), r(7), r(8)];
            let proof = |ids: &[u32], anchor, pre| unsafe {
                np_corner_patch_order(
                    rows.as_ptr(),
                    rows.len() as u32,
                    ids.as_ptr(),
                    ids.len() as u32,
                    42,
                    anchor,
                    frame,
                    pre,
                )
            };
            assert!(proof(&[7, 8], 7, false));
            assert!(proof(&[7, 8], 7, true));
            assert!(!proof(&[7], 7, false)); // Unmanaged window 8 would be covered.
            assert!(!proof(&[7, 7], 7, true));
            assert!(!proof(&[7, 99], 7, true));
            assert!(!proof(&[7, 8], 8, true));
            assert!(unsafe { np_corner_patch_order(rows.as_ptr(), 3, [7].as_ptr(), 1, 42, 7, frame, false) });
            assert!(!unsafe { np_corner_patch_bounds(&screen, 1, screen, &mut frame) });
        }

        #[test]
        fn posted_sheet_needs_its_opaque_windowserver_frame_and_normal_level() {
            let frame = Rect::new(959., 720., 41., 80.);
            let sheet = |alpha, bounds, layer| Row { id: 42, pid: 12, frame: bounds, alpha, layer };
            let observed = |panel| {
                let rows = [panel, Row { id: 7, pid: 11, frame, alpha: 1., layer: 0 }];
                unsafe { np_corner_patch_order(rows.as_ptr(), 2, [7].as_ptr(), 1, 42, 7, frame, false) }
            };
            assert!(observed(sheet(1., frame, 0)));
            assert!(!observed(sheet(0., frame, 0)));
            assert!(!observed(sheet(0.99, frame, 0)));
            assert!(!observed(sheet(1., Rect::new(960., 720., 40., 80.), 0)));
            assert!(!observed(sheet(1., frame, -1)));
        }
    }
}
