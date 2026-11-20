import ApplicationServices
import Foundation
import Testing
@testable import NearpaneCore

struct OrdinaryFocusAttributesTests {
    private func values() -> [AnyObject] {
        var point = CGPoint(x: -85, y: 37), size = CGSize(width: 400, height: 240)
        return [kAXWindowRole as NSString, kAXStandardWindowSubrole as NSString, NSNumber(value: false),
                NSNumber(value: false), NSNumber(value: false), AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }

    @Test func successfulBatchUsesOneIPCAndKeepsExactGeometry() {
        let raw = values()
        var batches = 0, singles = 0
        let result = OrdinaryFocusAttributes(batch: { batches += 1; return raw }, individual: { _ in singles += 1; return nil })
        #expect(batches == 1 && singles == 0)
        #expect(result?.frame == CGRect(x: -85, y: 37, width: 400, height: 240) && result?.minimized == false)
    }

    @Test func unsupportedBatchReadsAllOriginalFieldsAndAXErrorsRetryOnlyTheirAttribute() {
        let raw = values(), keys = OrdinaryFocusAttributes.keys
        var calls = [String]()
        func read(_ key: String) -> AnyObject? { calls.append(key); return raw[keys.firstIndex(of: key)!] }
        #expect(OrdinaryFocusAttributes(batch: { nil }, individual: read)?.minimized == false)
        #expect(calls.count == 7 && Set(calls) == Set(keys))
        calls = []
        var mixed = raw, error = AXError.attributeUnsupported
        mixed[3] = AXValueCreate(.axError, &error)!
        #expect(OrdinaryFocusAttributes(batch: { mixed }, individual: read)?.minimized == false)
        #expect(calls == [kAXMinimizedAttribute])
    }

    @Test func incompleteRolesOrWrongGeometryRemainIneligible() {
        for (index, bad) in [(0, kAXGroupRole as NSString), (1, kAXDialogSubrole as NSString), (2, NSNumber(value: true)),
                             (4, NSNull()), (5, NSString(string: "invalid")), (6, NSNull())] as [(Int, AnyObject)] {
            var raw = values(); raw[index] = bad
            #expect(OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil }) == nil)
        }
    }

    @Test func missingOrPositiveMinimizedStateNeverBecomesFalse() {
        var raw = values()
        raw[3] = NSNumber(value: true)
        #expect(OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil })?.minimized == true)
        raw[3] = NSNull()
        #expect(OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil })?.minimized == nil)
    }

    @Test func focusTraceCanBeReadByAnOlderOrUninstrumentedRequester() throws {
        let id = UUID()
        let request = OrdinaryWindowRequest(.focusCurrent, pid: 12, launch: 20, bundle: "fixture", focusTimingID: id)
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(OrdinaryWindowRequest.self, from: encoded).focusTimingID == id)
        var prior = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        prior.removeValue(forKey: "focusTimingID")
        let decoded = try JSONDecoder().decode(OrdinaryWindowRequest.self, from: JSONSerialization.data(withJSONObject: prior))
        #expect(decoded.focusTimingID == nil && decoded.nonce == request.nonce)
    }
}
