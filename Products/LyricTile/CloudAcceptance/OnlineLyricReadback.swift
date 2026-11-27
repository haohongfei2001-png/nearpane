// Disposable CI only. Read the ordinary app's actual visible Accessibility
// text; emit hashes and geometry, never lyric text, input events or screenshots.
import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

private struct ReadbackFailure: Error { let reason: String }

@MainActor
private final class CenterReadback {
    let pid: pid_t
    let started = ProcessInfo.processInfo.systemUptime
    var deadline: TimeInterval { started + 1.65 }
    var report: [String: Any]

    init(pid: pid_t) {
        self.pid = pid
        report = ["status": "BLOCKED", "pid": pid, "hitBelongsToTargetWindow": false,
                  "centerTextHashes": [String](), "textIncluded": false,
                  "inputPosted": false, "permissionsRequested": false,
                  "normalization": "trim whitespaceAndNewlines; preserve internal whitespace; SHA256 of UTF-8"]
    }

    func checkTime() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw ReadbackFailure(reason: "Read-only Accessibility inspection reached its bounded deadline.")
        }
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func text(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }
    func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(source, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func bounds(_ source: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(source, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = attribute(source, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: point, size: size)
        return Self.valid(rect) ? rect : nil
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0 && rect.width <= 16_384 && rect.height <= 16_384
    }
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
    static func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
    func visibleWindows() -> [(number: UInt32, bounds: CGRect)] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number > 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), Self.valid(rect),
                  rect.width >= 100, rect.height >= 100 else { return nil }
            return (number, rect)
        }
    }
    func containingWindow(_ source: AXUIElement) -> AXUIElement? {
        if let window = element(source, kAXWindowAttribute) { return window }
        var current: AXUIElement? = source
        for _ in 0..<8 {
            guard let value = current else { break }
            if text(value, kAXRoleAttribute) == kAXWindowRole { return value }
            current = element(value, kAXParentAttribute)
        }
        return nil
    }
    func inspect() throws {
        let trusted = AXIsProcessTrusted()
        report["accessibilityAlreadyTrusted"] = trusted
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == "com.holdsnow.lyrictile" else {
            throw ReadbackFailure(reason: "The target is not the currently running ordinary LyricTile app.")
        }
        guard trusted else {
            throw ReadbackFailure(reason: "Accessibility is not already trusted; no permission request was made.")
        }
        let system = AXUIElementCreateSystemWide()
        // The system-wide object sets the process's default messaging timeout.
        AXUIElementSetMessagingTimeout(system, 0.08)
        let windows = visibleWindows()
        report["visibleCandidateWindowCount"] = windows.count
        guard windows.count == 1, let window = windows.first else {
            throw ReadbackFailure(reason: "No unique visible LyricTile window of at least 100 by 100 points.")
        }
        report["windowNumber"] = window.number
        report["windowBounds"] = Self.rectangle(window.bounds)
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.08)
        let axWindows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard axWindows.count <= 12 else { throw ReadbackFailure(reason: "Too many Accessibility windows for a bounded readback.") }
        let matches = axWindows.filter { source in
            guard let rect = bounds(source) else { return false }
            return Self.same(rect, window.bounds)
        }
        try checkTime()
        guard matches.count == 1, let target = matches.first else {
            throw ReadbackFailure(reason: "The CG window has no unique matching Accessibility window.")
        }
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        report["point"] = ["x": Double(center.x), "y": Double(center.y)]
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(center.x), Float(center.y), &hit)
        report["hitResult"] = result.rawValue
        var hitPID: pid_t = 0
        guard result == .success, let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
              let hitWindow = containingWindow(hit), let hitWindowBounds = bounds(hitWindow),
              Self.same(hitWindowBounds, window.bounds) else {
            throw ReadbackFailure(reason: "System-wide hit testing did not confirm the same target PID and window.")
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(hitWindow, &windowPID) == .success, windowPID == pid else {
            throw ReadbackFailure(reason: "The hit window belongs to a different process.")
        }
        report["hitBelongsToTargetWindow"] = true
        report["hitWindowIdentityEqual"] = CFEqual(hitWindow, target)
        report["hitRole"] = text(hit, kAXRoleAttribute) ?? "unknown"
        if let rect = bounds(hit) { report["hitBounds"] = Self.rectangle(rect) }

        var hashes = Set<String>()
        var observations: [[String: Any]] = []
        var visited = 0
        func read(_ source: AXUIElement, depth: Int, isHit: Bool) {
            guard depth <= 8, visited < 64, ProcessInfo.processInfo.systemUptime < deadline else { return }
            visited += 1
            let rect = bounds(source)
            // Only native elements covering the physical center are candidates.
            // Missing grouping geometry may be traversed, never accepted as text.
            if let rect, !rect.intersection(window.bounds).contains(center) { return }
            let role = text(source, kAXRoleAttribute) ?? "unknown"
            if let rect, isHit || role == kAXStaticTextRole {
                var localHashes = Set<String>()
                for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let raw = text(source, name) else { continue }
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value.utf8.count <= 16_384 else { continue }
                    localHashes.insert(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined())
                }
                if !localHashes.isEmpty {
                    hashes.formUnion(localHashes)
                    observations.append(["role": role, "bounds": Self.rectangle(rect), "hashes": localHashes.sorted(), "directHit": isHit])
                }
            }
            for child in (attribute(source, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(12) {
                read(child, depth: depth + 1, isHit: false)
            }
        }
        read(hit, depth: 0, isHit: true)
        // SwiftUI may expose a grouping proxy as its hit result. Inspect only a
        // small center-covering path in the already verified native window.
        if hashes.isEmpty { read(target, depth: 0, isHit: false) }
        try checkTime()
        let fresh = visibleWindows()
        try checkTime()
        guard fresh.count == 1, fresh[0].number == window.number, Self.same(fresh[0].bounds, window.bounds) else {
            throw ReadbackFailure(reason: "The native target window changed during readback.")
        }
        report["visitedElements"] = visited
        report["centerTextHashes"] = hashes.sorted()
        report["textObservations"] = observations
        guard !hashes.isEmpty else { throw ReadbackFailure(reason: "No center-covering native text was exposed within the bounded inspection.") }
        report["status"] = "OBSERVED"
    }
}

@main
@MainActor
private enum OnlineLyricReadback {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        var directory: ObjCBool = false
        guard env["GITHUB_ACTIONS"] == "true", let temporary = env["RUNNER_TEMP"], !temporary.isEmpty,
              FileManager.default.fileExists(atPath: temporary, isDirectory: &directory), directory.boolValue,
              CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--pid",
              let pid = Int32(CommandLine.arguments[2]), pid > 0, pid != getpid() else {
            print("{\"status\":\"BLOCKED\",\"reason\":\"Disposable macOS CI and --pid are required.\",\"centerTextHashes\":[],\"hitBelongsToTargetWindow\":false}")
            return
        }
        let probe = CenterReadback(pid: pid)
        do { try probe.inspect() }
        catch let error as ReadbackFailure { probe.report["reason"] = error.reason }
        catch { probe.report["reason"] = "Native readback failed." }
        probe.report["durationMilliseconds"] = (ProcessInfo.processInfo.systemUptime - probe.started) * 1_000
        if let data = try? JSONSerialization.data(withJSONObject: probe.report, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print(output) }
    }
}
