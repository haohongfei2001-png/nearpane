import Foundation
import NearpaneCore
import Testing

struct FullscreenRuntimeTransitionTests {
    let session = UUID()
    let window = ManagedWindowID(pid: 91, launch: 101, number: 12, element: UUID())
    var source: WorkspaceID { .native(session: session, scope: "display", record: "witnessed") }

    func sample(_ revision: UInt64, _ observation: DesktopFullscreenObservation,
                members: Set<ManagedWindowID> = [], until: Double = 120) -> FullscreenDisplaySample {
        .init(session: session, revision: revision, validUntil: until, observation: observation, ordinaryMembers: members)
    }

    func enter() -> FullscreenTransitionCoordinator {
        var state = FullscreenTransitionCoordinator()
        state.observe(sample(1, .ordinary(workspace: source), members: [window]), uptime: 100)
        state.observe(sample(2, .native(window: window)), uptime: 101)
        return state
    }

    @Test func toolSelectionIsExplicitAndOnlyAnIntactReturnEmitsASingleSourceWitness() {
        var state = enter()
        #expect(!state.toolsOpen && state.permitsTool(at: 101))
        state.clickStatusStrip()
        #expect(state.toolsOpen)
        let ordinary = sample(3, .ordinary(workspace: source), members: [window])
        let accepted = state.observe(ordinary, uptime: 105)
        #expect(accepted && state.phase == .ordinary && !state.toolsOpen)
        #expect(state.returnEvidence == .witnessedSource)
        let replay = state.observe(ordinary, uptime: 106)
        #expect(!replay)
        state.observe(sample(4, .ordinary(workspace: source), members: [window]), uptime: 106)
        #expect(state.returnEvidence == .none)
        state.observe(sample(5, .native(window: window)), uptime: 107)
        #expect(state.phase == .native && !state.toolsOpen)
    }

    @Test func lockedUnknownExpiredAndReplacedWitnessesCannotRestoreThePreviousLayout() {
        for cause in ["lock", "unknown", "expired", "same-number-new-AX", "same-number-new-PID-generation"] {
            var state = enter()
            state.clickStatusStrip()
            var returned = window
            let t: Double
            switch cause {
            case "lock":
                state.invalidatePresentation(); t = 104
            case "unknown":
                state.observe(sample(3, .unknown), uptime: 103); t = 104
            case "expired":
                t = 121 // no intermediate timer notification
            default:
                returned = .init(pid: window.pid, launch: cause.hasSuffix("generation") ? 102 : 101,
                    number: window.number, element: UUID())
                state.observe(sample(3, .native(window: returned)), uptime: 103); t = 104
            }
            let accepted = state.observe(sample(4, .ordinary(workspace: source), members: [returned], until: 130), uptime: t)
            #expect(accepted && state.phase == .ordinary && !state.toolsOpen)
            #expect(state.returnEvidence == .unconfirmedSource)
        }
    }

    @Test func closedMemberOtherWorkspaceVirtualOrMissingSourceCannotManufactureAReturn() {
        let other = WorkspaceID.native(session: session, scope: "display", record: "elsewhere")
        let returns: [(WorkspaceID, Set<ManagedWindowID>)] = [(source, []), (other, [window]), (.virtual(UUID()), [window])]
        for (workspace, members) in returns {
            var state = enter()
            state.observe(sample(3, .ordinary(workspace: workspace), members: members), uptime: 105)
            #expect(state.returnEvidence == .unconfirmedSource)
        }
        var fresh = FullscreenTransitionCoordinator()
        fresh.observe(sample(1, .native(window: window)), uptime: 101)
        fresh.observe(sample(2, .ordinary(workspace: source), members: [window]), uptime: 102)
        #expect(fresh.returnEvidence == .unconfirmedSource)
    }

    @Test func lateAndDuplicateReadCannotReopenOrSignalAnOrdinaryDesktop() {
        var state = enter()
        state.clickStatusStrip()
        let old = state.observe(sample(1, .ordinary(workspace: source), members: [window]), uptime: 101)
        let duplicate = state.observe(sample(2, .ordinary(workspace: nil)), uptime: 102)
        let foreign = state.observe(.init(session: UUID(), revision: 7, validUntil: 115,
            observation: .ordinary(workspace: nil)), uptime: 103)
        #expect(!old && !duplicate && !foreign && state.toolsOpen)
        state.invalidatePresentation()
        let replay = state.observe(sample(2, .native(window: window)), uptime: 104)
        state.clickStatusStrip()
        #expect(!replay && !state.toolsOpen && !state.permitsTool(at: 104))
        state.observe(sample(4, .native(window: window)), uptime: 105)
        #expect(!state.toolsOpen && state.permitsTool(at: 105))
    }
}
