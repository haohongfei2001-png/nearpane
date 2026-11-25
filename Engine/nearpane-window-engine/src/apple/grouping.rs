// Adapted from eugene-tea/stage-manager. Copyright (c) 2026 Eugene Tiutiunnyk.
// SPDX-License-Identifier: MIT. Original file and blob are recorded in upstream.json.
use super::{Group, Rect};

pub(super) fn union(a: Rect, b: Rect) -> Rect {
    let x = a.x.min(b.x);
    let y = a.y.min(b.y);
    Rect {
        x,
        y,
        width: (a.x + a.width).max(b.x + b.width) - x,
        height: (a.y + a.height).max(b.y + b.height) - y,
    }
}

pub(super) fn overlap(a: &Rect, b: &Rect) -> f64 {
    let width = (a.x + a.width).min(b.x + b.width) - a.x.max(b.x);
    let height = (a.y + a.height).min(b.y + b.height) - a.y.max(b.y);
    width.max(0.0) * height.max(0.0)
}

/// The strip's items from its thumbnails (`thumbs`, front to back) and WindowManager's icon
/// windows (`icons`): thumbnails that overlap, directly or through another, make one item (a
/// stage's windows are drawn stacked; a stage of two apps has two icons, so the icon nearest a
/// thumbnail says nothing of its stage: live 11-16); each item's frame takes in the icons that
/// overlap its thumbnails most. Top to bottom.
pub(super) fn items(thumbs: &[(u32, Rect)], icons: &[Rect]) -> Vec<Group> {
    let mut groups: Vec<(Group, Rect)> = Vec::new();
    for (id, b) in thumbs {
        let joined: Vec<usize> = groups
            .iter()
            .enumerate()
            .filter(|(_, (_, t))| overlap(t, b) > 0.0)
            .map(|(i, _)| i)
            .collect();
        match joined.as_slice() {
            [] => groups.push((
                Group {
                    windows: vec![*id],
                    frame: *b,
                },
                *b,
            )),
            [first, rest @ ..] => {
                let first = *first;
                for &i in rest.iter().rev() {
                    let (g, t) = groups.remove(i);
                    groups[first].0.windows.extend(g.windows);
                    groups[first].1 = union(groups[first].1, t);
                }
                groups[first].0.windows.push(*id);
                groups[first].1 = union(groups[first].1, *b);
            }
        }
    }
    let mut out: Vec<Group> = groups
        .into_iter()
        .map(|(mut g, t)| {
            g.frame = t;
            g
        })
        .collect();
    for icon in icons {
        let best = out
            .iter()
            .enumerate()
            .map(|(i, g)| (i, overlap(&g.frame, icon)))
            .filter(|(_, a)| *a > 0.0)
            .max_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((i, _)) = best {
            out[i].frame = union(out[i].frame, *icon);
        }
    }
    out.sort_by(|a, b| a.frame.y.total_cmp(&b.frame.y));
    out
}

/// Windows Apple draws no thumbnail of (`hidden`: managed, listed off screen, thumbnail-sized,
/// on this screen) put in the strip item whose thumbnails they lie within, at its back (module
/// docs). One within no item is left out (a stage past the strip's room, or a window shown
/// nowhere).
pub(super) fn undrawn(strip: &mut [Group], hidden: &[(u32, Rect)]) {
    for (id, b) in hidden {
        if let Some(g) = strip
            .iter_mut()
            .filter(|g| overlap(&g.frame, b) > 0.0)
            .max_by(|x, y| overlap(&x.frame, b).total_cmp(&overlap(&y.frame, b)))
        {
            g.windows.push(*id);
        }
    }
}
