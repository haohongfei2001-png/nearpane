import Testing
@testable import NearpaneOrdinaryWindowController

struct StageCreationFocusTests {
    @Test func aNewlyFocusedOriginalAxObjectMustMatchTheCreatedObject() {
        var path = StageCreationFocus(original: 100, same: ==)
        path.observe(100) { _ in false }
        path.observe(201) { _ in true }
        #expect(path.accepts(201))
        #expect(!path.accepts(202))
        #expect(!path.accepts(100))
        path.observe(202) { _ in true }
        #expect(!path.accepts(201))
    }

    @Test func existingSiblingOrUnobservedReceiverPoisonsAnOtherwiseMatchingReturn() {
        for other in [Optional(101), nil] {
            var path = StageCreationFocus(original: 100, same: ==)
            path.observe(other) { _ in false }
            path.observe(100) { _ in false }
            #expect(path.interrupted && !path.accepts(201))
        }
    }

    @Test func newWindowMayRemainUnfocusedWhileTheOriginKeepsFocus() {
        var path = StageCreationFocus(original: 100, same: ==)
        path.observe(100) { _ in false }
        #expect(path.accepts(201))
    }

    @Test func unreadableIntermediateFocusOrReturnToOriginCannotBeHiddenByTheFinalSample() {
        var path = StageCreationFocus(original: 100, same: ==)
        path.observe(201, changed: true) { _ in true }
        #expect(path.accepts(201))
        var repeated = path
        repeated.observe(201, changed: true) { _ in true }
        #expect(!repeated.accepts(201))
        path.observe(100) { _ in false }
        #expect(!path.accepts(201))
    }
}
