import AppKit
import Testing
@testable import NearpaneCore
@testable import NearpaneOrdinaryWindowRuntime

struct StageWindowReturnTests {
    let id = ManagedWindowID(pid: 77, launch: 1234, number: 101, element: UUID())
    let home = OrdinaryDesktopIdentity(display: "display", record: "41", uuid: UUID())
    let layout = SurfaceRect(x: 40, y: 60, width: 500, height: 300)

    func matches(forward: [UInt64] = [41], reverse: [UInt32] = [101], actual: CGRect? = nil,
                 minimized: Bool? = false, allowMinimized: Bool = false, pid: Int32 = 77,
                 number: UInt32 = 101, layer: Int = 0) -> Bool {
        let inventory: [[String: Any]] = [["Display Identifier": "display",
            "Current Space": ["id64": UInt64(42), "type": 4, "uuid": UUID().uuidString],
            "Spaces": [["id64": UInt64(41), "type": 0, "uuid": home.uuid.uuidString]]]]
        // The OS may shrink/move the presentation in an overview without moving its AX layout.
        let transformed = CGRect(x: 900, y: 20, width: 100, height: 60)
        let cg: [String: Any] = [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer, kCGWindowBounds as String: transformed.dictionaryRepresentation,
            kCGWindowIsOnscreen as String: false]
        return StageWindowPhysicalReader.returnedHomeMatches(id, home: home, expected: layout,
            frame: actual ?? CGRect(x: layout.x, y: layout.y, width: layout.width, height: layout.height),
            minimized: minimized, allowMinimized: allowMinimized, inventory: inventory,
            forward: forward, reverse: reverse, window: cg)
    }

    @Test func systemHandoffUsesExactAXLayoutAndBidirectionalHomeMembershipWithoutFocusOrCGTransforms() {
        #expect(matches())
        #expect(!matches(forward: [98]))
        #expect(!matches(forward: [41, 98]))
        #expect(!matches(reverse: []))
        #expect(!matches(reverse: [101, 101]))
        #expect(!matches(actual: CGRect(x: 41, y: 60, width: 500, height: 300)))
        #expect(!matches(pid: 78))
        #expect(!matches(number: 102))
        #expect(!matches(layer: 3))
    }

    @Test func onlyAnIncompleteYellowButtonTransactionMayRemainNativelyMinimized() {
        #expect(!matches(minimized: true))
        #expect(!matches(minimized: nil))
        #expect(matches(minimized: true, allowMinimized: true))
        #expect(matches(minimized: false, allowMinimized: true))
        #expect(!matches(minimized: nil, allowMinimized: true))
        #expect(!matches(forward: [98], minimized: true, allowMinimized: true))
    }

    @Test func aMissingManagedRowIsNotEvidenceThatAHiddenSpaceWasDestroyed() {
        // The full classic inventory, not the managed-display roster, supplies
        // positive absence. A live private ID instead needs an actual empty read.
        #expect(StageWindowPhysicalReader.hiddenSpacesReleased([99], inventory: [41], occupants: { _ in nil }))
        #expect(StageWindowPhysicalReader.hiddenSpacesReleased([99], inventory: [41, 99], occupants: { _ in [] }))
        #expect(!StageWindowPhysicalReader.hiddenSpacesReleased([99], inventory: [41, 99], occupants: { _ in nil }))
        #expect(!StageWindowPhysicalReader.hiddenSpacesReleased([99], inventory: [41, 99], occupants: { _ in [101] }))
        #expect(!StageWindowPhysicalReader.hiddenSpacesReleased([99], inventory: nil, occupants: { _ in [] }))
        #expect(!StageWindowPhysicalReader.hiddenSpacesReleased([], inventory: [], occupants: { _ in [] }))
    }
}
