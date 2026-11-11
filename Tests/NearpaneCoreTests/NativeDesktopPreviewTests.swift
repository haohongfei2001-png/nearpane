import Foundation
import Testing
import NearpaneCore

struct NativeDesktopPreviewTests {
    let date = Date(timeIntervalSince1970: 1000)
    let portrait = DisplayObservation(id: "portrait", frame: .init(x: -800, y: 0, width: 800, height: 1280),
        rotationDegrees: 90, backingScale: 2, usable: .init(x: 0, y: 20, width: 800, height: 1260))
    let landscape = DisplayObservation(id: "wide", frame: .init(width: 1800, height: 1000), rotationDegrees: 0,
        backingScale: 1, usable: .init(width: 1800, height: 1000))
    let viewport = SurfaceRect(width: 80, height: 126)
    var proof: ObservedSpaceRow {
        .init(displayID: portrait.id, scopeID: "secondary", recordID: "9",
              anchor: .init(number: 77, displayID: portrait.id, globalFrame: .init(x: -700, y: 70, width: 150, height: 80)))
    }

    func window(_ number: UInt32, _ frame: SurfaceRect, _ z: Int, _ membership: WindowMembership,
                display: String = "portrait", pid: Int32 = 313, epoch: UInt64 = 810,
                confidence: IdentityConfidence = .corroboratedMetadata, fullscreen: Bool? = false,
                axFrame: SurfaceRect? = nil, onScreen: Bool? = true) -> WindowObservation {
        let metadata = ObservedWindowMetadata(number: number, pid: pid, launchMicroseconds: epoch, element: UUID(),
            globalFrame: frame, frontToBack: z, minimized: false, fullScreen: fullscreen, axFrame: axFrame ?? frame, isOnscreen: onScreen)
        return .init(id: "ref-\(number)", displayID: display,
            bounds: .init(x: frame.x + (display == portrait.id ? 800 : 0), y: frame.y, width: frame.width, height: frame.height),
            membership: membership, confidence: confidence, metadata: metadata)
    }

    func sample(_ windows: [WindowObservation] = [], rows: [ObservedSpaceRow] = [], stageManager: Bool? = nil) -> DesktopSnapshot {
        let request = DesktopReadRequest(session: UUID(), revision: 10, parentPID: 101, fixtureWindows: nil,
                                         anchors: rows.map(\.anchor), experimentalSpaces: true)
        return .observed(request, from: date, to: date, build: "fixture", topology: "two",
            consistent: true, separateSpaces: true, displays: [landscape, portrait],
            scopes: [.init(id: "primary", displayID: landscape.id,
                           records: ["3","4","5"].map { .init(id: $0, isCurrent: $0 == "3") }),
                     .init(id: "secondary", displayID: portrait.id, records: [.init(id: "9", isCurrent: true)])],
            windows: windows, evidence: .init(population: .workWindows, accessibility: .available, spaces: .observed,
                                              rows: rows, windowLimitReached: false, beganUptime: 40, endedUptime: 41, stageManagerEnabled: stageManager))
    }

    func preview(_ state: DesktopSnapshot) -> DesktopPreview? {
        DesktopPreview(snapshot: state, displayID: portrait.id, viewport: viewport, now: date, uptime: 42)
    }

    @Test func stageManagerDoesNotGrantOrRevokeIdentityOrPermissionByItself() throws {
        let ax = SurfaceRect(x: -681, y: 64, width: 562, height: 422)
        let cg = SurfaceRect(x: -64, y: 602, width: 49, height: 76)
        let suspect = window(179888, cg, 0, .known(recordIDs: ["9"]), axFrame: ax)
        let good = window(33, ax, 1, .known(recordIDs: ["9"]))
        #expect(ManagedWindowID(suspect) != nil && suspect.metadata?.presentation == .divergent)
        for mode: Bool? in [true, false, nil] {
            let s = sample([suspect, good], rows: [proof], stageManager: mode)
            let copy = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(s))
            #expect(copy == s && copy.native?.stageManagerEnabled == mode)
            let p = try #require(preview(s))
            #expect(p.rows[0].windows.count == 2)
            #expect(p.hit(x: 75, y: 60, current: s, now: date, uptime: 42) == .blocked(suspect.id))
            #expect(p.hit(x: 20, y: 12, current: s, now: date, uptime: 42) == .candidate(good.id))
            for w in [suspect, good] {
                let t = DesktopTarget(sessionID: s.sessionID, revision: s.revision, runtimeID: w.id)
                #expect(s.containsObservation(w, target: t, now: date, uptime: 42) == (w == good))
            }
        }
    }

    @Test func legacyObservationWithoutVisibilityRemainsReadOnly() throws {
        let w = window(1, .init(x: -560, y: 20, width: 300, height: 100), 0, .known(recordIDs: ["9"]), onScreen: nil)
        let s = sample([w], rows: [proof])
        let old = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(s))
        #expect(old.windows[0].metadata?.presentation == .unconfirmed)
        let p = try #require(preview(old))
        #expect(p.hit(x: 30, y: 5, current: old, now: date, uptime: 42) == .blocked(w.id))
    }

    @Test func linkedScopesAndUnwitnessedRecordsNeverProduceSpaceRows() throws {
        var s = sample()
        s.separateSpaces = false
        #expect(s.isStructurallyValid)
        #expect(try #require(preview(s)).rows.map(\.kind) == [.visibleDisplay])
        s = sample(rows: [proof]); s.separateSpaces = false
        #expect(!s.isStructurallyValid && preview(s) == nil)
        #expect(DesktopPreview(snapshot: sample(), displayID: nil, viewport: viewport, now: date, uptime: 42) == nil)
    }

    @Test func clipsAcrossDisplaysUsingActualUsableRectangleAndSingleScale() throws {
        let cross = window(1, .init(x: -100, y: 0, width: 400, height: 300), 0, .unknown, display: landscape.id)
        let s = sample([cross])
        let row = try #require(preview(s)).rows[0]
        #expect(row.kind == .visibleDisplay && row.desktop == viewport)
        #expect(row.windows[0].frame == SurfaceRect(x: 70, y: 0, width: 10, height: 28))
        let other = try #require(DesktopPreview(snapshot: s, displayID: landscape.id, viewport: .init(width: 180, height: 100),
                                                now: date, uptime: 42))
        #expect(other.rows[0].windows[0].frame == SurfaceRect(x: 0, y: 0, width: 30, height: 30))
    }

    @Test func scopedRowsKeepMultipleMembershipAndUnknownForegroundBlocksHit() throws {
        let full = SurfaceRect(x: -800, y: 20, width: 800, height: 1260)
        let front = window(1, .init(x: -600, y: 220, width: 200, height: 250), 0, .unknown)
        let other = window(2, full, 1, .known(recordIDs: ["3"]))
        let back = window(3, full, 2, .known(recordIDs: ["3","9"]))
        let covered = window(4, full, 3, .known(recordIDs: ["9"]))
        let s = sample([covered, other, front, back], rows: [proof])
        let p = try #require(preview(s)), row = p.rows[0]
        #expect(row.kind == .witnessedSpace("9") && row.hasUnassignedWindows)
        #expect(row.windows.map(\.id) == [back.id, covered.id])
        #expect(p.hit(x: 30, y: 30, current: s, now: date, uptime: 42) == .blocked(front.id))
        #expect(p.hit(x: 60, y: 100, current: s, now: date, uptime: 42) == .candidate(back.id))
    }

    @Test func unequalPartitionsAndUnoccupiedBoundsStayProportional() throws {
        let a = window(1, .init(x: -770, y: 120, width: 480, height: 400), 1, .unknown)
        let b = window(2, .init(x: -290, y: 120, width: 240, height: 400), 0, .unknown)
        let s = sample([a,b]), p = try #require(preview(s)), row = p.rows[0]
        #expect(row.windows.map(\.frame) == [.init(x: 51, y: 10, width: 24, height: 40), .init(x: 3, y: 10, width: 48, height: 40)])
        #expect(p.hit(x: 10, y: 60, current: s, now: date, uptime: 42) == .none)
        #expect(p.hit(x: 10, y: 20, current: s, now: date, uptime: 42) == .blocked(a.id))
    }

    @Test func rebuiltWindowProcessEpochAndSessionCannotReuseAReference() throws {
        let frame = SurfaceRect(x: -760, y: 30, width: 400, height: 120)
        let old = window(7, frame, 0, .unknown), s = sample([old])
        let target = DesktopTarget(sessionID: s.sessionID, revision: s.revision, runtimeID: old.id)
        #expect(s.containsObservation(old, target: target, now: date, uptime: 42))
        for new in [window(7,frame,0,.unknown), window(7,frame,0,.unknown,epoch: 811), window(7,frame,0,.unknown,pid: 314)] {
            var replaced = s; replaced.windows = [new]
            #expect(!replaced.containsObservation(old, target: target, now: date, uptime: 42))
        }
        var later = s; later.revision += 1
        #expect(!later.containsObservation(old, target: target, now: date, uptime: 42))
        var other = s; other.sessionID = UUID()
        #expect(!other.containsObservation(old, target: target, now: date, uptime: 42))
        var closed = s; closed.windows = []
        #expect(!closed.containsObservation(old, target: target, now: date, uptime: 42))
    }

    @Test func unstableDelayedOrIncompleteSamplesHaveNoPreview() {
        var s = sample(); s.topologyConsistent = false; s.freshness = .transient
        #expect(preview(s) == nil)
        s = sample()
        #expect(DesktopPreview(snapshot: s, displayID: portrait.id, viewport: viewport, now: date, uptime: 60) == nil)
        #expect(DesktopPreview(snapshot: s, displayID: portrait.id, viewport: viewport, now: date.addingTimeInterval(13), uptime: 42) == nil)
        s.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [], windowLimitReached: true,
                         beganUptime: 40, endedUptime: 41)
        #expect(preview(s) == nil)
    }

    @Test func ambiguousOrUnknownFullscreenWindowBlocksGeometricHit() throws {
        let f = SurfaceRect(x: -720, y: 120, width: 240, height: 240)
        for w in [window(4,f,0,.unknown,confidence: .ambiguous), window(4,f,0,.unknown,fullscreen: nil),
                  window(4,f,0,.unknown,fullscreen: true)] {
            let s = sample([w]), p = try #require(preview(s))
            #expect(p.hit(x: 20, y: 20, current: s, now: date, uptime: 42) == .blocked(w.id))
            #expect(p.hit(x: 20, y: 20, current: s, now: date, uptime: 60) == .none)
            #expect(!s.capabilities.windowActivation && !s.capabilities.spaceSwitching)
        }
    }
}
