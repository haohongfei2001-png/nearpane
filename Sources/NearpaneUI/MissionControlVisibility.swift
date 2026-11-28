import AppKit
import ApplicationServices
import NearpaneCore
import Security

/// AppKit has no Mission Control entry/exit notification. These are observations of the
/// signed Dock's direct AX children, not assertions about another app's foreground state.
enum MissionControlVisibility: String, Sendable {
    case ordinary, exposed, unknown

    enum Child { case overview, dockList, other }

    static func classify(_ children: [Child]) -> Self {
        let overviews = children.filter { $0 == .overview }.count
        if overviews == 1 { return .exposed }
        if overviews == 0 && children.contains(.dockList) { return .ordinary }
        return .unknown
    }
}

/// Only the fixed "mc" identifier and the ordinary Dock list role are used. Never
/// descend into that list or fetch names, titles, documents, geometry, or content.
actor MissionControlVisibilityReader {
    private var verifiedDock: OrdinaryProcessImage?
    private static let executable = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    private static let identifier = "com.apple.dock"

    typealias Reading = (visibility: MissionControlVisibility, evidence: String, startUptime: TimeInterval, endUptime: TimeInterval)

    func read() -> Reading {
        let start = ProcessInfo.processInfo.systemUptime
        let result = sampleDock()
        return (result.visibility, result.evidence, start, ProcessInfo.processInfo.systemUptime)
    }

    private func sampleDock() -> (visibility: MissionControlVisibility, evidence: String) {
        guard AXIsProcessTrusted() else { return (.unknown, "accessibilityUnavailable") }
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier)
        guard matches.count == 1, let pid = matches.first?.processIdentifier,
              let image = try? OrdinaryProcessImage.read(pid), image.executable.path == Self.executable else {
            verifiedDock = nil
            return (.unknown, "uniqueDockProcessOrExecutableUnconfirmed")
        }
        if verifiedDock != image {
            guard Self.isAppleDock(pid) else { verifiedDock = nil; return (.unknown, "dockSignatureUnconfirmed") }
            verifiedDock = image
        }
        let root = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(root, 0.12) == .success, Self.owned(root, by: pid) else { return (.unknown, "dockAXRootUnconfirmed") }
        let began = ContinuousClock.now
        let attribute = kAXChildrenAttribute as CFString
        var count = 0
        var raw: CFArray?
        guard AXUIElementGetAttributeValueCount(root, attribute, &count) == .success, (1...16).contains(count),
              AXUIElementCopyAttributeValues(root, attribute, 0, count, &raw) == .success,
              let children = raw as? [AXUIElement], children.count == count else { return (.unknown, "missingOrUnboundedDockChildren") }
        var states = [MissionControlVisibility.Child]()
        for child in children {
            guard Self.owned(child, by: pid), ContinuousClock.now - began < .milliseconds(240) else { return (.unknown, "childOwnerOrDeadlineUnconfirmed") }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &value)
            if result == .success {
                guard let identifier = value as? String else { return (.unknown, "unexpectedChildIdentifierType") }
                if identifier == "mc" { states.append(.overview); continue }
            } else if result != .noValue && result != .attributeUnsupported { return (.unknown, "childIdentifierReadFailed") }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                  let name = role as? String else { return (.unknown, "childRoleReadFailed") }
            states.append(name == kAXListRole ? .dockList : .other)
        }
        var endCount = 0
        var endChildren: CFArray?
        guard AXUIElementGetAttributeValueCount(root, attribute, &endCount) == .success, endCount == count,
              AXUIElementCopyAttributeValues(root, attribute, 0, count, &endChildren) == .success,
              let raw, let endChildren, CFEqual(raw, endChildren), ContinuousClock.now - began < .milliseconds(300), (try? OrdinaryProcessImage.read(pid)) == image else { return (.unknown, "dockTreeGenerationOrDeadlineChanged") }
        switch MissionControlVisibility.classify(states) {
        case .ordinary: return (.ordinary, "signedDockAXListWithoutMC")
        case .exposed: return (.exposed, "signedDockMCIdentifier")
        case .unknown: return (.unknown, "ambiguousOrUnrecognizedDockTree")
        }
    }

    private static func owned(_ element: AXUIElement, by pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private static func isAppleDock(_ pid: pid_t) -> Bool {
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString("anchor apple and identifier \"com.apple.dock\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
