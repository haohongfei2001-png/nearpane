import Foundation
import Testing
import NearpaneCore
@testable import WindowLab

struct OrdinaryScopeTests {
    private func scope(_ ids: [String], current: String) -> ManagedDisplayScope {
        .init(id: "scope-secondary", displayID: "secondary", records: ids.map { .init(id: $0, isCurrent: $0 == current) })
    }
    @Test func testOnlyAdjacentOrdinaryRecordsOnTheSameDisplayQualifyInEitherDirection() {
        let types = OrdinaryConsoleScope(ordinaryRecordsByDisplay: ["secondary": ["2","3","8"], "primary": ["1"]])
        let order = ["2","3","7","8"]
        #expect(types.admits(scope(order, current: "2"), current: "2", fullscreenOnly: false, other: nil))
        #expect(types.admits(scope(order, current: "3"), current: "3", fullscreenOnly: false, other: "2"))
        #expect(!types.admits(scope(order, current: "3"), current: "3", fullscreenOnly: false, other: "8"))
        #expect(!types.admits(scope(order, current: "3"), current: "3", fullscreenOnly: false, other: "7"))
        #expect(!types.admits(scope(order, current: "3"), current: "3", fullscreenOnly: false, other: "1"))
        #expect(!types.admits(scope(order, current: "7"), current: "7", fullscreenOnly: false, other: "8"))
        #expect(!types.admits(scope(order, current: "8"), current: "8", fullscreenOnly: false, other: nil))
    }
    @Test func testFullscreenProcedureStillRequiresOrdinarySourceAndTypedRead() {
        let types = OrdinaryConsoleScope(ordinaryRecordsByDisplay: ["secondary": ["2"]])
        #expect(types.admits(scope(["2","7"], current: "2"), current: "2", fullscreenOnly: true, other: nil))
        #expect(!types.admits(scope(["2","7"], current: "7"), current: "7", fullscreenOnly: true, other: nil))
        #expect((try? JSONDecoder().decode(OrdinaryConsoleScope.self, from: Data("{}".utf8))) == nil)
    }
}
