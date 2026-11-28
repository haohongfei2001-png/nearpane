import Foundation
import Testing
@testable import NearpaneCore
@testable import NearpaneOrdinaryWindowController
@testable import NearpaneOrdinaryWindowRuntime

@MainActor struct StageHostWindowAccessTests {
    @Test func inactiveOrdinaryRecordWithoutUUIDPreservesOrderButCannotBecomeTheFocusDesktop() throws {
        let display = UUID().uuidString, currentUUID = UUID(), topology = String(repeating: "a", count: 64)
        let inactive = SpaceRecord(id: "1", isCurrent: false, observedNativeType: 0)
        let active = SpaceRecord(id: "12", isCurrent: true, ordinaryUUID: currentUUID)
        let scope = try #require(OrdinaryFocusScope(display: display, topology: topology, order: [inactive, active]))
        #expect(scope.order.map(\.id) == ["1", "12"] && scope.order[0].observedNativeType == 0)
        #expect(scope.desktop.record == "12" && scope.desktop.uuid == currentUUID)
        #expect(scope.order[0].ordinaryUUID == nil && scope.order[0].fullscreenUUID == nil)
        let current: [String: Any] = ["id64": UInt64(12), "type": 0, "uuid": currentUUID.uuidString]
        func rows(_ first: [String: Any]) -> [[String: Any]] {
            [["Display Identifier": display, "Current Space": current, "Spaces": [first, current]]]
        }
        #expect(CurrentFocusScope.inventory(rows(["id64": UInt64(1), "type": 0, "uuid": ""]), for: scope) == .confirmed)
        #expect(CurrentFocusScope.inventory(rows(["id64": UInt64(1), "type": 4, "uuid": ""]), for: scope) == .changed)
        #expect(CurrentFocusScope.inventory(rows(["id64": UInt64(1), "type": 0, "uuid": UUID().uuidString]), for: scope) == .changed)
        #expect(CurrentFocusScope.inventory(rows(["id64": UInt64(2), "type": 0, "uuid": ""]), for: scope) == .changed)
        #expect(OrdinaryFocusScope(display: display, topology: topology,
            order: [.init(id: "1", isCurrent: true, observedNativeType: 0), .init(id: "12", isCurrent: false, ordinaryUUID: currentUUID)]) == nil)
        #expect(OrdinaryFocusScope(display: display, topology: topology,
            order: [.init(id: "1", isCurrent: false), active]) == nil)
        let legacy = Data("{\"id\":\"1\",\"isCurrent\":false}".utf8)
        #expect(try JSONDecoder().decode(SpaceRecord.self, from: legacy).observedNativeType == nil)
    }

    @Test func ordinaryHelperRecognizesOnlyTheSealedCandidatesSingleModeAndExactExecutables() {
        let root = URL(fileURLWithPath: "/private/tmp/nearpane-parent-contract/Candidate.app")
        let host = root.appendingPathComponent("Contents/MacOS/NearpaneHost")
        let helper = root.appendingPathComponent("Contents/Helpers/NearpaneOrdinaryWindowController")
        func accepts(_ workspace: Any?, _ acceptance: Any?, identifier: String? = IndependentStagePolicy.candidateBundleID,
                     actualHost: URL? = nil, declared: URL? = nil, actualHelper: URL? = nil) -> Bool {
            ordinaryControllerParentMatches(helper: actualHelper ?? helper, host: actualHost ?? host, root: root,
                declaredHost: declared ?? host, identifier: identifier, workspace: workspace, acceptance: acceptance)
        }
        #expect(accepts(1, nil))
        #expect(accepts(nil, 1))
        for (workspace, acceptance) in [(nil, nil), (1, 1), (1, 0), (0, 1), (2, nil), (nil, 0)] as [(Int?, Int?)] {
            #expect(!accepts(workspace, acceptance))
        }
        #expect(!accepts("1", nil))
        #expect(!accepts(1, nil, identifier: "net.example.unrelated"))
        #expect(!accepts(1, nil, actualHost: URL(fileURLWithPath: "/private/tmp/Other.app/Contents/MacOS/NearpaneHost")))
        #expect(!accepts(1, nil, actualHost: root.appendingPathComponent("Contents/Helpers/NearpaneHost")))
        #expect(!accepts(1, nil, declared: root.appendingPathComponent("Contents/Helpers/NearpaneHost")))
        #expect(!accepts(1, nil, actualHelper: root.appendingPathComponent("Contents/MacOS/NearpaneOrdinaryWindowController")))
    }

    @Test func ordinaryHelperKeepsTheExistingAlphaParentRule() {
        let root = URL(fileURLWithPath: "/Applications/Nearpane.app")
        let host = root.appendingPathComponent("Contents/MacOS/NearpaneHost")
        let helper = root.appendingPathComponent("Contents/Helpers/NearpaneOrdinaryWindowController")
        #expect(ordinaryControllerParentMatches(helper: helper, host: host, root: root, declaredHost: host,
            identifier: "com.holdsnow.nearpane.alpha", workspace: nil, acceptance: nil))
        #expect(!ordinaryControllerParentMatches(helper: helper, host: host, root: root, declaredHost: host,
            identifier: "net.example.nearpane-sidebar-observer", workspace: nil, acceptance: nil))
    }

    @Test func hostNeedsTheCanonicalKernelExecutableAndTheApprovedSigningDigest() {
        let app = "/Applications/Nearpane.app", digest = String(repeating: "a", count: 40)
        let exe = app + "/Contents/MacOS/NearpaneHost", id = "com.holdsnow.nearpane.alpha"
        #expect(StageHostAccess.matches(bundle: id, root: app, executable: exe, expected: digest, actual: digest))
        for (bundle, root, binary, hash) in [
            (id, app, app + "/Contents/Helpers/NearpaneOrdinaryWindowController", digest),
            ("net.example.nearpane.hosted-window-switch", app, exe, digest),
            (id, "/tmp/Nearpane.app", exe, digest), (id, app, exe, String(repeating: "b", count: 40))
        ] {
            #expect(!StageHostAccess.matches(bundle: bundle, root: root, executable: binary, expected: digest, actual: hash))
        }
        #expect(!StageHostAccess.matches(bundle: id, root: app, executable: exe, expected: "test", actual: "test"))
    }

    @Test func legacyWorkerRejectsStageOperationsBeforeReadingAnOwnerOrPrompting() {
        let worker = Worker(getppid())
        let home = OrdinaryDesktopIdentity(display: UUID().uuidString, record: "3", uuid: UUID())
        for action in [OrdinaryWindowRequest.Action.stageRead, .stagePlace, .watchCreated] {
            let r = OrdinaryWindowRequest(action, pid: 0, launch: 0, bundle: "", desktop: home)
            let reply = worker.handle(r)
            #expect(reply.failure?.contains("Host") == true)
            #expect(reply.stageObservation == nil && reply.pair == nil && reply.created == nil)
        }
    }

    @Test func aStageLayoutOrFocusRequiresTheOriginalOwnerWindowLifetimeAndOrdinarySpace() {
        let epoch = UUID(), life = UUID(), scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
        let id = ManagedWindowID(pid: 12, launch: 24, number: 9, element: UUID())
        let home = OrdinaryDesktopIdentity(display: scope.display.uuidString, record: "8", uuid: scope.nativeSpace)
        let env = StageEngineEnvironment(osBuild: "fixture", engineRevision: "fixture", hostCDHash: "fixture",
            hardware: "fixture", topology: "fixture", windowClass: "ordinary", sipEnabled: true)
        let owner = StageEngineOwner(qualification: .init(backend: .corner, environment: env, evidence: UUID(), checks: [:]), generation: epoch)
        let rect = SurfaceRect(x: 20, y: 20, width: 400, height: 300)
        let state = StageWindowState(window: .init(pid: id.pid, birth: id.launch, number: id.number), lifetime: life,
                                     frame: rect, visibility: .visible)
        func make(_ action: StageWindowAction, epoch generation: UUID? = nil, record: UInt64 = 8,
                  restoring: Bool = false) -> StageWindowCommand {
            .init(intent: UUID(), group: UUID(), member: UUID(), generation: generation ?? epoch, scope: scope,
                  nativeID: record, action: action, before: state, restoring: restoring, restoreFrame: nil)
        }
        for action in [StageWindowAction.focus, .place(rect)] {
            let wanted = make(action)
            #expect(StageHostWindow.matches(wanted, id: id, lifetime: life, home: home, owner: owner))
            let next = ManagedWindowID(pid: id.pid, launch: id.launch + 1, number: id.number, element: UUID())
            #expect(!StageHostWindow.matches(wanted, id: next, lifetime: life, home: home, owner: owner))
            #expect(!StageHostWindow.matches(wanted, id: id, lifetime: nil, home: home, owner: owner))
            #expect(!StageHostWindow.matches(wanted, id: id, lifetime: UUID(), home: home, owner: owner))
            for wrong in [make(action, epoch: UUID()), make(action, record: 9), make(action, restoring: true)] {
                #expect(!StageHostWindow.matches(wrong, id: id, lifetime: life, home: home, owner: owner))
            }
            let moved = OrdinaryDesktopIdentity(display: home.display, record: home.record, uuid: UUID())
            #expect(!StageHostWindow.matches(wanted, id: id, lifetime: life, home: moved, owner: owner))
        }
        for action in [StageWindowAction.hide, .show] {
            #expect(!StageHostWindow.matches(make(action), id: id, lifetime: life, home: home, owner: owner))
        }
    }

    @Test func physicalInputRevocationDeadlineAndPrimitiveLimitEachEndTheIntent() throws {
        var fence = StageHostWindow.PrimitiveFence(now: 20, input: [2, 3, 4, 5, 6])
        try fence.check(now: 21, input: fence.originalInput, current: true)
        #expect(throws: StageSwitchError.interrupted) { try fence.check(now: 21, input: [2, 3, 5, 5, 6], current: true) }
        #expect(throws: StageSwitchError.interrupted) { try fence.check(now: 25, input: fence.originalInput, current: true) }
        #expect(throws: StageSwitchError.interrupted) { try fence.check(now: 21, input: fence.originalInput, current: false) }
        for _ in 0..<8 { try fence.check(now: 21, input: fence.originalInput, current: true); fence.next() }
        #expect(throws: StageSwitchError.interrupted) { try fence.check(now: 21, input: fence.originalInput, current: true) }
    }
}
