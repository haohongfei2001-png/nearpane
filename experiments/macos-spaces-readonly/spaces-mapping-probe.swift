import Foundation
import AppKit
import CoreGraphics
import CoreFoundation
import ApplicationServices
import Darwin

func rect(_ r: CGRect) -> [String: Double] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}
func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
    guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
    let uuid = unmanaged.takeRetainedValue()
    return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
}

let screenRows: [[String: Any]] = NSScreen.screens.enumerated().map { index, screen in
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    return [
        "ordinal": index + 1,
        "localizedName": screen.localizedName,
        "displayUUID": displayUUID(id) ?? "",
        "frameAppKit": rect(screen.frame),
        "visibleFrameAppKit": rect(screen.visibleFrame),
        "boundsCG": rect(CGDisplayBounds(id)),
        "pixelWidth": CGDisplayPixelsWide(id),
        "pixelHeight": CGDisplayPixelsHigh(id),
        "backingScale": screen.backingScaleFactor,
        "rotation": CGDisplayRotation(id),
        "isBuiltin": CGDisplayIsBuiltin(id) != 0,
        "isMain": CGDisplayIsMain(id) != 0,
        "isMirror": CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    ]
}
let screenUUIDs = screenRows.compactMap { $0["displayUUID"] as? String }

var out: [String: Any] = [
    "probe": "nearpane-p1-spaces-mapping-20261109",
    "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    "capturedPixels": false,
    "performedFocusOrSwitch": false,
    "requestedPermissions": false,
    "axTrustedForProbeHost": AXIsProcessTrusted(),
    "screenCapturePreflightForProbeHost": CGPreflightScreenCaptureAccess(),
    "separateSpaces": NSScreen.screensHaveSeparateSpaces,
    "screens": screenRows
]

let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func sym(_ names: [String]) -> UnsafeMutableRawPointer? {
    for name in names { if let p = dlsym(handle, name) { return p } }
    return nil
}
typealias MainConnection = @convention(c) () -> Int32
typealias Managed = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
let mainP = sym(["SLSMainConnectionID", "CGSMainConnectionID"])
let managedP = sym(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"])
let membershipP = sym(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"])
out["privateSymbols"] = [
    "mainConnection": mainP != nil,
    "managedDisplaySpaces": managedP != nil,
    "spacesForWindows": membershipP != nil
]

var connection: Int32 = 0
var spaceOrdinal: [UInt64: Int] = [:]
var scopeRows: [[String: Any]] = []
if let mainP {
    connection = unsafeBitCast(mainP, to: MainConnection.self)()
}
if let managedP, mainP != nil,
   let raw = unsafeBitCast(managedP, to: Managed.self)(connection)?.takeRetainedValue() {
    for (displayIndex, value) in (raw as NSArray).enumerated() {
        guard let display = value as? NSDictionary else { continue }
        let identifier = display["Display Identifier"] as? String ?? ""
        let matchedOrdinal = screenRows.firstIndex {
            (($0["displayUUID"] as? String) ?? "").caseInsensitiveCompare(identifier) == .orderedSame
        }.map { $0 + 1 }
        let spaces = display["Spaces"] as? [NSDictionary] ?? []
        let current = display["Current Space"] as? NSDictionary
        let currentID = (current?["id64"] as? NSNumber)?.uint64Value
        var spaceRows: [[String: Any]] = []
        for (spaceIndex, space) in spaces.enumerated() {
            let sid = (space["id64"] as? NSNumber)?.uint64Value ?? 0
            if spaceOrdinal[sid] == nil { spaceOrdinal[sid] = spaceOrdinal.count + 1 }
            spaceRows.append([
                "ordinalWithinScope": spaceIndex + 1,
                "anonymousSpaceKey": spaceOrdinal[sid] ?? 0,
                "typeRaw": (space["type"] as? NSNumber)?.intValue ?? -1,
                "isCurrent": sid == currentID,
                "hasUUID": space["uuid"] != nil
            ])
        }
        scopeRows.append([
            "displayScopeOrdinal": displayIndex + 1,
            "displayIdentifier": identifier,
            "matchedScreenOrdinal": matchedOrdinal as Any? ?? NSNull(),
            "matchesPublicScreenUUID": matchedOrdinal != nil,
            "isLiteralMainIdentifier": identifier == "Main",
            "spaceCount": spaces.count,
            "spaces": spaceRows
        ])
    }
}
out["managedScopes"] = scopeRows

let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var layerZeroCount = 0
var membershipCount = 0
var unknownMembershipRefs = 0
var onscreenPositiveCount = 0
var onscreenPositiveWithMembership = 0
var onscreenPositiveUnknown = 0
var membershipBySpace: [Int: Int] = [:]
var visibleRows: [[String: Any]] = []

for info in infos {
    let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -999
    guard layer == 0 else { continue }
    layerZeroCount += 1

    let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    var bounds: [String: Double]?
    if let b = info[kCGWindowBounds as String] as? [String: Any],
       let x = (b["X"] as? NSNumber)?.doubleValue,
       let y = (b["Y"] as? NSNumber)?.doubleValue,
       let w = (b["Width"] as? NSNumber)?.doubleValue,
       let h = (b["Height"] as? NSNumber)?.doubleValue {
        bounds = ["x": x, "y": y, "width": w, "height": h]
    }
    let positiveBounds = (bounds?["width"] ?? 0) > 0 && (bounds?["height"] ?? 0) > 0
    if isOnscreen && positiveBounds { onscreenPositiveCount += 1 }

    var keys: [Int] = []
    var returnedCount = 0
    var refsMatch = true
    if let membershipP, mainP != nil,
       let wid = info[kCGWindowNumber as String] as? NSNumber {
        let fn = unsafeBitCast(membershipP, to: Membership.self)
        if let raw = fn(connection, 7, [wid] as CFArray)?.takeRetainedValue() {
            let ids = (raw as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
            returnedCount = ids.count
            keys = ids.compactMap { spaceOrdinal[$0] }
            refsMatch = ids.allSatisfy { spaceOrdinal[$0] != nil }
            if returnedCount > 0 {
                membershipCount += 1
                for key in keys { membershipBySpace[key, default: 0] += 1 }
            }
            if !refsMatch { unknownMembershipRefs += 1 }
        }
    }

    if isOnscreen && positiveBounds {
        if returnedCount > 0 { onscreenPositiveWithMembership += 1 }
        if !refsMatch || returnedCount == 0 { onscreenPositiveUnknown += 1 }
        visibleRows.append([
            "anonymousWindowOrdinal": layerZeroCount,
            "boundsCG": bounds ?? [:],
            "spaceKeys": keys,
            "returnedMembershipCount": returnedCount,
            "membershipRefsMatchInventory": refsMatch
        ])
    }
}
out["cgWindowMetadataCount"] = infos.count
out["layerZeroWindowCount"] = layerZeroCount
out["layerZeroWindowsWithMembership"] = membershipCount
out["layerZeroWindowsWithUnknownSpaceRefs"] = unknownMembershipRefs
out["onscreenPositiveWindowCount"] = onscreenPositiveCount
out["onscreenPositiveWindowsWithMembership"] = onscreenPositiveWithMembership
out["onscreenPositiveWindowsUnresolved"] = onscreenPositiveUnknown
out["membershipCountsByAnonymousSpaceKey"] = Dictionary(uniqueKeysWithValues: membershipBySpace.map { (String($0.key), $0.value) })
out["onscreenPositiveWindows"] = visibleRows

if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
   let text = String(data: data, encoding: .utf8) {
    print(text)
}