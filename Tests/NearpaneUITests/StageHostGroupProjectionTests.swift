import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct StageHostGroupProjectionTests {
    @Test func anUnavailableGroupClickKeepsTheWorkSetAndOnlyAnExplicitMemberMayFocus() throws {
        var focusCount = 0
        #expect(throws: StageSwitchError.unavailable) {
            try StageSidebarSelection.group.withoutEngine { focusCount += 1 }
        }
        #expect(focusCount == 0)
        try StageSidebarSelection.member.withoutEngine { focusCount += 1 }
        #expect(focusCount == 1)
    }
    let display = UUID().uuidString, space = UUID(), rect = SurfaceRect(x: 24, y: 32, width: 320, height: 200)
    func window(_ n: UInt32, member: String = "4", membership: WindowMembership? = nil, rank: Int = 0) -> WindowObservation {
        .init(id: String(n), displayID: display, bounds: rect, membership: membership ?? .known(recordIDs: [member]), confidence: .unknown,
              metadata: .init(number: n, pid: 614, launchMicroseconds: 3400, element: nil, globalFrame: rect, frontToBack: rank,
                              minimized: nil, fullScreen: nil, isOnscreen: true, onActiveDesktop: true, overviewSpaceID: member))
    }
    func snapshot(_ windows: [WindowObservation], stage: Bool? = false, complete: Bool = true,
                  request: DesktopReadRequest? = nil, accessibility: AXReadStatus = .denied) -> DesktopSnapshot {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime, screen = SurfaceRect(width: 900, height: 700)
        return .observed(request ?? .init(session: UUID(), revision: 5, parentPID: 1, fixtureWindows: nil, anchors: [], experimentalSpaces: false),
            from: now, to: now, build: "fixture", topology: "fixture", consistent: true, separateSpaces: true,
            displays: [.init(id: display, frame: screen, rotationDegrees: 0, backingScale: 1, usable: screen)],
            scopes: [.init(id: "scope", displayID: display, records: [.init(id: "4", isCurrent: true, ordinaryUUID: space)])],
            windows: windows, evidence: .init(population: .workWindows, accessibility: accessibility, spaces: .observed, rows: [],
                   windowLimitReached: false, beganUptime: uptime, endedUptime: uptime, stageManagerEnabled: stage,
                   catalogComplete: complete))
    }
    func seen(_ n: UInt32, birth: UInt64 = 3400, bounds: SurfaceRect? = nil, member: UInt64 = 4) -> StageWindowPhysicalObservation {
        .init(id: .init(pid: 614, launch: birth, number: n, element: UUID()), frame: bounds ?? rect, membership: member,
              onscreen: true, minimized: false, focus: nil)
    }

    @Test func overlappingMembersRemainSelectableByIdentityUntilRemovedFromTheirGroup() async throws {
        let windows = [window(8, rank: 1), window(9, rank: 0)].map { observed in
            var confirmed = observed
            confirmed.metadata?.overviewOrdinaryRole = true
            confirmed.metadata?.minimized = false
            return confirmed
        }
        let feed = CurrentDesktopWindows(read: { request in await self.snapshot(windows, request: request, accessibility: .partial) },
                                         sessionAvailable: { true }, fingerprint: { 0 })
        feed.observe(true)
        defer { feed.observe(false) }
        let sample = try #require(await feed.readNow())
        let source = NativeSidebarDestination(session: sample.sessionID, topology: sample.topologyFingerprint,
                                             display: display, space: "4", uuid: space)
        let choices = StageGroupMemberChoice.rows(windows, source: source, lifetime: feed.lifetime(of:), name: { _ in "编辑器" })
        try #require(choices.count == 2)
        let first = choices[0], second = choices[1]
        #expect(first.window.bounds == second.window.bounds)
        #expect(choices.map(\.label) == ["编辑器 · 1", "编辑器 · 2"])
        #expect(choices.map(\.id.number) == [8, 9])
        #expect(!feed.stageEngine.offersGroupSelection(on: source))
        try feed.join(first.member, second.member, in: sample)
        let group = try #require(feed.groups.groups(in: .init(display: UUID(uuidString: display)!, nativeSpace: space)).first)
        #expect(feed.stillGroups(first.member, in: group.id, appearance: first.lifetime))
        #expect(feed.stillGroups(second.member, in: group.id, appearance: second.lifetime))
        #expect(!feed.stillGroups(first.member, in: group.id, appearance: UUID()))
        try feed.groups.detach(try #require(feed.groupWindow(first.member, in: sample)), from: group.id)
        #expect(!feed.stillGroups(first.member, in: group.id, appearance: first.lifetime))
        feed.invalidate()
        #expect(!feed.stillGroups(second.member, in: group.id, appearance: second.lifetime))
    }

    @Test func actualHostEvidenceSuppliesAGroupProjectionWithoutChangingTheReaderReceipt() async throws {
        let raw = snapshot([window(8), window(9), window(10), window(11, member: "5")])
        var requested = [UInt32]()
        let copy = try #require(await StageWindowEngineHost.projectGroups(raw) { key, home in
            requested.append(key.number)
            #expect(home.display == display && home.uuid == space && home.record == "4")
            switch key.number { case 8: return seen(8); case 9: return nil; default: throw StageSwitchError.incomplete }
        })
        #expect(requested == [8, 9, 10])
        #expect(raw.native?.accessibility == .denied && raw.windows[0].metadata?.overviewOrdinaryRole == nil)
        #expect(copy.native?.accessibility == .partial && copy.isCurrentDesktopWindow(copy.windows[0]))
        #expect(copy.windows[1].metadata?.overviewOrdinaryRole == false && !copy.isCurrentDesktopWindow(copy.windows[1]))
        #expect(copy.windows[2].metadata?.overviewOrdinaryRole == nil && !copy.isCurrentDesktopWindow(copy.windows[2]))
        #expect(copy.windows[3] == raw.windows[3])
    }

    @Test func directoryReadsWithoutAParkedWindowOrWriterAndPreservesAlreadyVerifiedRows() async throws {
        var raw = snapshot([window(8), window(9)])
        raw.native?.accessibility = .partial
        raw.windows[0].metadata?.overviewOrdinaryRole = true
        raw.windows[0].metadata?.minimized = false
        let projection = try #require(await StageWindowEngineHost.projectGroups(raw) { key, _ in
            #expect(key.number == 9)
            return seen(9)
        })
        #expect(projection.windows[0] == raw.windows[0])
        #expect(projection.windows.allSatisfy(projection.isCurrentDesktopWindow))
        #expect(!StageWindowEngineHost.needsDirectoryRead(projection))
        #expect(raw.windows[1].metadata?.overviewOrdinaryRole == nil)
    }

    @Test func interruptedDirectoryReadCannotPublishPartialHistoryOrQueryAnotherWindow() async {
        let raw = snapshot([window(8), window(9)])
        var read = [UInt32]()
        let result = await StageWindowEngineHost.projectGroups(raw, current: { read.isEmpty }) { key, _ in
            read.append(key.number)
            return seen(key.number)
        }
        #expect(result == nil && read == [8])
    }

    @Test func foreignMembershipRebuiltWindowDisagreementAndNativeTakeoverWithholdTheCard() async throws {
        let raw = snapshot([window(8)])
        for mismatch in [seen(9), seen(8, birth: 3500), seen(8, member: 5), seen(8, bounds: .init(width: 30, height: 30))] {
            let copy = try #require(await StageWindowEngineHost.projectGroups(raw) { _, _ in mismatch })
            #expect(copy.native?.accessibility == .denied && !copy.isCurrentDesktopWindow(copy.windows[0]))
        }
        for stopped in [snapshot([window(8)], stage: true), snapshot([window(8)], stage: nil),
                        snapshot([window(8)], complete: false)] {
            #expect(await StageWindowEngineHost.projectGroups(stopped) { _, _ in Issue.record("Unexpected AX read"); return nil } == nil)
        }
    }

    @Test func theIndependentRawRosterRequiresUniqueCurrentKeysAndAKnownRole() throws {
        let a = window(8), b = window(9), remote = window(10, member: "5")
        let roster = try StageWindowEngineWitness.ordinaryRoster([a, b, remote], on: display, current: "4") { $0.number == 8 }
        #expect(roster.map(\.number) == [8])
        let unknown = window(9, membership: .unknown), sticky = window(9, membership: .known(recordIDs: ["4", "5"]))
        for invalid in [[a, a], [a, unknown], [a, sticky]] {
            #expect(throws: StageSwitchError.incomplete) {
                _ = try StageWindowEngineWitness.ordinaryRoster(invalid, on: display, current: "4") { _ in true }
            }
        }
        #expect(throws: StageSwitchError.incomplete) {
            _ = try StageWindowEngineWitness.ordinaryRoster([a], on: display, current: "4") { _ in throw StageSwitchError.incomplete }
        }
    }

    @Test func focusOnAnotherDisplayNeedsTwoInventoriesAndIndependentVisibleFocus() throws {
        let home = StageGroupScope(display: try #require(UUID(uuidString: display)), nativeSpace: space)
        let other = StageGroupScope(display: UUID(), nativeSpace: UUID())
        let key = NativeSpaceWindow(pid: 614, birth: 3400, number: 9)
        let remote = other.display.uuidString, frame = SurfaceRect(x: 924, y: 32, width: 320, height: 200)
        var first = snapshot([window(8)])
        first.displays.append(.init(id: remote, frame: .init(x: 900, width: 900, height: 700), rotationDegrees: 0, backingScale: 1,
                                    usable: .init(width: 900, height: 700)))
        first.scopes.append(.init(id: "right", displayID: remote, records: [.init(id: "16", isCurrent: true, ordinaryUUID: other.nativeSpace)]))
        first.windows.append(.init(id: "9", displayID: remote, bounds: rect, membership: .known(recordIDs: ["16"]), confidence: .unknown,
            metadata: .init(number: 9, pid: 614, launchMicroseconds: 3400, element: nil, globalFrame: frame, frontToBack: 1,
                            minimized: nil, fullScreen: nil, isOnscreen: true, onActiveDesktop: true, overviewSpaceID: "16")))
        var last = first
        last.revision += 1
        try #require(first.isStructurallyValid && last.isStructurallyValid)
        func read(_ snapshot: DesktopSnapshot, focus: NativeSpaceWindow?, visible: Bool = true) throws -> StageGroupScope {
            try StageWindowEngineWitness.foreignFocus(key, outside: home, first: first, last: snapshot) { id, place in
                #expect(id == key && place.display == remote && place.uuid == other.nativeSpace)
                return .init(id: .init(pid: 614, launch: 3400, number: 9, element: UUID()), frame: frame, membership: 16,
                             onscreen: visible, minimized: false, focus: focus)
            }
        }
        #expect(try read(last, focus: key) == other)
        #expect(throws: StageSwitchError.incomplete) { try read(last, focus: nil) }
        #expect(throws: StageSwitchError.incomplete) { try read(last, focus: key, visible: false) }
        #expect(throws: StageSwitchError.interrupted) { try read(first, focus: key) }
        last.windows.removeLast()
        #expect(throws: StageSwitchError.incomplete) { try read(last, focus: key) }
    }
}
