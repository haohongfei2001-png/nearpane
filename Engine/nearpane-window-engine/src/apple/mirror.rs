// Adapted from eugene-tea/stage-manager, Copyright (c) 2026 Eugene Tiutiunnyk.
// SPDX-License-Identifier: MIT. See upstream.json for pinned sources and local changes.
use super::grouping::{items, overlap, undrawn, union};
use super::{
    AxMember, CURRENT, Group, INVALID, Input, Listed, Member, REMEMBERED, Rect, ResultInfo, STRIP,
};
use std::collections::{BTreeMap, BTreeSet};

const SETTLE_NS: u64 = 700_000_000;
const AX_TRUST_NS: u64 = 1_000_000_000;

#[derive(Clone, Copy)]
struct Seen {
    pid: i32,
    frame: Rect,
    kind: Kind,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Current,
    Thumbnail,
    Undrawn,
    Away,
}

#[derive(Default)]
struct Observation {
    seen: BTreeMap<u32, Seen>,
    current: Option<Group>,
    strip: Vec<Group>,
    strip_shown: Option<bool>,
}

pub(super) fn same(a: Rect, b: Rect) -> bool {
    (a.x - b.x).abs() <= 1.0
        && (a.y - b.y).abs() <= 1.0
        && (a.width - b.width).abs() <= 1.0
        && (a.height - b.height).abs() <= 1.0
}

impl Observation {
    fn new(i: &Input, listed: &[Listed], managed: &BTreeSet<u32>) -> Result<Self, u32> {
        let screen = i.display_frame;
        let mut o = Self::default();
        let mut first = BTreeMap::new();
        let mut thumbs = Vec::new();
        let mut icons = Vec::new();
        let mut hidden = Vec::new();
        for (index, row) in listed.iter().enumerate() {
            let r = row.frame;
            // Zero-size system windows remain in the original z-order and cannot form a twin.
            if row.window == 0
                || row.pid < 0
                || row.onscreen > 1
                || ![r.x, r.y, r.width, r.height, r.x + r.width, r.y + r.height]
                    .iter()
                    .all(|v| v.is_finite())
                || r.width < 0.0
                || r.height < 0.0
            {
                return Err(INVALID);
            }
            if let Some(previous) = first.insert(row.window, row) {
                if previous != row {
                    return Err(INVALID);
                }
                continue;
            }
            if row.layer != 0 {
                continue;
            }
            if row.pid == i.manager_pid {
                if (r.width - 66.0).abs() <= 2.0 && (r.height - 82.0).abs() <= 2.0 {
                    icons.push(r);
                }
                continue;
            }
            if !managed.contains(&row.window) || row.pid == 0 {
                continue;
            }
            let twin = index
                .checked_sub(1)
                .and_then(|j| listed.get(j))
                .is_some_and(|above| {
                    above.pid == i.manager_pid && above.layer == 0 && same(above.frame, r)
                });
            let on_screen = overlap(&r, &screen) > 0.0;
            let small = r.valid() && r.width <= 240.0 && r.height <= 240.0;
            let off_left = r.x + r.width <= screen.x
                && r.y < screen.y + screen.height
                && r.y + r.height > screen.y;
            let kind = if r.valid() && (twin || (small && off_left)) {
                thumbs.push((row.window, r));
                Kind::Thumbnail
            } else if on_screen && row.onscreen != 0 {
                let g = o.current.get_or_insert_with(|| Group {
                    windows: Vec::new(),
                    frame: r,
                });
                g.windows.push(row.window);
                g.frame = union(g.frame, r);
                Kind::Current
            } else if on_screen && row.onscreen == 0 && small {
                hidden.push((row.window, r));
                Kind::Undrawn
            } else {
                Kind::Away
            };
            o.seen.insert(
                row.window,
                Seen {
                    pid: row.pid,
                    frame: r,
                    kind,
                },
            );
        }
        o.strip_shown =
            (!thumbs.is_empty()).then(|| thumbs.iter().any(|(_, r)| r.x + r.width > screen.x));
        o.strip = items(&thumbs, &icons);
        undrawn(&mut o.strip, &hidden);
        Ok(o)
    }
}

#[derive(Clone, Default)]
struct AxGroups {
    items: BTreeMap<u32, Group>,
    owners: BTreeMap<u32, u32>,
}

impl AxGroups {
    fn read(rows: &[AxMember], managed: &BTreeSet<u32>) -> Result<Self, u32> {
        let mut ax = Self::default();
        for row in rows {
            if row.window == 0 || !row.frame.valid() {
                return Err(INVALID);
            }
            if !managed.contains(&row.window) {
                continue;
            }
            let group = ax.items.entry(row.item).or_insert_with(|| Group {
                windows: Vec::new(),
                frame: row.frame,
            });
            if !same(group.frame, row.frame) {
                return Err(INVALID);
            }
            match ax.owners.insert(row.window, row.item) {
                Some(id) if id != row.item => return Err(INVALID),
                Some(_) => {}
                None => group.windows.push(row.window),
            }
        }
        Ok(ax)
    }

    // Keep membership in front-to-back CG order. AX proves only the listed strip
    // members it actually names; windows absent from AX keep their geometric group.
    fn regroup(&self, strip: &[Group]) -> Vec<Group> {
        let mut confirmed = BTreeMap::<u32, Group>::new();
        let mut out = Vec::new();
        for g in strip {
            let mut other = Vec::new();
            for &window in &g.windows {
                if let Some(item) = self.owners.get(&window) {
                    let group = confirmed.entry(*item).or_insert_with(|| Group {
                        windows: Vec::new(),
                        frame: self.items[item].frame,
                    });
                    group.windows.push(window);
                } else {
                    other.push(window);
                }
            }
            if !other.is_empty() {
                out.push(Group {
                    windows: other,
                    frame: g.frame,
                });
            }
        }
        out.extend(confirmed.into_values());
        out.sort_by(|a, b| a.frame.y.total_cmp(&b.frame.y));
        out
    }
}

fn partitions(groups: &[Group]) -> BTreeSet<BTreeSet<u32>> {
    groups
        .iter()
        .map(|g| g.windows.iter().copied().collect())
        .collect()
}

#[derive(Default)]
pub(super) struct State {
    pub(super) time: u64,
    pub(super) merge: Option<super::merge::Snapshot>,
    manager: i32,
    display: Rect,
    changed: Option<u64>,
    still: u32,
    seen: BTreeMap<u32, Seen>,
    current: Option<Group>,
    strip: Vec<Group>,
    remembered: Vec<Group>,
    strip_shown: Option<bool>,
    ax: AxGroups,
}

impl State {
    pub(super) fn unavailable(time: u64) -> Self {
        Self {
            time,
            ..Self::default()
        }
    }

    pub(super) fn fold(
        &self,
        i: &Input,
        listed: &[Listed],
        managed: &BTreeSet<u32>,
        ax_members: &[AxMember],
    ) -> Result<(Self, Vec<Member>, ResultInfo), u32> {
        let observed = Observation::new(i, listed, managed)?;
        let ax = AxGroups::read(ax_members, managed)?;
        let previous = self.manager == i.manager_pid && self.display == i.display_frame;
        let changed = i.transition_began != 0
            || (previous
                && (observed.seen.len() != self.seen.len()
                    || observed.seen.iter().any(|(id, row)| {
                        !self.seen.get(id).is_some_and(|p| {
                            p.pid == row.pid && p.kind == row.kind && same(p.frame, row.frame)
                        })
                    })));
        let changed_at = if changed {
            Some(i.sample_time_ns)
        } else if previous {
            self.changed
        } else {
            None
        };
        let still = if changed {
            0
        } else if previous {
            self.still.saturating_add(1)
        } else {
            1
        };
        let since = changed_at.map(|t| i.sample_time_ns - t).unwrap_or(u64::MAX);
        let moving = since < SETTLE_NS;
        let settled = !moving && still >= 2;
        let keep = |g: &Group, displayed: &BTreeSet<u32>| -> Option<Group> {
            let windows: Vec<u32> = g
                .windows
                .iter()
                .copied()
                .filter(|id| {
                    !displayed.contains(id)
                        && self
                            .seen
                            .get(id)
                            .zip(observed.seen.get(id))
                            .is_some_and(|(a, b)| a.pid == b.pid)
                })
                .collect();
            (!windows.is_empty()).then_some(Group {
                windows,
                frame: g.frame,
            })
        };
        let mut strip = observed.strip;
        let mut current = observed.current;
        let mut strip_shown = observed.strip_shown;
        let mut remembered = Vec::new();
        if moving && previous {
            let excluded = BTreeSet::new();
            current = self.current.as_ref().and_then(|g| keep(g, &excluded));
            strip = self
                .strip
                .iter()
                .filter_map(|g| keep(g, &excluded))
                .collect();
            remembered = self
                .remembered
                .iter()
                .filter_map(|g| keep(g, &excluded))
                .collect();
            strip_shown = self.strip_shown;
        } else if previous {
            let visible: BTreeSet<u32> = current
                .iter()
                .chain(&strip)
                .flat_map(|g| g.windows.iter().copied())
                .collect();
            remembered = self
                .current
                .iter()
                .chain(&self.strip)
                .chain(&self.remembered)
                .filter_map(|g| keep(g, &visible))
                .collect();
        }

        let fresh_merge_ax = settled && since >= SETTLE_NS + AX_TRUST_NS && !ax.owners.is_empty();
        let mut trusted = if previous && !changed && i.ax_available != 0 {
            self.ax.clone()
        } else {
            AxGroups::default()
        };
        let strip_ids: BTreeSet<u32> = strip
            .iter()
            .flat_map(|g| g.windows.iter().copied())
            .collect();
        let contradicts_current = current
            .iter()
            .flat_map(|g| &g.windows)
            .any(|id| ax.owners.contains_key(id));
        if settled && since >= SETTLE_NS + AX_TRUST_NS && !ax.owners.is_empty() {
            trusted = if contradicts_current || !ax.owners.keys().any(|id| strip_ids.contains(id)) {
                AxGroups::default()
            } else {
                ax
            };
        }
        let mut disagreement = contradicts_current && settled;
        let has_confirmation = settled && trusted.owners.keys().any(|id| strip_ids.contains(id));
        if has_confirmation {
            let corrected = trusted.regroup(&strip);
            disagreement |= partitions(&corrected) != partitions(&strip);
            strip = corrected;
        }

        let mut rows = Vec::new();
        let mut add = |g: &Group, ordinal: u32, role: u32| {
            rows.extend(g.windows.iter().map(|&window| Member {
                ordinal,
                role,
                window,
                group_frame: g.frame,
                confirmed_by_ax: u32::from(
                    role == STRIP && has_confirmation && trusted.owners.contains_key(&window),
                ),
            }));
        };
        if let Some(g) = &current {
            add(g, 0, CURRENT);
        }
        for (index, g) in strip.iter().enumerate() {
            add(g, 1 + index as u32, STRIP);
        }
        for (index, g) in remembered.iter().enumerate() {
            add(g, 1 + strip.len() as u32 + index as u32, REMEMBERED);
        }
        let info = ResultInfo {
            member_count: rows.len() as u32,
            settled: settled.into(),
            disagreement: disagreement.into(),
            trusted_ax: has_confirmation.into(),
            strip_shown: strip_shown.map(i32::from).unwrap_or(-1),
            ..ResultInfo::default()
        };
        let merge = if fresh_merge_ax
            && has_confirmation
            && !contradicts_current
            && strip_shown == Some(true)
        {
            current
                .as_ref()
                .map(|g| super::merge::Snapshot::new(i, listed, &g.windows, ax_members))
        } else {
            None
        };
        let next = Self {
            merge,
            time: i.sample_time_ns,
            manager: i.manager_pid,
            display: i.display_frame,
            changed: changed_at,
            still,
            seen: observed.seen,
            current,
            strip,
            remembered,
            strip_shown,
            ax: trusted,
        };
        Ok((next, rows, info))
    }
}
