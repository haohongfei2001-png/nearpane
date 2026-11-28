import ApplicationServices
import Foundation
import Testing
@testable import NearpaneCore

struct StageWindowAttributesTests {
    private func fields() -> [AnyObject] {
        var point = CGPoint(x: -85, y: 37), size = CGSize(width: 400, height: 240)
        return [kAXWindowRole as NSString, kAXDialogSubrole as NSString, NSNumber(value: false),
                NSNumber(value: true), NSNumber(value: false), AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }

    @Test func miniaturizedOriginalKeepsItsFrameWithoutAdmittingANewDialog() {
        let raw = fields()
        #expect(OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil }) == nil)
        let retained = OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil }, retainedStandardWindow: true)
        #expect(retained?.minimized == true)
        #expect(retained?.frame == CGRect(x: -85, y: 37, width: 400, height: 240))
        var ordinary = raw; ordinary[1] = kAXStandardWindowSubrole as NSString
        #expect(OrdinaryFocusAttributes(batch: { ordinary }, individual: { _ in nil })?.minimized == true)
    }

    @Test func retainedBindingStillRejectsVisibleModalFullscreenUnknownOrUnrelatedElements() {
        for (index, value) in [(0, kAXScrollAreaRole as NSString), (1, kAXFloatingWindowSubrole as NSString),
            (2, NSNumber(value: true)), (3, NSNumber(value: false)), (3, NSNull()), (4, NSNumber(value: true)),
            (4, NSNull()), (5, NSNull())] as [(Int, AnyObject)] {
            var raw = fields(); raw[index] = value
            #expect(OrdinaryFocusAttributes(batch: { raw }, individual: { _ in nil }, retainedStandardWindow: true) == nil)
        }
    }
}
