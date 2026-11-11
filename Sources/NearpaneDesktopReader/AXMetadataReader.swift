import AppKit
import ApplicationServices
import WindowGeometryCore

struct MetadataIssue { let field, code: String }

// P1-C ReadOnlyWindowObserver, scoped to the selected PIDs and one total sample deadline.
// Titles are compared only as session-salted equality tokens and never enter the exported model.
final class AXMetadataReader {
    private var retainedElements: [(UUID, AXUIElement)] = []
    private let windowLimit = 64
    private let timeout: Float = 0.08
    let titleToken: (String) -> String?
    var fullScreen: [UUID: Bool] = [:]
    init(titleToken: @escaping (String) -> String?) { self.titleToken = titleToken }

    func read(_ process: ProcessIdentity, deadline: Double, issues: inout [MetadataIssue]) -> [AXWindowMetadata] {
        let app = AXUIElementCreateApplication(process.pid)
        guard AXUIElementSetMessagingTimeout(app, timeout) == .success else {
            issues.append(.init(field: "AX.timeout", code: "unavailable")); return []
        }
        return readAX(app, process: process, deadline: deadline, issues: &issues)
    }
    private func value(_ element: AXUIElement, _ attribute: CFString, deadline: Double,
                       issues: inout [MetadataIssue]) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            issues.append(MetadataIssue(field: "AX", code: "budgetExceeded")); return nil
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        if error == .success { return value }
        // Optional/unexposed attributes remain nil, never empty strings or false.
        if error != .attributeUnsupported && error != .noValue {
            issues.append(MetadataIssue(field: attribute as String, code: "AXError:\(error.rawValue)"))
        }
        return nil
    }

    func readAX(_ app: AXUIElement, process: ProcessIdentity, deadline: Double,
                        issues: inout [MetadataIssue]) -> [AXWindowMetadata] {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            issues.append(MetadataIssue(field: "AXWindows", code: "budgetExceeded")); return []
        }
        var array: CFArray?
        let error = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, windowLimit + 1, &array)
        guard error == .success, let elements = array as? [AXUIElement] else {
            issues.append(MetadataIssue(field: "AXWindows", code: "AXError:\(error.rawValue)")); return []
        }
        guard elements.count <= windowLimit else {
            issues.append(MetadataIssue(field: "AXWindows", code: "windowLimit")); return []
        }
        var result: [AXWindowMetadata] = []
        for element in elements {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                issues.append(MetadataIssue(field: "AXWindows", code: "budgetExceeded")); break
            }
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success else {
                issues.append(MetadataIssue(field: "AX.timeout", code: "unavailable")); break
            }
            // Equal AX objects share a token so duplicate rows remain ambiguous.
            let token = retainedElements.first(where: { CFEqual($0.1, element) })?.0 ?? UUID()
            if !retainedElements.contains(where: { $0.0 == token }) { retainedElements.append((token, element)) }
            let title = (value(element, kAXTitleAttribute as CFString, deadline: deadline, issues: &issues) as? String).flatMap(titleToken)
            let role = value(element, kAXRoleAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let subrole = value(element, kAXSubroleAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let minimized = (value(element, kAXMinimizedAttribute as CFString, deadline: deadline, issues: &issues) as? NSNumber)?.boolValue
            if let full = value(element, "AXFullScreen" as CFString, deadline: deadline, issues: &issues),
               CFGetTypeID(full) == CFBooleanGetTypeID(), let flag = full as? Bool {
                fullScreen[token] = flag
            }
            let position = value(element, kAXPositionAttribute as CFString, deadline: deadline, issues: &issues)
            let size = value(element, kAXSizeAttribute as CFString, deadline: deadline, issues: &issues)
            var point = CGPoint.zero, dimensions = CGSize.zero
            var rect: Rect?
            if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                let p = position as! AXValue, s = size as! AXValue
                if AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
                   AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions) {
                    let candidate = Rect(point.x, point.y, dimensions.width, dimensions.height)
                    if candidate.isValid { rect = candidate }
                }
            }
            if rect == nil || role == nil {
                issues.append(MetadataIssue(field: "AXWindow", code: "missingRequiredMetadata"))
            }
            let standard = role == kAXWindowRole && subrole == kAXStandardWindowSubrole && fullScreen[token] != nil
            result.append(AXWindowMetadata(process: process, elementToken: token, identifier: nil,
                                           title: title, role: role, subrole: subrole, frame: rect, minimized: minimized,
                                           standardWindowNumber: standard ? AdmissionAXRead.windowNumber(element) : nil))
        }
        return result
    }
}
