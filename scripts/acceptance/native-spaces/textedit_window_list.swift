import ApplicationServices
import Foundation

/// Metadata-only proof for exactly two enrolled TextEdit windows. Copies no document attributes here.
struct TextEditWindowList {
    let windows: [AXUIElement]?
    let status: String
    let evidence: [String: Any]

    static func read(_ app: AXUIElement) -> Self {
        let key = kAXWindowsAttribute as CFString
        return inspect(count: {
            var n = 0
            let error = AXUIElementGetAttributeValueCount(app, key, &n)
            return (error, n)
        }, copy: {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, key, &raw)
            return (error, raw)
        })
    }

    static func inspect(count: () -> (AXError, Int), copy: () -> (AXError, CFTypeRef?)) -> Self {
        var kind = "notRead"
        let list = AXWindowList.collect(limit: 2, count: count, array: {
            let (error, raw) = copy()
            if error != .success { kind = "error" }
            else if let raw { kind = CFGetTypeID(raw) == CFArrayGetTypeID() ? "array" : "otherCFType" }
            else { kind = "noValue" }
            return (error, raw)
        })
        let state: String
        if let reported = list.reportedCount, reported > 2 { state = "additionalWindowsReported" }
        else if list.arrayStatus == nil { state = "windowCountRefused" }
        else if list.arrayStatus != .success { state = "arrayAXError" }
        else if kind == "noValue" { state = "missingArrayValue" }
        else if kind != "array" { state = "nonArrayValue" }
        else if let expected = list.reportedCount, expected != list.actualCount { state = "countChanged" }
        else if list.actualCount == 0 { state = "emptyArray" }
        else if list.actualCount == 1 { state = "oneWindow" }
        else if list.actualCount != 2 { state = "additionalWindowsReturned" }
        else if list.windows == nil { state = "invalidArrayMembers" }
        else { state = "twoAXWindows" }
        var note: [String: Any] = ["status": state, "countAXError": list.countStatus.rawValue, "valueKind": kind]
        if let code = list.arrayStatus { note["copyAXError"] = code.rawValue }
        if let n = list.reportedCount { note["reportedCount"] = n }
        if let n = list.actualCount { note["copiedCount"] = n }
        return Self(windows: state == "twoAXWindows" ? list.windows : nil, status: state, evidence: note)
    }
}

// Interpret only the registered product identifier's cardinality and the AXBoolean
// on that node. A missing or malformed attribute cannot establish disablement.
enum TextEditSidebarButtonRead {
    static func matchState(count: Int, rosterCount: Int) -> String? {
        if count == 0 { return rosterCount == 1 ? "missing" : "rosterUnavailable" }
        return count == 1 ? nil : "duplicate"
    }
    static func enabled(status: AXError, value: CFTypeRef?) -> Bool? {
        guard status == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}
