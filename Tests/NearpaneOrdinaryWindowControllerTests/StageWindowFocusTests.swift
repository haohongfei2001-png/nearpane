import ApplicationServices
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct StageWindowFocusTests {
    @Test func desktopRequiresPositiveNonWindowStructureAndACompleteOrdinaryWindowList() {
        func accepts(role: String? = kAXScrollAreaRole, parent: Bool = true,
                     error: AXError = .attributeUnsupported, value: Bool = false, listed: Bool? = false) -> Bool {
            FrontFocus.finderDesktopMatches(role: role, parentIsApplication: parent,
                containingWindowError: error, containingWindowReturnedValue: value, listedAsWindow: listed)
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
}
