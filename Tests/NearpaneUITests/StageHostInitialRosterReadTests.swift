import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct StageHostInitialRosterReadTests {
    private let fixture = StageHostGroupProjectionTests()
    private let session = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var scope: StageGroupScope { .init(display: UUID(uuidString: fixture.display)!, nativeSpace: fixture.space) }
    private var authorized: Set<NativeSpaceWindow> {
        Set([53, 55, 56].map { .init(pid: 614, birth: 3400, number: $0) })
    }

    private func window(_ number: UInt32, rank: Int, pid: Int32 = 614, birth: UInt64 = 3400,
                        frame: SurfaceRect? = nil, membership: WindowMembership = .known(recordIDs: ["4"])) -> WindowObservation {
        let rect = frame ?? fixture.rect
        return .init(id: "\(pid)/\(birth)/\(number)", displayID: fixture.display, bounds: rect,
            membership: membership, confidence: .unknown,
            metadata: .init(number: number, pid: pid, launchMicroseconds: birth, element: nil,
                globalFrame: rect, frontToBack: rank, minimized: false, fullScreen: false,
                isOnscreen: true, onActiveDesktop: true, overviewSpaceID: "4", overviewOrdinaryRole: true))
    }

    private func snapshot(complete: Bool, revision: UInt64 = 5, windows: [WindowObservation]? = nil,
                          issues: [String]? = nil, began: Double = 10, ended: Double = 11) -> DesktopSnapshot {
        let rows = windows ?? [window(53, rank: 0), window(55, rank: 1), window(56, rank: 2)]
        var sample = fixture.snapshot(rows, request: .init(session: session, revision: revision,
            parentPID: 1, fixtureWindows: nil, anchors: [], experimentalSpaces: false), accessibility: .partial)
        sample.sampledFrom = date.addingTimeInterval(began)
        sample.sampledTo = date.addingTimeInterval(ended)
        sample.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [],
            windowLimitReached: false, beganUptime: began, endedUptime: ended,
            stageManagerEnabled: false, catalogComplete: complete)
        sample.native?.catalogIssues = issues ?? (complete ? nil : ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86"])
        return sample
    }

    private func fresh() -> DesktopSnapshot { snapshot(complete: true, revision: 6, began: 13, ended: 14) }

    private func opening(_ first: DesktopSnapshot,
                         state: @MainActor () -> StageWindowEngineWitness.InitialReadState = { .init() },
                         current: @MainActor () -> Bool = { true },
                         read: @MainActor () async -> DesktopSnapshot?) async throws -> DesktopSnapshot {
        var tick = 0
        let instants = [11.5, 12.0, 15.0]
        return try await StageWindowEngineWitness.initialOpeningDirectory(first, display: fixture.display, scope: scope,
            session: session, topology: "fixture", authorized: authorized, state: state, current: current, read: read,
            clock: {
                let now = instants[min(tick, instants.count - 1)]
                tick += 1
                return (date.addingTimeInterval(now), now)
            })
    }

    @Test func oneRosterChangeUsesOnlyTheLaterCompleteDirectoryWithoutRepairingTheFailedOne() async throws {
        let first = snapshot(complete: false)
        let later = snapshot(complete: true, revision: 6,
            windows: [window(53, rank: 0), window(55, rank: 1), window(56, rank: 2), window(86, rank: 3)], began: 13, ended: 14)
        var reads = 0
        let result = try await opening(first) { reads += 1; return later }
        #expect(reads == 1 && result == later)
        #expect(first.native?.catalogComplete == false && first.windows.count == 3)
        #expect(result.windows.count == 4 && result.revision > first.revision)
        #expect(result.sampledFrom > date.addingTimeInterval(12) && result.native!.beganUptime > 12)
    }

    @Test func aSecondIncompleteDirectoryFailsAfterExactlyOneFreshRead() async {
        var reads = 0
        await #expect(throws: StageSwitchError.incomplete) {
            try await opening(snapshot(complete: false)) {
                reads += 1
                return snapshot(complete: false, revision: 6, began: 13, ended: 14)
            }
        }
        #expect(reads == 1)
    }

    @Test(arguments: ["sequence", "bindings", "claims", "enrolled", "specialized"])
    func anExistingOrSpecializedWitnessNeverRetries(_ change: String) async throws {
        var state = StageWindowEngineWitness.InitialReadState()
        switch change {
        case "sequence": state.sequence = 1
        case "bindings": state.bindings = 1
        case "claims": state.claims = 1
        case "enrolled": state.enrolled = true
        default: state.specialized = true
        }
        let first = snapshot(complete: false)
        var reads = 0
        let result = try await opening(first, state: { state }) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: [[], ["windowIdentityOrBounds:pid=614,window=86"],
        ["windowRosterChanged", "backgroundRosterIncomplete"], ["windowRosterChanged", "nativeInventoryUnavailable"],
        ["windowRosterChanged", "membershipDisplayMismatch:pid=614,window=86"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=53"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86,extra=1"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=0,window=86"],
        ["windowRosterChanged", "windowRosterChanged"],
        ["windowRosterChanged"] + Array(repeating: "windowIdentityOrBounds:pid=614,window=86", count: 31)])
    func otherOrPotentiallyTruncatedIssuesCannotAuthorizeARetry(_ issues: [String]) async throws {
        let first = snapshot(complete: false, issues: issues)
        var reads = 0
        let result = try await opening(first) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: ["session", "topology", "space", "stale", "permission", "complete"])
    func aLostInitialContextCannotRequestAnotherDirectory(_ change: String) async throws {
        var first = snapshot(complete: change == "complete")
        switch change {
        case "session": first.sessionID = UUID()
        case "topology": first.topologyFingerprint = "changed"
        case "space": first.scopes = [.init(id: "scope", displayID: fixture.display,
            records: [.init(id: "4", isCurrent: true, ordinaryUUID: UUID())])]
        case "stale": first.freshness = .stale
        default: break
        }
        var reads = 0
        if change == "permission" {
            await #expect(throws: StageSwitchError.interrupted) {
                try await opening(first, current: { false }) { reads += 1; return fresh() }
            }
        } else {
            let result = try await opening(first) { reads += 1; return fresh() }
            #expect(result == first)
        }
        #expect(reads == 0)
    }

    @Test(arguments: ["session", "topology", "scope", "display", "identity", "targetFrame", "membership",
                      "missingAuthorized", "sameRevision", "wallBefore", "wallEqual", "nativeBefore", "nativeEqual"])
    func aFreshResponseCannotChangeIdentityScopeTargetOrTheSamplingBoundary(_ change: String) async {
        var later = fresh()
        switch change {
        case "session": later.sessionID = UUID()
        case "topology": later.topologyFingerprint = "changed"
        case "scope": later.scopes = [.init(id: "scope", displayID: fixture.display,
            records: [.init(id: "4", isCurrent: true, ordinaryUUID: UUID())])]
        case "display": later.displays[0].usable = .init(width: 800, height: 700)
        case "identity": later.windows[0] = window(53, rank: 0, birth: 3401)
        case "targetFrame": later.windows[0] = window(53, rank: 0, frame: .init(x: 25, y: 32, width: 320, height: 200))
        case "membership": later.windows[0] = window(53, rank: 0, membership: .unknown)
        case "missingAuthorized": later.windows.removeFirst()
        case "sameRevision": later.revision = 5
        case "wallBefore": later.sampledFrom = date.addingTimeInterval(11.9)
        case "wallEqual": later.sampledFrom = date.addingTimeInterval(12)
        default:
            later.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [],
                windowLimitReached: false, beganUptime: change == "nativeBefore" ? 11.9 : 12, endedUptime: 14,
                stageManagerEnabled: false, catalogComplete: true)
        }
        var reads = 0
        await #expect(throws: StageSwitchError.self) {
            try await opening(snapshot(complete: false)) { reads += 1; return later }
        }
        #expect(reads == 1)
    }

    @Test(arguments: ["intent", "sequence", "bindings", "claims", "enrolled", "specialized", "cancelled"])
    func theOriginalSelectionAndUnenrolledStateMustSurviveTheAwait(_ change: String) async {
        var state = StageWindowEngineWitness.InitialReadState(), current = true, reads = 0
        let job = Task {
            try await opening(snapshot(complete: false), state: { state }, current: { current }) {
                reads += 1
                switch change {
                case "sequence": state.sequence = 1
                case "bindings": state.bindings = 1
                case "claims": state.claims = 1
                case "enrolled": state.enrolled = true
                case "specialized": state.specialized = true
                case "cancelled": withUnsafeCurrentTask { $0?.cancel() }
                default: current = false
                }
                return fresh()
            }
        }
        await #expect(throws: StageSwitchError.interrupted) { try await job.value }
        #expect(reads == 1)
    }
}
