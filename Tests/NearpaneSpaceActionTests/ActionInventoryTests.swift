import Foundation
import Testing
import NearpaneCore
@testable import NearpaneSpaceAction

struct ActionInventoryTests {
    let display = UUID(), a = UUID(), b = UUID()

    func inventory(_ current: String, session: Int = 4) -> ActionInventory {
        .init(displays: [display: .init(number: 3, bounds: CGRect(x: -800, y: 0, width: 800, height: 1280),
                                       current: current, spaces: [.init(id: "3", uuid: a, ordinary: true),
                                                                  .init(id: "7", uuid: b, ordinary: true)])],
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
            let third = ActionInventory.Space(id: "11", uuid: other, ordinary: true)
            let spaces = original.spaces + [third]
            return .init(displays: [
                display: .init(number: 3, bounds: original.bounds, current: spaces[index].id, spaces: spaces),
                other: .init(number: 5, bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), current: secondary,
                             spaces: [.init(id: "12", uuid: nil, ordinary: true), .init(id: "13", uuid: nil, ordinary: true)])
            ], session: 4)
        }
        let start = sample(0, "12")
        let command = NativeSpaceCommand(id: UUID(), action: .select, display: display.uuidString,
                                        source: "3", target: "11", sourceUUID: a, targetUUID: other)
        #expect(try sample(1, "12").transition(from: start, request: command, previous: 0) == 1)
        #expect(throws: ActionFailure.self) { try sample(0, "12").transition(from: start, request: command, previous: 1) }
        #expect(throws: ActionFailure.self) { try sample(2, "13").transition(from: start, request: command, previous: 1) }
    }
}
