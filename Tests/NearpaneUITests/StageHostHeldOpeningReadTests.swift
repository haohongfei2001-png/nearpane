import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct StageHostHeldOpeningReadTests {
    private let fixture = StageHostGroupProjectionTests()
    private let session = UUID(), lifetime = UUID(), otherSpace = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var scope: StageGroupScope { .init(display: UUID(uuidString: fixture.display)!, nativeSpace: fixture.space) }
    private func key(_ number: UInt32, pid: Int32 = 614, birth: UInt64 = 3400) -> NativeSpaceWindow {
        .init(pid: pid, birth: birth, number: number)
    }
    private var states: [NativeSpaceWindow: StageWindowState] {
        Dictionary(uniqueKeysWithValues: [UInt32(53), 55, 56].map { number in
            let k = key(number)
            return (k, .init(window: k, lifetime: lifetime, frame: fixture.rect,
                visibility: number == 55 ? .stageSpace : .visible, hiddenSpaceID: number == 55 ? 91 : nil))
        })
    }
    private var authorized: Set<NativeSpaceWindow> { [key(53), key(55)] } // 56 is retained read-only.
    private func window(_ number: UInt32, pid: Int32 = 614, birth: UInt64 = 3400,
                        membership: WindowMembership = .known(recordIDs: ["4"]), role: Bool? = true,
                        frame: SurfaceRect? = nil) -> WindowObservation {
        let rect = frame ?? fixture.rect
        return .init(id: "\(pid)/\(birth)/\(number)", displayID: fixture.display, bounds: rect,
            membership: membership, confidence: .unknown,
            metadata: .init(number: number, pid: pid, launchMicroseconds: birth, element: nil,
                globalFrame: rect, frontToBack: Int(number), minimized: false, fullScreen: false,
                isOnscreen: true, onActiveDesktop: true, overviewOrdinaryRole: role))
    }
    private func detail(number: UInt32 = 86, pid: Int32 = 614, birth: UInt64? = 3400,
                        first: CatalogIssueWindowFacts.Sample? = nil, membership: WindowMembership? = nil,
                        role: Bool? = nil) -> CatalogIssueWindowFacts {
        let sample = CatalogIssueWindowFacts.Sample(pid: pid, birth: birth, frame: fixture.rect,
            reportedOnscreen: true, observedOnscreen: true, active: true, ordered: true, ownerUnhidden: true)
        return .init(issueIndex: 1, number: number, first: first, second: sample,
            left: membership, right: membership,
            role: .init(firstPID: first?.pid, source: role == nil ? .notRequested : .current,
                ownerRead: role != nil, windowRead: role != nil, everyNumberKnown: nil,
                allRolesRead: nil, ordinary: role, minimized: nil, fullscreen: nil))
    }
    private func snapshot(complete: Bool, newSurface: Bool = true, revision: UInt64 = 5,
                          began: Double = 10, ended: Double = 11) -> DesktopSnapshot {
        var sample = fixture.snapshot([window(53), window(56)], request: .init(session: session, revision: revision,
            parentPID: 1, fixtureWindows: nil, anchors: [], experimentalSpaces: false), accessibility: .partial)
        sample.scopes = [.init(id: "scope", displayID: fixture.display, records: [
            .init(id: "4", isCurrent: true, ordinaryUUID: fixture.space),
            .init(id: "5", isCurrent: false, ordinaryUUID: otherSpace), .init(id: "91", isCurrent: false)])]
        sample.sampledFrom = date.addingTimeInterval(began); sample.sampledTo = date.addingTimeInterval(ended)
        sample.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [],
            windowLimitReached: false, beganUptime: began, endedUptime: ended,
            stageManagerEnabled: false, catalogComplete: complete)
        if !complete {
            sample.native?.catalogIssues = newSurface
                ? ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86"] : ["windowRosterChanged"]
            sample.native?.catalogIssueWindows = newSurface ? [detail()] : nil
        }
        return sample
    }
    private func fresh() -> DesktopSnapshot { snapshot(complete: true, revision: 6, began: 13, ended: 14) }
    private func opening(_ first: DesktopSnapshot, current: @MainActor () -> Bool = { true },
                         read: @MainActor () async -> DesktopSnapshot?) async throws -> DesktopSnapshot {
        var tick = 0
        let instants = [11.5, 12.0, 15.0]
        return try await StageWindowEngineWitness.heldOpeningDirectory(first, display: fixture.display, scope: scope,
            session: session, topology: "fixture", nativeID: 4, retained: Set(states.keys), authorized: authorized,
            expected: states, current: current, read: read, clock: {
                let now = instants[min(tick, instants.count - 1)]; tick += 1
                return (date.addingTimeInterval(now), now)
            })
    }

    @Test(arguments: [false, true])
    func aHeldPreparationUsesOneWholeNewDirectoryAndKeepsTheHiddenOriginal(newSurface: Bool) async throws {
        let first = snapshot(complete: false, newSurface: newSurface), later = fresh()
        var reads = 0
        let result = try await opening(first) { reads += 1; return later }
        #expect(reads == 1 && result == later && first.native?.catalogComplete == false)
        #expect(!result.windows.contains { $0.metadata?.number == 55 })
        #expect(states[key(55)]?.visibility == .stageSpace && states[key(55)]?.hiddenSpaceID == 91)
    }

    @Test(arguments: [false, true])
    func aCompleteReplacementExposesANewOrdinaryWindowToTheOriginalRoster(ordinary: Bool) async throws {
        var later = fresh(); later.windows.append(window(86, role: ordinary))
        let result = try await opening(snapshot(complete: false)) { later }
        var roleReads = [UInt32]()
        let roster = try StageWindowEngineWitness.ordinaryRoster(result.windows, on: fixture.display, current: "4") { key in
            roleReads.append(key.number)
            return key.number != 86 || ordinary
        }
        #expect(Set(roleReads) == [53, 56, 86])
        #expect(roster == (ordinary ? [key(53), key(56), key(86)] : [key(53), key(56)]))
        // This is the unchanged original membership boundary before retained AX reads.
        #expect(roster.isSubset(of: Set(states.keys)) == !ordinary)
    }

    @Test(arguments: ["missingFacts", "firstPresent", "retainedNumber", "readonlyNumber", "unknownBirth",
                      "knownMembership", "knownRole", "otherIssue", "cappedIssues", "extraFacts"])
    func missingOrConflictingFailureFactsCannotStartAnotherRead(_ change: String) async throws {
        var first = snapshot(complete: false)
        switch change {
        case "missingFacts": first.native?.catalogIssueWindows = nil
        case "firstPresent": first.native?.catalogIssueWindows = [detail(first: detail().second)]
        case "retainedNumber", "readonlyNumber":
            let number: UInt32 = change == "retainedNumber" ? 55 : 56
            first.native?.catalogIssues = ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=\(number)"]
            first.native?.catalogIssueWindows = [detail(number: number)]
        case "unknownBirth": first.native?.catalogIssueWindows = [detail(birth: nil)]
        case "knownMembership": first.native?.catalogIssueWindows = [detail(membership: .known(recordIDs: ["4"]))]
        case "knownRole": first.native?.catalogIssueWindows = [detail(role: true)]
        case "otherIssue": first.native?.catalogIssues = ["windowRosterChanged", "membershipChanged:pid=614,window=86"]
        case "cappedIssues": first.native?.catalogIssues = ["windowRosterChanged"] + Array(repeating: "windowIdentityOrBounds:pid=614,window=86", count: 31)
        default: first.native?.catalogIssueWindows = [detail(), detail()]
        }
        var reads = 0
        let result = try await opening(first) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: ["visibleMissing", "readonlyMissing", "readonlyFrame", "readonlyOwner", "readonlyBirth",
                      "visibleMembership", "hiddenOwner", "hiddenVisible", "knownNewOrdinary"])
    func aRetainedConflictCannotDisappearBehindResampling(_ change: String) async throws {
        var first = snapshot(complete: false, newSurface: false)
        switch change {
        case "visibleMissing": first.windows.removeFirst()
        case "readonlyMissing": first.windows.removeLast()
        case "readonlyFrame": first.windows[1] = window(56, frame: .init(x: 80, y: 32, width: 320, height: 200))
        case "readonlyOwner": first.windows[1] = window(56, pid: 615)
        case "readonlyBirth": first.windows[1] = window(56, birth: 3401)
        case "visibleMembership": first.windows[0] = window(53, membership: .known(recordIDs: ["5"]))
        case "hiddenOwner": first.windows.append(window(55, pid: 615, membership: .known(recordIDs: ["91"])))
        case "hiddenVisible": first.windows.append(window(55))
        default: first.windows.append(window(88))
        }
        #expect(first.isStructurallyValid)
        var reads = 0
        let result = try await opening(first) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: [false, true])
    func anUnboundMembershipConflictIsNotErasedWhenItsRowDisappears(unknown: Bool) async throws {
        var first = snapshot(complete: false, newSurface: false)
        first.windows.append(window(88, membership: unknown ? .unknown : .known(recordIDs: ["4", "5"]), role: false))
        #expect(first.isStructurallyValid)
        var reads = 0
        let result = try await opening(first) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: ["incomplete", "sameRevision", "wallBoundary", "nativeBoundary", "scope", "display",
                      "retainedFrame", "retainedMembership", "newOwner", "newBirth", "newFrame"])
    func theOnlyReplacementMustBeCompleteLaterAndKeepKnownEvidence(_ change: String) async {
        var later = fresh()
        switch change {
        case "incomplete": later = snapshot(complete: false, newSurface: false, revision: 6, began: 13, ended: 14)
        case "sameRevision": later.revision = 5
        case "wallBoundary": later.sampledFrom = date.addingTimeInterval(12)
        case "nativeBoundary": later.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed,
            rows: [], windowLimitReached: false, beganUptime: 12, endedUptime: 14, stageManagerEnabled: false, catalogComplete: true)
        case "scope": later.scopes = [.init(id: "scope", displayID: fixture.display,
            records: [.init(id: "4", isCurrent: true, ordinaryUUID: UUID())])]
        case "display": later.displays[0].usable = .init(width: 800, height: 600)
        case "retainedFrame": later.windows[1] = window(56, frame: .init(x: 80, y: 32, width: 320, height: 200))
        case "retainedMembership": later.windows[1] = window(56, membership: .known(recordIDs: ["5"]))
        case "newOwner": later.windows.append(window(86, pid: 615, role: false))
        case "newBirth": later.windows.append(window(86, birth: 3401, role: false))
        default: later.windows.append(window(86, role: false, frame: .init(x: 80, y: 32, width: 320, height: 200)))
        }
        var reads = 0
        await #expect(throws: (any Error).self) {
            try await opening(snapshot(complete: false)) { reads += 1; return later }
        }
        #expect(reads == 1)
    }

    @Test(arguments: [false, true])
    func currentSelectionMustSurviveBothSidesOfTheOnlyFreshRead(lostAfterRead: Bool) async {
        var current = lostAfterRead, reads = 0
        await #expect(throws: StageSwitchError.interrupted) {
            try await opening(snapshot(complete: false), current: { current }) {
                reads += 1; current = false; return fresh()
            }
        }
        #expect(reads == (lostAfterRead ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringTheReplacementCannotReturnACompleteResult() async throws {
        let started = AsyncStream<Void>.makeStream(), reply = AsyncStream<DesktopSnapshot>.makeStream()
        let later = fresh()
        let task = Task { try await opening(snapshot(complete: false)) {
            started.continuation.yield(()); started.continuation.finish()
            var iterator = reply.stream.makeAsyncIterator()
            return await iterator.next()
        } }
        defer { task.cancel(); started.continuation.finish(); reply.continuation.finish() }
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        task.cancel(); reply.continuation.yield(later); reply.continuation.finish()
        await #expect(throws: StageSwitchError.interrupted) { try await task.value }
    }
}
