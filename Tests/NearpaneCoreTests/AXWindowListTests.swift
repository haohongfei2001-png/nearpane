import ApplicationServices
import Testing
@testable import NearpaneCore

struct AXWindowListTests {
    @Test func anEmptyWholeArrayIsEvidenceAndAnAXErrorIsNotAnEmptyList() {
        let empty = [] as CFArray
        for countStatus in [AXError.success, .illegalArgument] {
            let list = AXWindowList.collect(limit: 64, count: { (countStatus, 0) }, array: { (.success, empty) })
            #expect(list.windows?.isEmpty == true && list.actualCount == 0)
        }
        for status in [AXError.illegalArgument, .noValue, .cannotComplete] {
            let failed = AXWindowList.collect(limit: 64, count: { (.success, 0) }, array: { (status, nil) })
            #expect(failed.windows == nil && failed.arrayStatus == status)
        }
    }

    @Test func currentWindowCountsOrdinaryElementsAndOversizedOrUnstableArraysAreWithheld() throws {
        let a = AXUIElementCreateApplication(1001), b = AXUIElementCreateApplication(1002)
        for elements in [[a], [b,a]] {
            let reply = AXWindowList.collect(limit: 64, count: { (.success, elements.count) }, array: { (.success, elements as CFArray) })
            #expect(try #require(reply.windows).elementsEqual(elements, by: { CFEqual($0, $1) }))
        }
        let bad = AXWindowList.collect(limit: 64, count: { (.success, 0) }, array: { (.success, [a] as CFArray) })
        #expect(bad.windows == nil && bad.actualCount == 1)
        let malformed = AXWindowList.collect(limit: 64, count: { (.success, 1) }, array: { (.success, ["not an AX object"] as CFArray) })
        #expect(malformed.windows == nil)
        for (status, count) in [(AXError.apiDisabled,0), (.invalidUIElement,0), (.success,65)] {
            let reply = AXWindowList.collect(limit: 64, count: { (status,count) }, array: { Issue.record("unbounded read"); return (.success,nil) })
            #expect(reply.windows == nil && reply.arrayStatus == nil)
        }
    }
}
