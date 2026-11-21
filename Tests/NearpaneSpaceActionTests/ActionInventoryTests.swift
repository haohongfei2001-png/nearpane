import ApplicationServices
import Foundation
import Testing
import NearpaneCore
@testable import NearpaneSpaceAction

struct ActionInventoryTests {
    let display = UUID(), a = UUID(), b = UUID()

    func inventory(_ current: String, session: Int = 4) -> ActionInventory {
        .init(displays: [display: .init(number: 3, bounds: CGRect(x: -800, y: 0, width: 800, height: 1280),
                                       current: current, spaces: [.init(id: "3", uuid: a, kind: .ordinary),
                                                                  .init(id: "7", uuid: b, kind: .ordinary)])],
              session: session)
    }

    @Test func testRouteBindsBothSpaceUUIDsAndDisplay() throws {
        let request = NativeSpaceCommand(id: UUID(), action: .select, display: display.uuidString,
                                         source: "3", target: "7", sourceUUID: a, targetUUID: b)
        #expect(try inventory("3").route(request).2 == 1)
        #expect(throws: ActionFailure.self) { try inventory("7").route(request) }
        for uuid in [UUID(), nil] as [UUID?] {
            let replaced = NativeSpaceCommand(id: UUID(), action: .select, display: display.uuidString,
                                               source: "3", target: "7", sourceUUID: a, targetUUID: uuid)
            #expect(throws: ActionFailure.self) { try inventory("3").route(replaced) }
        }
    }

    @Test func testReadbackRequiresExpectedCurrentAndOriginalSession() {
        let before = inventory("3"), after = inventory("7")
        #expect(!before.agrees(with: before, expected: after.currents))
        #expect(after.agrees(with: before, expected: after.currents))
        #expect(!inventory("7", session: 5).agrees(with: before, expected: after.currents))
    }
    @Test func rejectsIntermediateBounceAndUnrelatedDisplayMovement() throws {
        let other = UUID()
        func sample(_ index: Int, _ secondary: String) -> ActionInventory {
            let original = inventory("3").displays[display]!
            let third = ActionInventory.Space(id: "11", uuid: other, kind: .ordinary)
            let spaces = original.spaces + [third]
            return .init(displays: [
                display: .init(number: 3, bounds: original.bounds, current: spaces[index].id, spaces: spaces),
                other: .init(number: 5, bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), current: secondary,
                             spaces: [.init(id: "12", uuid: nil, kind: .ordinary), .init(id: "13", uuid: nil, kind: .ordinary)])
            ], session: 4)
        }
        let start = sample(0, "12")
        let command = NativeSpaceCommand(id: UUID(), action: .select, display: display.uuidString,
                                        source: "3", target: "7", sourceUUID: a, targetUUID: b)
        #expect(try sample(1, "12").transition(from: start, request: command, previous: 0) == 1)
        #expect(throws: ActionFailure.self) { try sample(0, "12").transition(from: start, request: command, previous: 1) }
        #expect(throws: ActionFailure.self) { try sample(2, "13").transition(from: start, request: command, previous: 1) }
    }
    @Test func fullscreenEndpointsBindKindAndRejectMovesAndUnselectedFullscreenTransit() throws {
        let full = UUID(), last = UUID()
        func three(current: String) -> ActionInventory {
            .init(displays: [display: .init(number: 3, bounds: .init(x: 0, y: 0, width: 900, height: 600), current: current,
                spaces: [.init(id: "3", uuid: a, kind: .ordinary), .init(id: "4", uuid: full, kind: .fullscreen),
                         .init(id: "5", uuid: last, kind: .ordinary)])], session: 4)
        }
        func request(_ action: NativeSpaceCommand.Action, source: String = "3", target: String = "4",
                     sourceUUID: UUID? = nil, targetUUID: UUID? = nil,
                     sourceKind: NativeSpaceKind = .ordinary, targetKind: NativeSpaceKind = .fullscreen) -> NativeSpaceCommand {
            .init(id: UUID(), action: action, display: display.uuidString, source: source, target: target,
                  sourceUUID: sourceUUID ?? a, targetUUID: targetUUID ?? full, sourceKind: sourceKind, targetKind: targetKind)
        }
        #expect(try three(current: "3").route(request(.select)).2 == 1)
        #expect(try three(current: "4").route(request(.select, source: "4", target: "3", sourceUUID: full,
                                                       targetUUID: a, sourceKind: .fullscreen, targetKind: .ordinary)).2 == 0)
        #expect(throws: ActionFailure.self) { try three(current: "3").route(request(.move)) }
        #expect(throws: ActionFailure.self) { try three(current: "3").route(request(.select, targetKind: .ordinary)) }
        #expect(throws: ActionFailure.self) { try three(current: "3").route(request(.select, target: "5",
                                                                                    targetUUID: last, targetKind: .ordinary)) }
    }

    @Test func finalMoveRequiresTheExactUnusedPermitAndUnchangedWindowWithinItsDeadline() throws {
        let command = NativeSpaceCommand(id: UUID(), action: .move, display: "display", source: "A", target: "B",
                                         confirmMoveBeforeSubmission: true, createdAtUptime: 10)
        let yes = NativeSpaceStepPermission(id: command.id, submittedSteps: 0, proceed: true)
        let wrong = NativeSpaceStepPermission(id: UUID(), submittedSteps: 0, proceed: true)
        let repeated = NativeSpaceStepPermission(id: command.id, submittedSteps: 1, proceed: true)
        let denied = NativeSpaceStepPermission(id: command.id, submittedSteps: 0, proceed: false)
        var instant = 12.0, writes = 0
        func deliver(_ permit: NativeSpaceStepPermission, verify: () throws -> Void = {}) throws {
            try submitPreparedMove(command, now: { instant }, authorize: { permit }, verify: verify,
                                   submit: { _ in writes += 1 })
        }
        for permit in [wrong, repeated, denied] {
            #expect(throws: ActionFailure.self) { try deliver(permit) }
        }
        #expect(throws: ActionFailure.self) { try deliver(yes) { throw ActionFailure("window changed") } }
        #expect(throws: ActionFailure.self) { try deliver(yes) { instant = 15 } }
        #expect(writes == 0)
        instant = 12
        try deliver(yes)
        #expect(writes == 1)
    }

    @Test func oldMoveWireFormRetainsItsIndependentWindowVerification() throws {
        let old = NativeSpaceCommand(id: UUID(), action: .move, display: "display", source: "A", target: "B", createdAtUptime: 10)
        let data = try JSONEncoder().encode(old)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["confirmMoveBeforeSubmission"] == nil)
        let decoded = try JSONDecoder().decode(NativeSpaceCommand.self, from: data)
        var phases = [String]()
        let permission = NativeSpaceStepPermission(id: old.id, submittedSteps: 0, proceed: true)
        #expect(!permission.permits(decoded, after: 0, now: 11))
        try submitPreparedMove(decoded, now: { 11 }, authorize: { phases.append("unexpected permit"); return permission },
                               verify: { phases.append("window verified") }, submit: { _ in phases.append("issued") })
        #expect(phases == ["window verified", "issued"])
    }

    @Test func stepAuthorizationIsBoundToRequestStepAndDeadline() {
        let command = NativeSpaceCommand(id: UUID(), action: .select, display: "", source: "", target: "", createdAtUptime: 10)
        let consent = NativeSpaceStepPermission(id: command.id, submittedSteps: 2, proceed: true)
        #expect(consent.permits(command, after: 2, now: 12))
        #expect(!consent.permits(command, after: 1, now: 12))
        #expect(!consent.permits(command, after: 2, now: 15))
        #expect(!consent.permits(command, after: 2, now: 9))
        #expect(!NativeSpaceStepPermission(id: UUID(), submittedSteps: 2, proceed: true).permits(command, after: 2, now: 12))
        #expect(!NativeSpaceStepPermission(id: command.id, submittedSteps: 2, proceed: false).permits(command, after: 2, now: 12))
    }

    @Test func helperHandshakeReadsOneCancellationAndTimesOutOnPartialPipe() throws {
        let id = UUID(), channel = Pipe(), replies = Pipe()
        let request = NativeSpaceReply(id: id, state: .awaitingStep, detail: "", canSwitch: true, canMove: false,
                                       submittedSteps: 1)
        let decision = NativeSpaceStepPermission(id: id, submittedSteps: 1, proceed: false)
        try channel.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(decision) + Data([10]))
        let received = try StepHandshake.exchange(request, input: channel.fileHandleForReading, output: replies.fileHandleForWriting)
        #expect(received.id == id && received.submittedSteps == 1 && !received.proceed)
        try replies.fileHandleForWriting.close()
        let data = try replies.fileHandleForReading.read(upToCount: 2048)
        let envelope = try #require(data)
        #expect(try JSONDecoder().decode(NativeSpaceReply.self, from: envelope).state == .awaitingStep)

        let delayedReplies = Pipe()
        try channel.fileHandleForWriting.write(contentsOf: Data([123]))
        #expect(throws: ActionFailure.self) {
            try StepHandshake.exchange(request, input: channel.fileHandleForReading,
                                       output: delayedReplies.fileHandleForWriting, timeout: 0.03)
        }
    }
    @Test func closedOrRebuiltSelectionRejectsTheNextCrossDesktopStep() throws {
        // Local opaque AX objects only. No AX reads, input events, or windows are created.
        let original = AXUIElementCreateApplication(401)
        var current: AXUIElement? = original
        let selection = try SelectedWindowWitness {
            guard let current else { throw ActionFailure("source closed") }
            return current
        }
        try selection.verify()
        current = nil
        #expect(throws: ActionFailure.self) { try selection.verify() }
        current = AXUIElementCreateApplication(402)
        #expect(throws: ActionFailure.self) { try selection.verify() }
    }

}
