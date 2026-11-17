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
                axFrame: SurfaceRect? = nil, onScreen: Bool? = true, axNumber: UInt32? = nil, active: Bool? = nil) -> WindowObservation {
        let metadata = ObservedWindowMetadata(number: number, pid: pid, launchMicroseconds: epoch, element: UUID(),
            globalFrame: frame, frontToBack: z, minimized: false, fullScreen: fullscreen, axFrame: axFrame ?? frame, isOnscreen: onScreen, axStandardWindowNumber: axNumber, onActiveDesktop: active)
        return .init(id: "ref-\(number)", displayID: display,
            bounds: .init(x: frame.x + (display == portrait.id ? 800 : 0), y: frame.y, width: frame.width, height: frame.height),
            membership: membership, confidence: confidence, metadata: metadata)
    }

    @Test func activeWindowListSeparatesCoveredSiblingsAndDoesNotInventMembership() {
        let r = SurfaceRect(x: -720, y: 90, width: 200, height: 120)
        func current(_ z: Int) -> DesktopSnapshot {
            sample([window(12, r, z, .unknown, axNumber: 12, active: true),
                    window(13, r, 1-z, .unknown, axNumber: 13, active: true),
                    window(14, r, 2, .unknown, axNumber: 14, active: false),
                    window(15, r, 3, .unknown, axNumber: 15)])
        }
        for state in [current(0), current(1)] {
            let uptime = state.native!.endedUptime
            let list = state.currentDesktopWindows(on: portrait.id, now: date, uptime: uptime)
            #expect(list.compactMap { $0.metadata?.number } == [12, 13])
            #expect(list.allSatisfy { $0.canWitnessCurrentSpace })
            #expect(state.presentationDemand(for: portrait.id, now: date, uptime: uptime).hasCurrentDesktopWindows)
            #expect(state.currentDesktopWindows(on: landscape.id, now: date, uptime: uptime).isEmpty)
            #expect(state.currentDesktopWindows(on: portrait.id, now: date, uptime: uptime + 15).isEmpty)
        }
    }

    @Test func conflictingSpaceOrUnconfirmedGeometryCannotBecomeAnActiveTarget() {
        let r = SurfaceRect(x: -700, y: 70, width: 150, height: 80)
        let state = sample([window(77, r, 0, .known(recordIDs:["9"]), axNumber: 77, active: true),
                            window(31, r, 1, .known(recordIDs:["4"]), axNumber: 31, active: true),
                            window(32, r, 2, .unknown, axFrame: .init(width: 49, height: 76), axNumber: 32, active: true)], rows: [proof])
        let list = state.currentDesktopWindows(on: portrait.id, now: date, uptime: state.native!.endedUptime)
        #expect(list.compactMap { $0.metadata?.number } == [32,77])
        #expect(list.filter(\.canWitnessCurrentSpace).compactMap { $0.metadata?.number } == [77])
        #expect(list.filter(\.canRequestCurrentDesktopFocus).compactMap { $0.metadata?.number } == [77])
        #expect(!OrdinaryWindowRequest.Action.focusCurrent.allowedForStillPreview)
    }

    @Test func incompleteAXSampleOnlyAllowsLiveLookupOnCurrentDesktop() {
        func candidate(_ active: Bool?, _ confidence: IdentityConfidence) -> WindowObservation {
            let r = SurfaceRect(width: 180, height: 130)
            return .init(id: "candidate", displayID: "wide", bounds: r, membership: .unknown, confidence: confidence,
                         metadata: .init(number: 12, pid: 313, launchMicroseconds: 810, element: nil,
                                         globalFrame: r, frontToBack: 1, minimized: nil, fullScreen: nil,
                                         isOnscreen: true, onActiveDesktop: active))
        }
        let pending = candidate(true, .unknown)
        #expect(pending.canRequestCurrentDesktopFocus && !pending.canWitnessCurrentSpace)
        #expect(!candidate(false, .unknown).canRequestCurrentDesktopFocus)
        #expect(!candidate(nil, .unknown).canRequestCurrentDesktopFocus)
        #expect(!candidate(true, .ambiguous).canRequestCurrentDesktopFocus)
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

    private func visit(_ session: UUID, revision: UInt64, current: String, firstUUID: UUID?, secondUUID: UUID,
                       witness: Bool = true, available: Bool = true) -> DesktopSnapshot {
        let record = ObservedSpaceRow(displayID: portrait.id, scopeID: "secondary", recordID: current, anchor: proof.anchor)
        let rows = witness ? [record] : []
        let window = window(5, proof.anchor.globalFrame, 0, .known(recordIDs: ["8", "9"]))
        var state = sample([window], rows: rows)
        state.revision = revision; state.sessionID = session
        state.native = .init(population: .workWindows, accessibility: available ? .available : .denied,
                             spaces: .observed, rows: rows, windowLimitReached: false, beganUptime: 40, endedUptime: 41)
        state.scopes = [.init(id: "secondary", displayID: portrait.id, records: [
            .init(id: "8", isCurrent: current == "8", ordinaryUUID: firstUUID),
            .init(id: "9", isCurrent: current == "9", ordinaryUUID: secondUUID)])]
        return state
    }

    @Test func manuallyVisitedOrdinarySpacesKeepTheirSystemOrderWithoutRetainingWindowContentOrActions() throws {
        let session = UUID(), a = UUID(), b = UUID()
        var history = WitnessedSpaceHistory()
        var first = visit(session, revision: 1, current: "8", firstUUID: a, secondUUID: b)
        history.apply(to: &first, now: date, uptime: 42)
        #expect(try #require(preview(first)).rows.map(\.kind) == [.witnessedSpace("8")])
        var second = visit(session, revision: 2, current: "9", firstUUID: a, secondUUID: b)
        history.apply(to: &second, now: date, uptime: 42)
        let panel = try #require(preview(second)), row = panel.rows[0]
        #expect(panel.rows.map(\.kind) == [.previouslyWitnessedSpace("8"), .witnessedSpace("9")])
        #expect(row.windows.isEmpty && !row.hasUnassignedWindows && !panel.rows[1].windows.isEmpty)
        #expect(panel.hit(x: row.desktop.x + 1, y: row.desktop.y + 1, current: second, now: date, uptime: 42) == .none)
        #expect(second.desktopPreviewRowCount(for: portrait.id) == 2 && second.presentationDemand(for: portrait.id, now: date, uptime: 42).spaces == 2)
        let wire = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(second))
        #expect(try #require(preview(wire)).rows.map(\.kind) == [.witnessedSpace("9")])
        var back = visit(session, revision: 3, current: "8", firstUUID: a, secondUUID: b)
        history.apply(to: &back, now: date, uptime: 42)
        #expect(try #require(preview(back)).rows.map(\.kind) == [.witnessedSpace("8"), .previouslyWitnessedSpace("9")])
    }

    @Test func missingReusedDuplicateOrRetiredWitnessesNeverInventBackgroundRows() throws {
        let session = UUID(), a = UUID(), b = UUID()
        for change in 0..<8 {
            var history = WitnessedSpaceHistory()
            var first = visit(session, revision: 1, current: "8", firstUUID: a, secondUUID: b, witness: change != 0)
            history.apply(to: &first, now: date, uptime: 42)
            if change == 1 {
                var denied = visit(session, revision: 2, current: "8", firstUUID: a, secondUUID: b, witness: false, available: false)
                history.apply(to: &denied, now: date, uptime: 42)
            }
            var second = visit(change == 2 ? UUID() : session, revision: 3, current: "9",
                               firstUUID: change == 3 ? nil : change == 4 ? UUID() : change == 5 ? b : a, secondUUID: b)
            if change == 6 { second.topologyFingerprint = "changed" }
            if change == 7 {
                var stale = visit(session, revision: 2, current: "8", firstUUID: a, secondUUID: b)
                history.apply(to: &stale, now: date, uptime: 80)
            }
            history.apply(to: &second, now: date, uptime: 42)
            #expect(try #require(preview(second)).rows.map(\.kind) == [.witnessedSpace("9")])
        }
    }

    @Test func activeSpaceRowUsesSystemNumberWhenTitlesCannotCorroborate() throws {
        let frame = proof.anchor.globalFrame
        let row = ObservedSpaceRow(displayID: portrait.id, scopeID: proof.scopeID, recordID: proof.recordID,
            anchor: .init(number: 77, displayID: portrait.id, globalFrame: frame, witness: .appKitActiveList))
        func witnessed(_ confidence: IdentityConfidence, axNumber: UInt32?) -> DesktopSnapshot {
            let w = window(77, frame, 0, .known(recordIDs: ["9"]), confidence: confidence, axNumber: axNumber)
            return sample([w], rows: [row])
        }
        #expect(preview(witnessed(.corroboratedMetadata, axNumber: 78)) == nil)
        let exact = witnessed(.geometryOnly, axNumber: 77)
        #expect(try #require(preview(exact)).rows.map(\.kind) == [.witnessedSpace("9")])
        #expect(try #require(preview(exact)).rows[0].windows[0].canShowContent)
        #expect(!exact.capabilities.spaceSwitching)
        #expect(preview(witnessed(.ambiguous, axNumber: 77)) == nil)
        #expect(preview(witnessed(.geometryOnly, axNumber: nil)) == nil)
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
            #expect(p.rows[0].windows[0].presentation == .divergent && !p.rows[0].windows[0].canShowContent)
            #expect(p.rows[0].windows[1].presentation == .confirmed && !p.rows[0].windows[1].canShowContent)
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
