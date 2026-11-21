import ApplicationServices
import CNativeSpaceActions
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneSpaceAction

/// Opaque local AX references stand in for exact generations. No live window is queried.
struct MoveReadbackTests {
    let screen = UUID(), source = UUID(), destination = UUID(), elsewhere = UUID()
    let target = AXUIElementCreateApplication(40301), sibling = AXUIElementCreateApplication(40302)
    let replaced = AXUIElementCreateApplication(40303)
    let number: UInt32 = 21, other: UInt32 = 22, hiddenSurface: UInt32 = 23

    func witness(birth: UInt64 = 940, targetHandle: AXUIElement? = nil, siblingHandle: AXUIElement? = nil,
                 siblingSpaces: [String] = ["8"], hiddenSpaces: [String] = []) -> WindowWitness {
        .init(identity: .init(pid: 40300, birth: birth, number: number), element: targetHandle ?? target,
              frame: CGRect(x: 30, y: 60, width: 540, height: 300),
              siblings: [other: .init(element: siblingHandle ?? sibling, spaces: siblingSpaces)],
              otherCGSurfaces: [hiddenSurface: hiddenSpaces])
    }

    var inventory: ActionInventory {
        .init(displays: [screen: .init(number: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 600), current: "8",
              spaces: [.init(id: "8", uuid: source, kind: .ordinary),
                       .init(id: "9", uuid: destination, kind: .ordinary),
                       .init(id: "10", uuid: elsewhere, kind: .ordinary)])], session: 5)
    }

    func move(targetUUID: UUID? = nil, birth: UInt64 = 940) -> NativeSpaceCommand {
        .init(id: UUID(), action: .move, display: screen.uuidString, source: "8", target: "9", sourceUUID: source,
              targetUUID: targetUUID ?? destination, window: witness(birth: birth).identity, createdAtUptime: 10)
    }

    var landed: [String: Set<UInt32>] { ["8": [other], "9": [number], "10": []] }

    func read(_ reverse: [String]?, _ members: [String: Set<UInt32>], rebound: WindowWitness? = nil,
              command: NativeSpaceCommand? = nil, now: () -> TimeInterval = { 11 }) throws -> [String] {
        let original = witness()
        return try original.verifiedMoveMembership(command ?? move(), rebound: rebound ?? original, inventory: inventory,
            reverse: { $0 == number ? reverse : nil }, members: { members[$0] }, now: now)
    }

    @Test func returnValueCannotConfirmTheTargetUntilBothMembershipDirectionsAgree() throws {
        #expect(try read(["8"], ["8": [number, other], "9": [], "10": []]) == ["8"])
        #expect(try read(["9"], landed) == ["9"])
        for spaces: [String]? in [nil, [], ["8", "9"], ["10"]] {
            #expect(throws: ActionFailure.self) { try read(spaces, landed) }
        }
        #expect(throws: ActionFailure.self) { try read(["8"], landed) }
    }

    @Test func requiresIndependentPositiveAndNegativeReadsForEachSourceTargetAndSibling() {
        var mutations = [[String: Set<UInt32>]]()
        for space in ["8", "9", "10"] {
            var missing = landed
            missing.removeValue(forKey: space)
            mutations.append(missing)
        }
        for (space, numbers): (String, Set<UInt32>) in [
            ("9", []), ("8", [number, other]), ("10", [number]),  // target absent or also elsewhere
            ("8", []), ("9", [number, other]), ("10", [other]),   // sibling moved or became shared
            ("10", [hiddenSurface])                               // previously unassigned surface moved
        ] {
            var changed = landed
            changed[space] = numbers
            mutations.append(changed)
        }
        for change in mutations {
            #expect(throws: ActionFailure.self) { try read(["9"], change) }
        }
    }

    @Test func reusedWindowProcessSiblingOrManagedSpaceCannotSatisfyReadback() {
        for change in [witness(birth: 941), witness(targetHandle: replaced), witness(siblingHandle: replaced),
                       witness(siblingSpaces: ["9"]), witness(hiddenSpaces: ["9"])] {
            #expect(throws: ActionFailure.self) { try read(["9"], landed, rebound: change) }
        }
        for command in [move(birth: 941), move(targetUUID: UUID())] {
            #expect(throws: ActionFailure.self) { try read(["9"], landed, command: command) }
        }
    }

    @Test func expirationInsideTheIndependentReadRefusesConfirmation() {
        var reads = 0
        #expect(throws: ActionFailure.self) {
            try read(["9"], landed, now: {
                reads += 1
                return reads > 2 ? 15 : 11
            })
        }
        #expect(reads == 3)
    }

    @MainActor @Test func productionRequestRefusesBeforeInventoryPreparationOrAuthorization() {
        let frozen = move()
        for action: NativeSpaceCommand.Action in [.move, .select] {
            let request = NativeSpaceCommand(id: frozen.id, action: action, display: frozen.display, source: frozen.source,
                target: frozen.target, sourceUUID: frozen.sourceUUID, targetUUID: frozen.targetUUID, window: frozen.window)
            for available in [true, false] {
                let reply = run(request, available: available, witnesses: SidebarWindowWitnesses())
                #expect(reply.id == request.id && reply.state == .failed && !reply.canSwitch && !reply.canMove)
                #expect(reply.submittedSteps == 0 && reply.issuedAtUptime == nil)
                #expect(reply.currentBefore == nil && reply.membershipBefore == nil && reply.switchTrace == nil)
            }
        }
    }
}
