// MIT adaptations of the pinned upstream points, perspective, plan and shift_click route.
// See upstream.json. Nearpane requires independent, fresh AX membership and an exact CG twin.
use super::{
    CLOSED, INTERNAL, INVALID, Input, Listed, REGISTRY, Rect, STALE, UNAVAILABLE, VERSION, ffi,
    header_matches, pointer, slice,
};
use std::collections::BTreeSet;

pub(super) struct Snapshot {
    display: Rect,
    manager: i32,
    listed: Vec<Listed>,
    current: BTreeSet<u32>,
    strip: Vec<BTreeSet<u32>>,
}
impl Snapshot {
    pub(super) fn new(
        i: &Input,
        listed: &[Listed],
        current: &[u32],
        ax: &[super::AxMember],
    ) -> Self {
        let mut strip = std::collections::BTreeMap::<u32, BTreeSet<u32>>::new();
        for row in ax {
            strip.entry(row.item).or_default().insert(row.window);
        }
        Self {
            display: i.display_frame,
            manager: i.manager_pid,
            listed: listed.to_vec(),
            current: current.iter().copied().collect(),
            strip: strip.into_values().collect(),
        }
    }
    fn point(
        &self,
        source: &BTreeSet<u32>,
        dest: &BTreeSet<u32>,
        visible: Rect,
    ) -> Option<PointResult> {
        if self.current != *dest
            || !self.strip.contains(source)
            || !source.is_disjoint(dest)
            || !contains(self.display, visible)
        {
            return None;
        }
        // Apple's source item's front thumbnail is the only clickable member,
        // even if part of a second thumbnail remains visible behind it.
        let index = self
            .listed
            .iter()
            .position(|r| source.contains(&r.window))?;
        let window = self.listed.get(index)?;
        let twin = self.listed.get(index.checked_sub(1)?)?;
        if window.onscreen != 1
            || window.layer != 0
            || window.pid == self.manager
            || twin.onscreen != 1
            || twin.layer != 0
            || twin.pid != self.manager
            || !super::mirror::same(twin.frame, window.frame)
            || window.frame.width > 240.
            || window.frame.height > 240.
        {
            return None;
        }
        let own = plane(window.frame, visible, self.display)?;
        // Every earlier on-screen row is a possible cover, including system layers
        // and full icon windows. Conservative box rejection may cost a merge, never a click.
        let mut covers = Vec::new();
        for r in &self.listed[..index - 1] {
            if r.onscreen == 0 || !r.frame.valid() {
                continue;
            }
            let pad = 3.0 + 0.055 * r.frame.width.max(r.frame.height).min(240.);
            let edge = Rect {
                x: r.frame.x - pad,
                y: r.frame.y - pad,
                width: r.frame.width + 2. * pad,
                height: r.frame.height + 2. * pad,
            };
            if super::grouping::overlap(&window.frame, &edge) > 0. {
                covers.push(edge);
            }
            if covers.len() > 128 {
                return None;
            }
        }
        // Interior samples of the actual projected plane, 6pt clear of its edges.
        // Try the center first, then bounded points. A covered point is always discarded.
        for v in [0.5, 0.35, 0.65, 0.2, 0.8] {
            for u in [0.5, 0.35, 0.65, 0.2, 0.8] {
                let lo = lerp(own[0], own[1], u);
                let hi = lerp(own[3], own[2], u);
                let p = lerp(lo, hi, v);
                if depth(&own, p) < 6.
                    || !inset_contains(self.display, p, 2.)
                    || covers.iter().any(|r| inset_contains(*r, p, 0.))
                {
                    continue;
                }
                return Some(PointResult {
                    size: size_of::<PointResult>() as u32,
                    version: VERSION,
                    window: window.window,
                    twin: twin.window,
                    manager_pid: self.manager,
                    reserved: 0,
                    x: p.0,
                    y: p.1,
                });
            }
        }
        None
    }
}

type Point = (f64, f64);
fn lerp(a: Point, b: Point, t: f64) -> Point {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
}
fn contains(a: Rect, b: Rect) -> bool {
    b.valid()
        && b.x >= a.x
        && b.y >= a.y
        && b.x + b.width <= a.x + a.width
        && b.y + b.height <= a.y + a.height
}
fn inset_contains(r: Rect, p: Point, pad: f64) -> bool {
    p.0 >= r.x + pad
        && p.0 <= r.x + r.width - pad
        && p.1 >= r.y + pad
        && p.1 <= r.y + r.height - pad
}
fn depth(q: &[Point; 4], p: Point) -> f64 {
    (0..4)
        .map(|i| {
            let a = q[i];
            let b = q[(i + 1) % 4];
            let dx = b.0 - a.0;
            let dy = b.1 - a.1;
            (dx * (p.1 - a.1) - dy * (p.0 - a.0)) / dx.hypot(dy).max(f64::EPSILON)
        })
        .fold(f64::INFINITY, f64::min)
}
// Upstream View::apples, plane_of and project. Inverting the projected far x
// yields the original width analytically; infeasible planes yield no target.
fn plane(r: Rect, visible: Rect, screen: Rect) -> Option<[Point; 4]> {
    if !r.valid() {
        return None;
    }
    let t = ((visible.width - 1800.) / 760.).clamp(0., 1.);
    let angle = (44.2 + 3.7 * t).to_radians();
    let distance = 1346. + 914. * t;
    let ex = visible.x + 15.;
    let ey = screen.y + screen.height * 0.5;
    let denominator = distance * angle.cos() - (r.x + r.width - ex) * angle.sin();
    if denominator <= 0. {
        return None;
    }
    let width = r.width * distance / denominator;
    if !width.is_finite() || width > 8. * distance {
        return None;
    }
    let ratio = distance / (distance + width * angle.sin());
    let top = if r.y <= ey {
        r.y
    } else {
        ey + (r.y - ey) / ratio
    };
    let max = r.y + r.height;
    let bottom = if max >= ey {
        max
    } else {
        ey + (max - ey) / ratio
    };
    if bottom <= top {
        return None;
    }
    Some([
        (r.x, top),
        (r.x + r.width, ey + (top - ey) * ratio),
        (r.x + r.width, ey + (bottom - ey) * ratio),
        (r.x, bottom),
    ])
}

#[repr(C)]
pub struct Request {
    size: u32,
    version: u32,
    sample_time_ns: u64,
    visible_frame: Rect,
    source_count: u32,
    destination_count: u32,
    source: *const u32,
    destination: *const u32,
}
#[derive(Default)]
#[repr(C)]
pub struct PointResult {
    size: u32,
    version: u32,
    window: u32,
    twin: u32,
    manager_pid: i32,
    reserved: u32,
    x: f64,
    y: f64,
}

/// Both ID arrays must be valid, aligned, disjoint from output and exact observed membership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn np_apple_merge_point_v1(
    handle: u64,
    request: *const Request,
    out: *mut PointResult,
) -> u32 {
    ffi(|| {
        if !pointer(request)
            || !pointer(out)
            || !unsafe { header_matches(request) && header_matches(out.cast_const()) }
        {
            return Err(INVALID);
        }
        let r = unsafe { &*request };
        unsafe {
            out.write(PointResult {
                size: size_of::<PointResult>() as u32,
                version: VERSION,
                ..PointResult::default()
            });
        }
        if r.sample_time_ns == 0 || !r.visible_frame.valid() {
            return Err(INVALID);
        }
        let exact = |p: *const u32, n: u32| -> Result<BTreeSet<u32>, u32> {
            let ids = unsafe { slice(p, n, 1024)? };
            let unique = ids.iter().copied().collect::<BTreeSet<_>>();
            if ids.is_empty() || ids.len() != unique.len() || unique.contains(&0) {
                return Err(INVALID);
            }
            Ok(unique)
        };
        let source = exact(r.source, r.source_count)?;
        let destination = exact(r.destination, r.destination_count)?;
        let registry = REGISTRY.lock().map_err(|_| INTERNAL)?;
        let state = &registry.sessions.get(&handle).ok_or(CLOSED)?.state;
        if r.sample_time_ns != state.time {
            return Err(STALE);
        }
        let point = state
            .merge
            .as_ref()
            .and_then(|s| s.point(&source, &destination, r.visible_frame))
            .ok_or(UNAVAILABLE)?;
        unsafe {
            out.write(point);
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::apple::{
        AxMember,
        tests::{Reader, rect, row, sample, scene, scope},
    };

    #[test]
    fn request_requires_current_ax_exact_partition_fresh_mirror_and_clickable_front() {
        let s = scope(1, 4);
        let h = Reader::new(s);
        let rows = scene();
        let source = [2u32, 3];
        let dest = [1u32];
        let managed = [1u32, 2, 3, 4];
        let ax = [
            AxMember {
                item: 0,
                window: 2,
                frame: rows[1].frame,
            },
            AxMember {
                item: 0,
                window: 3,
                frame: rows[1].frame,
            },
            AxMember {
                item: 1,
                window: 4,
                frame: rows[5].frame,
            },
        ];
        let visible = rect(0., 32., 1600., 968.);
        let query = |time, ids: &[u32], dest: &[u32]| {
            let req = Request {
                size: size_of::<Request>() as u32,
                version: 1,
                sample_time_ns: time,
                visible_frame: visible,
                source: ids.as_ptr(),
                source_count: ids.len() as u32,
                destination: dest.as_ptr(),
                destination_count: dest.len() as u32,
            };
            let mut p = PointResult {
                size: size_of::<PointResult>() as u32,
                version: 1,
                ..PointResult::default()
            };
            let res = unsafe { np_apple_merge_point_v1(h.0, &req, &mut p) };
            (res, p)
        };
        let read = |time, rows: &[Listed], ax: &[AxMember]| {
            let mut i = sample(s, time);
            i.ax_available = 1;
            h.read(i, rows, &managed, ax, 4).0
        };
        assert_eq!(read(1, &rows, &ax), 0);
        assert_eq!(query(1, &source, &dest).0, UNAVAILABLE);
        assert_eq!(read(2, &rows, &ax), 0);
        let (status, p) = query(2, &source, &dest);
        assert_eq!((status, p.window, p.twin, p.manager_pid), (0, 2, 101, 99));
        assert_eq!(query(1, &source, &dest).0, STALE);
        assert_eq!(query(2, &source, &[4]).0, UNAVAILABLE);
        assert_eq!(query(2, &[3], &dest).0, UNAVAILABLE);
        assert_eq!(read(3, &rows, &[]), 0);
        assert_eq!(query(3, &source, &dest).0, UNAVAILABLE);
        let mut mixed = ax.to_vec();
        mixed.push(AxMember {
            item: 0,
            window: 800,
            frame: rows[1].frame,
        });
        assert_eq!(read(4, &rows, &mixed), 0);
        assert_eq!(query(4, &source, &dest).0, UNAVAILABLE);
        let mut covered = rows.clone();
        covered.insert(
            0,
            Listed {
                layer: 5,
                ..row(399, 550, rows[1].frame)
            },
        );
        assert_eq!(read(5, &covered, &ax), 0);
        assert_eq!(query(5, &source, &dest).0, UNAVAILABLE);
    }
}
