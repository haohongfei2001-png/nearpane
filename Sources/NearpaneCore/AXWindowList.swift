import ApplicationServices
import Foundation

/// AX's indexed array API can reject index zero on an empty AXWindows list.
public struct AXWindowList {
    public let windows: [AXUIElement]?
    public let countStatus: AXError
    public let reportedCount: Int?
    public let arrayStatus: AXError?
    public let actualCount: Int?

    public static func read(_ app: AXUIElement, limit: Int, canRead: () -> Bool = { true }) -> Self {
        collect(limit: limit, count: {
            guard canRead() else { return (.cannotComplete, 0) }
            var count = 0
            let status = AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
            return (status, count)
        }, array: {
            guard canRead() else { return (.cannotComplete, nil) }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            return (status, value)
        })
    }

    static func collect(limit: Int, count: () -> (AXError, Int), array: () -> (AXError, CFTypeRef?)) -> Self {
        let (countStatus, countValue) = count()
        let expected = countStatus == .success ? countValue : nil
        guard limit > 0, expected.map({ (0...limit).contains($0) }) != false,
              countStatus != .apiDisabled && countStatus != .invalidUIElement else {
            return Self(windows: nil, countStatus: countStatus, reportedCount: expected, arrayStatus: nil, actualCount: nil)
        }
        let (status, raw) = array()
        guard status == .success, let raw, CFGetTypeID(raw) == CFArrayGetTypeID() else {
            return Self(windows: nil, countStatus: countStatus, reportedCount: expected, arrayStatus: status, actualCount: nil)
        }
        let length = CFArrayGetCount(unsafeBitCast(raw, to: CFArray.self))
        let valid = length <= limit && (expected == nil || expected == length)
        let rows = valid ? raw as? [AnyObject] : nil
        let windows = rows.flatMap { values -> [AXUIElement]? in
            guard values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return values.map { unsafeBitCast($0, to: AXUIElement.self) }
        }
        return Self(windows: windows, countStatus: countStatus, reportedCount: expected, arrayStatus: status, actualCount: length)
    }
}
