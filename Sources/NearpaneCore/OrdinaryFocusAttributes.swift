import ApplicationServices
import Foundation

/// All seven properties belong to the same retained AX element. A client that cannot
/// supply the batch can still provide the original individual attributes.
package struct OrdinaryFocusAttributes {
    static let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXMinimizedAttribute,
                       "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute]
    package let frame: CGRect
    package let minimized: Bool?

    package init?(_ element: AXUIElement) {
        self.init(batch: {
            var items: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.keys as CFArray, [], &items) == .success else { return nil }
            return items as? [AnyObject]
        }, individual: { key in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        })
    }

    init?(batch: () -> [AnyObject]?, individual: (String) -> AnyObject?) {
        let values = batch()
        func field(_ i: Int) -> AnyObject? {
            if let values, values.count == Self.keys.count {
                let item = values[i]
                if !(item is NSNull) && !(CFGetTypeID(item) == AXValueGetTypeID() && AXValueGetType(item as! AXValue) == .axError) {
                    return item
                }
            }
            return individual(Self.keys[i])
        }
        guard field(0) as? String == kAXWindowRole, field(1) as? String == kAXStandardWindowSubrole,
              field(2) as? Bool == false, field(4) as? Bool == false,
              let position = field(5), CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = field(6), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &s),
              p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
        frame = CGRect(origin: p, size: s)
        minimized = field(3) as? Bool
    }
}
