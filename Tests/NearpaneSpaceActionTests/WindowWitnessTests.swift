import ApplicationServices
import Foundation
import Testing
import NearpaneCore
@testable import NearpaneSpaceAction

struct WindowWitnessTests {
    let target = AXUIElementCreateApplication(40001)
    let sibling = AXUIElementCreateApplication(40002)
    let replacement = AXUIElementCreateApplication(40003)

    private func observed(target handle: AXUIElement, birth: UInt64 = 901, x: CGFloat = 5,
                          siblings: [UInt32: WindowWitness.Sibling] = [:], other: [UInt32: [String]] = [:]) -> WindowWitness {
        WindowWitness(identity: .init(pid: 12345, birth: birth, number: 12), element: handle,
                      frame: CGRect(x: x, y: 20, width: 300, height: 200), siblings: siblings, otherCGSurfaces: other)
    }

    @Test func postMoveRequiresOriginalGenerationAndReboundAXHandle() {
        let source = observed(target: target)
        #expect(!source.sameWindowAndSiblings(as: observed(target: replacement)))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, birth: 902)))
        let repositioned = observed(target: target, x: 100)
        #expect(source.sameWindowAndSiblings(as: repositioned))
        #expect(!source.agreesBeforeDispatch(with: repositioned))
    }

    @Test func postMoveRequiresCompleteSiblingHandlesAndMemberships() {
        let old = WindowWitness.Sibling(element: sibling, spaces: ["8"])
        let source = observed(target: target, siblings: [13: old], other: [44: []])
        #expect(source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: old], other: [44: []])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, other: [44: []])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: old, 15: old], other: [44: []])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: .init(element: replacement, spaces: ["8"])], other: [44: []])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: .init(element: sibling, spaces: ["7"])], other: [44: []])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: old], other: [44: ["7"]])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: old])))
        #expect(!source.sameWindowAndSiblings(as: observed(target: target, siblings: [13: old], other: [44: [], 45: []])))
    }
}
