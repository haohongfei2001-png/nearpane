import AppKit
import CoreGraphics
import CoreFoundation
import Darwin
import ObservationCore

// Isolated experiment only. These three getters are the complete private-symbol allowlist.
// ABI/selector/ownership validation remains the separate P1-A gate, not a claim made by this helper.
private final class SkyLightReader {
    typealias Connection = @convention(c) () -> Int32
    typealias Managed = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias MembershipQuery = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private var handle: UnsafeMutableRawPointer?
    private var connection: Connection?
    private var managed: Managed?
    private var membershipQuery: MembershipQuery?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        guard let handle else { return }
        if let symbol = dlsym(handle, "SLSMainConnectionID") { connection = unsafeBitCast(symbol, to: Connection.self) }
        if let symbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") { managed = unsafeBitCast(symbol, to: Managed.self) }
        if let symbol = dlsym(handle, "SLSCopySpacesForWindows") { membershipQuery = unsafeBitCast(symbol, to: MembershipQuery.self) }
    }
    deinit { if let handle { dlclose(handle) } }

    func inventory() -> Inventory {
        guard let connection, let managed else { return Inventory(status: .unavailable, scopes: []) }
        guard let value = managed(connection())?.takeRetainedValue() else { return parseInventory(nil) }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return Inventory(status: .malformed, scopes: []) }
        return parseInventory(value as [AnyObject])
    }

    func membership(windowID: UInt32) -> Membership {
        guard let connection, let membershipQuery else { return Membership(status: .unavailable) }
        // Explicit 32-bit CFNumber, retaining the CGWindowID bit pattern; no [NSNumber] Swift bridge.
        var signedID = Int32(bitPattern: windowID)
        guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &signedID) else {
            return Membership(status: .unavailable)
        }
        var callbacks = kCFTypeArrayCallBacks
        guard let windows = CFArrayCreateMutable(kCFAllocatorDefault, 1, &callbacks) else {
            return Membership(status: .unavailable)
        }
        CFArrayAppendValue(windows, Unmanaged.passUnretained(number).toOpaque())
        guard let value = membershipQuery(connection(), 0x7, windows)?.takeRetainedValue() else {
            return Membership(status: .nullResult)
        }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return Membership(status: .malformed) }
        return parseMembership(value as [AnyObject])
    }
}

private func rect(_ value: CGRect) -> Rect {
    Rect(x: value.origin.x, y: value.origin.y, width: value.width, height: value.height)
}

final class MacSampler {
    private let skyLight = SkyLightReader()
    private let osVersion: String
    private let osBuild: String

    init() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var length = 0
        if sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0, length < 1024 {
            var bytes = [CChar](repeating: 0, count: length)
            if sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0 {
                osBuild = String(cString: bytes)
            } else { osBuild = "UNKNOWN" }
        } else { osBuild = "UNKNOWN" }
    }

    private func topology() -> Topology {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else {
            return Topology(displays: [], status: .unavailable)
        }
        // Leave capacity for a concurrent attachment; mark inconsistencies instead of retrying.
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        guard CGGetActiveDisplayList(64, &ids, &count) == .success, count <= 64 else {
            return Topology(displays: [], status: .unavailable)
        }
        let screens = NSScreen.screens
        var issues: [String] = []
        let displays: [Display] = ids.prefix(Int(count)).map { id in
            let matches = screens.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let screen = matches.count == 1 ? matches[0] : nil
            if screen == nil { issues.append("appkit_display_unresolved") }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let uuidString = uuid.map { CFUUIDCreateString(kCFAllocatorDefault, $0) as String }
            let mirror = CGDisplayMirrorsDisplay(id)
            return Display(id: id, uuid: uuidString, name: screen?.localizedName,
                           bounds: rect(CGDisplayBounds(id)), appKitFrame: screen.map { rect($0.frame) },
                           scale: screen.map { Double($0.backingScaleFactor) }, rotation: CGDisplayRotation(id),
                           pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                           isMain: CGDisplayIsMain(id) != 0, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                           mirrorsDisplay: mirror == kCGNullDirectDisplay ? nil : mirror)
        }
        return Topology(displays: displays, issues: Array(Set(issues)))
    }

    private func boundary() -> Boundary {
        Boundary(separateSpaces: NSScreen.screensHaveSeparateSpaces, topology: topology(), inventory: skyLight.inventory())
    }

    private func windows() -> (ReadStatus, [WindowMetadata]) {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return (.nullResult, []) }
        guard let rows = raw as? [[String: Any]] else { return (.malformed, []) }
        let records = rows.map { row -> WindowMetadata in
            let id = unsignedID(row[kCGWindowNumber as String]).flatMap(UInt32.init(exactly:))
            let pid = signedInteger(row[kCGWindowOwnerPID as String]).flatMap(Int32.init(exactly:))
            let layer = signedInteger(row[kCGWindowLayer as String]).flatMap(Int32.init(exactly:))
            let bounds = (row[kCGWindowBounds as String] as? [String: Any]).flatMap {
                CGRect(dictionaryRepresentation: $0 as CFDictionary)
            }.map(rect)
            let onscreen = row[kCGWindowIsOnscreen as String] as? Bool
            // Deliberately do not collect window titles or application names, even in the raw log.
            return WindowMetadata(id: id, pid: pid, layer: layer, bounds: bounds, onscreen: onscreen)
        }
        return (.ok, records)
    }

    func sample(revision: Int) throws -> Sample {
        precondition(Thread.isMainThread)
        let start = timestamp(), startNS = DispatchTime.now().uptimeNanoseconds
        let before = boundary()
        let (windowStatus, metadata) = windows()
        let observations = metadata.map { window -> WindowObservation in
            let membership: Membership
            if window.layer == 0, let id = window.id { membership = skyLight.membership(windowID: id) }
            else { membership = Membership(status: window.layer == 0 ? .unavailable : .notQueried) }
            return WindowObservation(metadata: window, membership: membership)
        }
        let (afterStatus, afterWindows) = windows()
        let after = boundary()
        let endNS = DispatchTime.now().uptimeNanoseconds
        return Sample(revision: revision, startedAt: start, endedAt: timestamp(), startedUptimeNS: startNS,
                      endedUptimeNS: endNS,
                      state: ObservationState(osVersion: osVersion, osBuild: osBuild, boundary: before,
                                              windowListStatus: windowStatus, windows: observations),
                      afterBoundary: after, afterWindowFingerprint: try fingerprint(afterWindows), afterWindowStatus: afterStatus)
    }
}
