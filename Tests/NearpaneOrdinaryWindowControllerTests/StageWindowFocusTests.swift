import ApplicationServices
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct StageWindowFocusTests {
    @Test func desktopRequiresPositiveNonWindowStructureAndACompleteOrdinaryWindowList() {
        func accepts(role: String? = kAXScrollAreaRole, parent: Bool = true,
                     error: AXError = .attributeUnsupported, value: Bool = false, listed: Bool? = false) -> Bool {
            FrontFocus.finderDesktopMatches(role: role, parentIsApplication: parent,
                containingWindowError: error, containingWindowReturnedValue: value,
                containingWindowIsSelf: false, listedOccurrences: listed.map { $0 ? 1 : 0 })
        }
        #expect(accepts() && accepts(error: .noValue))
        #expect(!accepts(role: nil) && !accepts(role: kAXWindowRole) && !accepts(role: kAXGroupRole))
        #expect(!accepts(parent: false)) // A scroll area inside a Finder window is still a window focus.
        #expect(!accepts(listed: nil) && !accepts(listed: true))
        #expect(!accepts(value: true))
        for error in [AXError.success, .cannotComplete, .invalidUIElement, .failure, .notImplemented, .apiDisabled] {
            #expect(!accepts(error: error))
        }
    }

    @Test func listedDesktopMustReferToItselfExactlyOnceWithoutBecomingAnOrdinaryWindow() {
        func accepts(role: String? = kAXScrollAreaRole, parent: Bool = true, error: AXError = .success,
                     value: Bool = true, same: Bool = true, count: Int? = 1) -> Bool {
            FrontFocus.finderDesktopMatches(role: role, parentIsApplication: parent,
                containingWindowError: error, containingWindowReturnedValue: value,
                containingWindowIsSelf: same, listedOccurrences: count)
        }
        #expect(accepts())
        #expect(!accepts(same: false) && !accepts(value: false))
        #expect(!accepts(count: nil) && !accepts(count: 0) && !accepts(count: 2))
        #expect(!accepts(role: kAXWindowRole) && !accepts(role: nil) && !accepts(parent: false))
        for error in [AXError.cannotComplete, .invalidUIElement, .noValue, .attributeUnsupported, .failure] {
            #expect(!accepts(error: error))
        }
    }
}
