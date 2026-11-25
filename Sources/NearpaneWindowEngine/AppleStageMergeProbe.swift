import AppKit
import ApplicationServices
import CNearpaneWindowEngine

package struct AppleStageMergePoint: Equatable, Sendable {
    package let window, twin: CGWindowID
    package let manager: pid_t
    package let location: CGPoint
    package let timestamp: UInt64

    /// Independent AX hit and front-to-back on-screen CG read immediately before delivery.
    package func stillHits(_ source: Set<UInt32>) -> Bool {
        guard AXIsProcessTrusted(), !source.isEmpty, source.contains(window),
              let owner = NSRunningApplication(processIdentifier: manager), !owner.isTerminated,
              owner.bundleIdentifier == "com.apple.WindowManager",
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              rows.count <= NP_APPLE_MAX_LISTED else { return false }
        var topMatches = false
        for row in rows {
            guard let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw) else { return false }
            guard frame.contains(location) else { continue }
            topMatches = row[kCGWindowNumber as String] as? UInt32 == twin &&
                row[kCGWindowOwnerPID as String] as? Int32 == manager && row[kCGWindowLayer as String] as? Int32 == 0
            break
        }
        guard topMatches else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &hit) == .success,
              var node = hit else { return false }
        var matched = false
        for _ in 0..<8 {
            var pid: pid_t = -1
            guard AXUIElementGetPid(node, &pid) == .success, pid == manager else { return false }
            AXUIElementSetMessagingTimeout(node, 0.04)
            func attribute(_ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
            }
            if let ids = attribute("AXWindowsIDs") as? [NSNumber] {
                let actual = ids.compactMap { UInt32($0.stringValue) }
                guard actual.count == ids.count, actual.count == source.count, Set(actual) == source else { return false }
                matched = true
            }
            if attribute(kAXIdentifierAttribute) as? String == "sm.strip" { return matched && !owner.isTerminated }
            guard let parent = attribute(kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
        }
        return false
    }
}

extension AppleStageSystemRead {
    /// Contains native members even if Nearpane cannot manage one; callers must not silently filter it out.
    package func confirmedStrip(on screen: CGRect) -> [[UInt32]]? {
        strip(on: screen)?.map(\.members)
    }
}

extension AppleStageMirror {
    /// Must follow a successful mirror read of this exact snapshot in the same physical scope.
    package func mergePoint(system: AppleStageSystemRead, managed: [UInt32], screen: CGRect, visible: CGRect,
                            source: Set<UInt32>, destination: Set<UInt32>) -> AppleStageMergePoint? {
        guard source.count > 0, destination.count > 0, source.isDisjoint(with: destination),
              source.union(destination).isSubset(of: Set(managed)), screen.contains(visible),
              let strips = system.confirmedStrip(on: screen), strips.contains(where: { Set($0) == source && $0.count == source.count }),
              strips.allSatisfy({ destination.isDisjoint(with: $0) }),
              source.count <= NP_APPLE_MAX_MANAGED, destination.count <= NP_APPLE_MAX_MANAGED else { return nil }
        var query = NPAppleMergeRequest(), out = NPAppleMergePoint()
        query.size = UInt32(MemoryLayout.size(ofValue: query)); query.version = UInt32(NP_APPLE_MIRROR_ABI)
        out.size = UInt32(MemoryLayout.size(ofValue: out)); out.version = query.version
        query.sample_time_ns = system.sampleTime
        query.visible_frame = NPAppleRect(visible)
        query.source_count = UInt32(source.count); query.destination_count = UInt32(destination.count)
        let status = source.sorted().withUnsafeBufferPointer { from in
            destination.sorted().withUnsafeBufferPointer { to in
                query.source = from.baseAddress; query.destination = to.baseAddress
                return np_apple_merge_point_v1(handle, &query, &out)
            }
        }
        guard status == NP_APPLE_MIRROR_OK, out.manager_pid == system.manager else { return nil }
        return AppleStageMergePoint(window: out.window, twin: out.twin, manager: out.manager_pid,
                                    location: CGPoint(x: out.x, y: out.y), timestamp: system.sampleTime)
    }
}
