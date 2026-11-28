use super::*;
use std::ptr;

pub(super) fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}
pub(super) fn row(window: u32, pid: i32, frame: Rect) -> Listed {
    Listed {
        window,
        pid,
        layer: 0,
        onscreen: 1,
        frame,
    }
}
pub(super) fn scope(display: u8, space: u64) -> Scope {
    Scope {
        size: size_of::<Scope>() as u32,
        version: 1,
        display_uuid: [display; 16],
        native_space_id: space,
    }
}
pub(super) fn sample(scope: Scope, time: u64) -> Input {
    Input {
        size: size_of::<Input>() as u32,
        version: 1,
        scope,
        sample_time_ns: time,
        display_frame: rect(0., 0., 1600., 1000.),
        manager_pid: 99,
        ax_available: 0,
        transition_began: 0,
        listed_count: 0,
        managed_count: 0,
        ax_count: 0,
        listed: ptr::null(),
        managed: ptr::null(),
        ax_members: ptr::null(),
    }
}
pub(super) struct Reader(pub(super) u64);
impl Reader {
    pub(super) fn new(s: Scope) -> Self {
        let mut h = 0;
        assert_eq!(unsafe { np_apple_mirror_create(&s, &mut h) }, 0);
        Self(h)
    }
    pub(super) fn read(
        &self,
        mut i: Input,
        listed: &[Listed],
        managed: &[u32],
        ax: &[AxMember],
        capacity: usize,
    ) -> (u32, Vec<Member>, ResultInfo) {
        i.listed = listed.as_ptr();
        i.managed = managed.as_ptr();
        i.ax_members = ax.as_ptr();
        i.listed_count = listed.len() as u32;
        i.managed_count = managed.len() as u32;
        i.ax_count = ax.len() as u32;
        let mut info = ResultInfo::default();
        let mut rows = vec![Member::default(); capacity];
        let status = unsafe {
            np_apple_mirror_read_v1(self.0, &i, rows.as_mut_ptr(), capacity as u32, &mut info)
        };
        rows.truncate(if status == 0 {
            info.member_count as usize
        } else {
            0
        });
        (status, rows, info)
    }
}
impl Drop for Reader {
    fn drop(&mut self) {
        np_apple_mirror_destroy(self.0);
    }
}
fn members(rows: &[Member]) -> Vec<(u32, u32, u32)> {
    rows.iter().map(|m| (m.ordinal, m.role, m.window)).collect()
}
pub(super) fn scene() -> Vec<Listed> {
    let large = rect(300., 80., 800., 710.);
    let a = rect(30., 100., 185., 160.);
    let b = rect(36., 107., 180., 161.);
    let c = rect(29., 440., 180., 120.);
    vec![
        row(1, 10, large),
        row(101, 99, a),
        row(2, 10, a),
        row(102, 99, b),
        row(3, 70, b),
        row(103, 99, c),
        row(4, 70, c),
    ]
}

#[test]
fn mirror_groups_twin_windows_by_overlap_and_preserves_current_sibling() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let mut rows = scene();
    rows.push(Listed {
        onscreen: 0,
        ..row(5, 10, rect(31., 104., 50., 80.))
    });
    rows.push(row(104, 99, rect(6., 155., 66., 82.)));
    let (status, out, info) = h.read(sample(s, 1), &rows, &[1, 2, 3, 4, 5, 2], &[], 6);
    assert_eq!(status, 0);
    assert_eq!(info.strip_shown, 1);
    assert_eq!(info.settled, 0);
    assert_eq!(
        members(&out),
        vec![
            (0, CURRENT, 1),
            (1, STRIP, 2),
            (1, STRIP, 3),
            (1, STRIP, 5),
            (2, STRIP, 4)
        ]
    );
    assert_eq!(out[1].group_frame.x, 6.);
    assert_eq!(
        h.read(sample(s, 2), &rows, &[1, 2, 3, 4, 5], &[], 5)
            .2
            .settled,
        1
    );
}

#[test]
fn unmanaged_intervening_row_prevents_false_twin_hidden_strip_is_classified() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let a = rect(15., 21., 170., 140.);
    let rows = [
        row(9, 99, a),
        Listed {
            layer: 5,
            ..row(36, 88, a)
        },
        row(2, 10, a),
        row(3, 10, rect(-258., 480., 180., 120.)),
        row(4, 10, rect(-258., 1800., 180., 120.)),
    ];
    let (code, out, info) = h.read(sample(s, 1), &rows, &[2, 3, 4], &[], 3);
    assert_eq!(code, 0);
    assert_eq!(members(&out), vec![(0, CURRENT, 2), (1, STRIP, 3)]);
    assert_eq!(info.strip_shown, 0);
}

#[test]
fn motion_keeps_last_observed_groups_prunes_dead_windows_and_delays_ax() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let mut rows = scene();
    let ids = [1, 2, 3, 4];
    let ax = [
        AxMember {
            item: 0,
            window: 2,
            frame: rows[1].frame,
        },
        AxMember {
            item: 1,
            window: 3,
            frame: rows[5].frame,
        },
        AxMember {
            item: 1,
            window: 4,
            frame: rows[5].frame,
        },
    ];
    assert_eq!(h.read(sample(s, 1), &rows, &ids, &[], 4).0, 0);
    let mut i = sample(s, 20);
    i.transition_began = 1;
    assert_eq!(h.read(i, &rows, &ids, &[], 4).2.settled, 0);
    rows.remove(0);
    let read = |time: u64, rows: &[Listed], ax: &[AxMember]| {
        let mut i = sample(s, time);
        i.ax_available = 1;
        h.read(i, rows, &ids, ax, 4)
    };
    let (_, held, moving) = read(40, &rows, &ax);
    assert!(!held.iter().any(|m| m.window == 1));
    assert_eq!(moving.trusted_ax, 0);
    assert_eq!(
        held.iter().find(|m| m.window == 2).unwrap().ordinal,
        held.iter().find(|m| m.window == 3).unwrap().ordinal
    );
    assert_eq!(read(400_000_040, &rows, &ax).2.settled, 0);
    let (_, _, pre) = read(700_000_040, &rows, &ax);
    assert_eq!((pre.settled, pre.trusted_ax), (1, 0));
    let (_, corrected, after) = read(1_700_000_040, &rows, &ax);
    assert_eq!((after.disagreement, after.trusted_ax), (1, 1));
    assert_eq!(
        members(&corrected),
        vec![(1, STRIP, 2), (2, STRIP, 3), (2, STRIP, 4)]
    );
    assert!(corrected.iter().all(|m| m.confirmed_by_ax == 1));
    let (_, blank, fresh) = read(1_800_000_040, &rows, &[]);
    assert_eq!(members(&blank), members(&corrected));
    assert_eq!(fresh.trusted_ax, 1);
    // Permission no longer available. No AX confirmation can survive it.
    let (_, again, off) = h.read(sample(s, 1_900_000_040), &rows, &ids, &[], 4);
    assert_eq!(off.trusted_ax, 0);
    assert!(again.iter().all(|r| r.confirmed_by_ax == 0));
}

#[test]
fn remembered_requires_same_live_managed_pid_and_is_not_a_strip_target() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let ids = [1, 2];
    let frame = rect(22., 34., 180., 100.);
    let scene = [
        row(93, 99, frame),
        row(2, 10, frame),
        row(1, 11, rect(400., 380., 300., 500.)),
    ];
    assert_eq!(h.read(sample(s, 1), &scene, &ids, &[], 2).0, 0);
    let away = [
        Listed {
            onscreen: 0,
            ..row(2, 10, rect(400., 380., 300., 500.))
        },
        scene[2],
    ];
    h.read(sample(s, 100), &away, &ids, &[], 2);
    let (_, out, _) = h.read(sample(s, 800_000_100), &away, &ids, &[], 2);
    assert_eq!(members(&out), vec![(0, CURRENT, 1), (1, REMEMBERED, 2)]);
    let reused = [
        Listed {
            pid: 900,
            ..away[0]
        },
        away[1],
    ];
    let (_, out, _) = h.read(sample(s, 900_000_100), &reused, &ids, &[], 2);
    assert_eq!(members(&out), vec![(0, CURRENT, 1)]);
}

#[test]
fn capacity_retry_and_physical_scope_isolation_are_atomic() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let rows = scene();
    let ids = [1, 2, 3, 4];
    let (code, _, short) = h.read(sample(s, 12), &rows, &ids, &[], 1);
    assert_eq!((code, short.member_count), (CAPACITY, 4));
    let (code, _, fresh) = h.read(sample(s, 12), &rows, &ids, &[], 4);
    assert_eq!((code, fresh.settled), (0, 0));
    assert_eq!(h.read(sample(s, 12), &rows, &ids, &[], 4).0, STALE);
    let other = scope(2, 4);
    assert_eq!(
        h.read(sample(other, 13), &rows, &ids, &[], 4).0,
        SCOPE_CHANGED
    );
    assert_eq!(
        h.read(sample(scope(1, 5), 13), &rows, &ids, &[], 4).0,
        SCOPE_CHANGED
    );
    let second = Reader::new(other);
    assert_eq!(
        second.read(sample(other, 12), &rows, &[4], &[], 1).1[0].ordinal,
        1
    );
    let mut down = sample(s, 14);
    down.manager_pid = 0;
    assert_eq!(h.read(down, &[], &[], &[], 0).0, UNAVAILABLE);
    assert_eq!(h.read(sample(s, 15), &rows, &ids, &[], 4).2.settled, 0);
    assert_eq!(np_apple_mirror_destroy(second.0), 0);
    assert_eq!(second.read(sample(other, 16), &[], &[], &[], 0).0, CLOSED);
}

#[test]
fn rejects_conflicting_or_malformed_observations_without_advancing_session() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let mut rows = scene();
    rows.push(Listed {
        pid: 666,
        ..rows[0]
    });
    assert_eq!(h.read(sample(s, 12), &rows, &[1, 2], &[], 2).0, INVALID);
    rows.pop();
    rows.push(rows[0]);
    let mut i = sample(s, 12);
    i.ax_available = 1;
    let contradictory = [
        AxMember {
            item: 1,
            window: 2,
            frame: rows[1].frame,
        },
        AxMember {
            item: 2,
            window: 2,
            frame: rows[1].frame,
        },
    ];
    assert_eq!(h.read(i, &rows, &[1, 2], &contradictory, 2).0, INVALID);
    assert_eq!(h.read(sample(s, 12), &rows, &[1, 2], &[], 2).0, 0);
    let mut invalid = sample(s, 13);
    invalid.listed_count = 8193;
    invalid.listed = rows.as_ptr();
    let mut info = ResultInfo::default();
    assert_eq!(
        unsafe { np_apple_mirror_read_v1(h.0, &invalid, ptr::null_mut(), 0, &mut info) },
        INVALID
    );
    invalid.listed_count = 1;
    invalid.listed = ptr::null();
    assert_eq!(
        unsafe { np_apple_mirror_read_v1(h.0, &invalid, ptr::null_mut(), 0, &mut info) },
        INVALID
    );
    assert_eq!(h.read(sample(s, 13), &[], &[], &[], 0).0, 0);
}

// The pinned upstream project's real three-activation CG capture (MIT).
// This is an offline replay; it cannot establish current physical OS qualification.
#[test]
fn replays_three_upstream_native_activations_through_c_abi() {
    let s = scope(1, 4);
    let h = Reader::new(s);
    let ids = [73, 74, 80, 86];
    let expected = [
        vec![
            (0, CURRENT, 86),
            (1, STRIP, 80),
            (2, STRIP, 73),
            (2, STRIP, 74),
        ],
        vec![
            (0, CURRENT, 73),
            (0, CURRENT, 74),
            (1, STRIP, 80),
            (2, STRIP, 86),
        ],
        vec![
            (0, CURRENT, 80),
            (1, STRIP, 73),
            (1, STRIP, 74),
            (2, STRIP, 86),
        ],
    ];
    for (step, capture) in include_str!("upstream-capture.txt").lines().enumerate() {
        let mut alpha = [73, 74].into_iter();
        let mut wm = 1000..;
        let rows = capture
            .split('|')
            .map(|line| {
                let parts: Vec<_> = line.split_whitespace().collect();
                let coord = |i: usize| parts[i].parse::<f64>().unwrap();
                let (id, pid) = match parts[0] {
                    "WM" => (wm.next().unwrap(), 99),
                    "alpha" => (alpha.next().unwrap(), 1),
                    "bravo" => (80, 2),
                    "charlie" => (86, 3),
                    name => panic!("unknown capture ID {name}"),
                };
                row(id, pid, rect(coord(1), coord(2), coord(3), coord(4)))
            })
            .collect::<Vec<_>>();
        let mut out = None;
        for offset in [0, 800_000_000, 850_000_000] {
            let mut input = sample(s, 3_000_000_000 * step as u64 + offset + 1);
            input.display_frame = rect(0., 0., 1512., 982.);
            let (code, found, quality) = h.read(input, &rows, &ids, &[], 4);
            assert_eq!(code, 0);
            out = Some((found, quality));
        }
        let (found, quality) = out.unwrap();
        assert_eq!(members(&found), expected[step]);
        assert_eq!((quality.settled, quality.strip_shown), (1, 1));
    }
}
