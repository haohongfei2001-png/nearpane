import AppKit
import ApplicationServices
import WindowGeometryCore

public struct MetadataIssue: Equatable, Sendable {
    public let field: String
    public let code: String
}

public struct MetadataRead: Sendable {
    public let process: ProcessIdentity?
    public let cg: [CGWindowMetadata]
    public let ax: [AXWindowMetadata]
    public let beganUptime: Double
    public let endedUptime: Double
    public let issues: [MetadataIssue]
    /// Agreement between bounded reads is evidence, not an atomic snapshot guarantee.
    public let repeatedMetadataAgrees: Bool
    public var matches: [WindowMatch] { WindowMatcher.matches(cg: cg, ax: ax) }
}

/// Opt-in library only: constructing it does not inspect the desktop. No executable
/// invokes it in this package. No action, permission-request, image, or Spaces API.
/// Keep in an isolated helper before any future live integration; not a Host provider.
@MainActor
public final class ReadOnlyWindowObserver {
    private var retainedElements: [(UUID, AXUIElement)] = []
    private let windowLimit = 64
    private let timeout: Float = 0.1

    public init() {}

    /// Read a specifically selected PID using only existing AX trust. Never prompts.
    /// Budget checks are between synchronous calls; a CG call has no OS timeout API.
    public func read(pid: Int32) -> MetadataRead {
        retainedElements = [] // Every read invalidates all previous AX tokens.
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + 2
        var issues: [MetadataIssue] = []
        var cg: [CGWindowMetadata] = [], ax: [AXWindowMetadata] = []
        let process = incarnation(pid)
        func result(_ stable: Bool) -> MetadataRead {
            MetadataRead(process: process, cg: cg, ax: ax, beganUptime: began,
                         endedUptime: ProcessInfo.processInfo.systemUptime,
                         issues: issues, repeatedMetadataAgrees: stable && issues.isEmpty)
        }
        guard let process else {
            issues.append(MetadataIssue(field: "process", code: "unavailable"))
            return result(false)
        }
        guard process.hasLifecycleEvidence else {
            issues.append(MetadataIssue(field: "process.launchDate", code: "unknown"))
            return result(false)
        }
        guard AXIsProcessTrusted() else {
            issues.append(MetadataIssue(field: "accessibility", code: "notTrustedNoPrompt"))
            return result(false)
        }
        cg = readCG(process, issues: &issues)
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, timeout) == .success else {
            issues.append(MetadataIssue(field: "AX.timeout", code: "unavailable"))
            return result(false)
        }
        ax = readAX(app, process: process, deadline: deadline, issues: &issues)
        guard issues.isEmpty, ProcessInfo.processInfo.systemUptime < deadline else { return result(false) }
        let axAfter = readAX(app, process: process, deadline: deadline, issues: &issues)
        guard issues.isEmpty, ProcessInfo.processInfo.systemUptime < deadline else { return result(false) }
        let cgAfter = readCG(process, issues: &issues)
        let stable = process == incarnation(pid) && cg == cgAfter && ax == axAfter
            && ProcessInfo.processInfo.systemUptime <= deadline
        if !stable { issues.append(MetadataIssue(field: "sample", code: "changedOrBudgetExceeded")) }
        // This does not sample topology or Space state and cannot issue a WindowTarget.
        return result(stable)
    }

    private func incarnation(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        var micros: UInt64?
        if let date = app.launchDate {
            let value = date.timeIntervalSince1970 * 1_000_000
            if value.isFinite, value > 0, value < Double(UInt64.max) { micros = UInt64(value) }
        }
        return ProcessIdentity(pid: pid, launchEpochMicroseconds: micros)
    }

    private func readCG(_ process: ProcessIdentity, issues: inout [MetadataIssue]) -> [CGWindowMetadata] {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            issues.append(MetadataIssue(field: "CGWindowList", code: "unavailable")); return []
        }
        // Unrelated processes' metadata is discarded; never logged or persisted.
        var result: [CGWindowMetadata] = []
        for (index, row) in rows.enumerated() where (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.pid {
            guard result.count < windowLimit else {
                issues.append(MetadataIssue(field: "CGWindowList", code: "windowLimit")); break
            }
            guard let number = row[kCGWindowNumber as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else {
                issues.append(MetadataIssue(field: "CGWindow", code: "missingRequiredMetadata")); continue
            }
            let rect = Rect(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height)
            guard rect.isValid, number.uint32Value != 0 else {
                issues.append(MetadataIssue(field: "CGWindow", code: "invalidGeometryOrID")); continue
            }
            result.append(CGWindowMetadata(process: process, windowID: number.uint32Value,
                                           title: row[kCGWindowName as String] as? String, frame: rect,
                                           layer: layer.intValue,
                                           isOnscreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
                                           frontToBackIndex: index))
        }
        return result
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

    private func readAX(_ app: AXUIElement, process: ProcessIdentity, deadline: Double,
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
            let title = value(element, kAXTitleAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let identifier = value(element, kAXIdentifierAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let role = value(element, kAXRoleAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let subrole = value(element, kAXSubroleAttribute as CFString, deadline: deadline, issues: &issues) as? String
            let minimized = (value(element, kAXMinimizedAttribute as CFString, deadline: deadline, issues: &issues) as? NSNumber)?.boolValue
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
            result.append(AXWindowMetadata(process: process, elementToken: token, identifier: identifier,
                                           title: title, role: role, subrole: subrole, frame: rect, minimized: minimized))
        }
        return result
    }
}
