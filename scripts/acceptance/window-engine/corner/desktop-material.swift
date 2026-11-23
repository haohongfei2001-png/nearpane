import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Security

/// Reads only a WindowServer surface owned by the Apple-signed wallpaper agent.
@MainActor enum CornerDesktopMaterial {
    struct Surface: Equatable {
        let pid: pid_t
        let birth: UInt64
        let number: CGWindowID
        let frame: CGRect
        let display: CGDirectDisplayID
        let displayUUID: UUID
    }
    enum Missing: String, Error {
        case permission, display, wallpaperSurface, systemAsset, shareableWallpaper, sourceChanged, sampleUnavailable
    }

    private static func signingGeneration(_ pid: pid_t) -> UInt64? {
        var bsd = proc_bsdinfo()
        let bytes = Int32(MemoryLayout.size(ofValue: bsd))
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bytes) == bytes,
              bsd.pbi_pid == UInt32(pid), bsd.pbi_uid == getuid() else { return nil }
        var live: SecCode?, rule: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"com.apple.wallpaper.agent\"" as CFString, [],
                                              &rule) == errSecSuccess, let rule,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                              [], &live) == errSecSuccess, let live,
              SecCodeCheckValidity(live, [], rule) == errSecSuccess else { return nil }
        return bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
    }

    static func surface() throws -> Surface {
        guard CGPreflightScreenCaptureAccess() else { throw Missing.permission }
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Missing.display
        }
        let display = number.uint32Value, frame = CGDisplayBounds(display)
        guard let asset = NSWorkspace.shared.desktopImageURL(for: screen), asset.isFileURL,
              asset.path.hasPrefix("/System/") else { throw Missing.systemAsset }
        let canonical = asset.resolvingSymlinksInPath().path
        guard canonical.hasPrefix("/System/Library/Wallpapers/") || canonical.hasPrefix("/System/Library/Desktop Pictures/")
        else { throw Missing.systemAsset }
        guard CGDisplayIsActive(display) != 0, CGDisplayIsInMirrorSet(display) == 0,
              let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let uuid = UUID(uuidString: CFUUIDCreateString(nil, cf) as String),
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { throw Missing.display }
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.wallpaper.agent")
        guard agents.count == 1, let pid = agents.first?.processIdentifier, let birth = signingGeneration(pid) else {
            throw Missing.wallpaperSurface
        }
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let candidates = rows.compactMap { row -> CGWindowID? in
            guard row[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let level = row[kCGWindowLayer as String] as? Int, level <= desktop,
                  row[kCGWindowIsOnscreen as String] as? Bool == true, row[kCGWindowAlpha as String] as? Double == 1,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds == frame else { return nil }
            return row[kCGWindowNumber as String] as? CGWindowID
        }
        guard candidates.count == 1, let id = candidates.first, id > 0 else { throw Missing.wallpaperSurface }
        return Surface(pid: pid, birth: birth, number: id, frame: frame, display: display, displayUUID: uuid)
    }

    /// No call accepts an application, window, arbitrary crop or output file. No pixel bytes leave this process.
    static func sample(nonce: UUID) async -> [String: Any] {
        var result: [String: Any] = ["challenge": nonce.uuidString, "scope": "appleWallpaperWindowOnly",
                                     "productionQualified": false, "windowWrites": 0, "storedFrames": 0]
        do {
            let bound = try surface()
            result["sourcePID"] = bound.pid
            result["sourceBirth"] = bound.birth
            result["sourceWindow"] = bound.number
            result["displayUUID"] = bound.displayUUID.uuidString
            let inventory = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let matches = inventory.windows.filter {
                $0.windowID == bound.number && $0.owningApplication?.processID == bound.pid && $0.frame == bound.frame
            }
            guard matches.count == 1, let window = matches.first else { throw Missing.shareableWallpaper }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let bounds = filter.contentRect
            guard bounds.width == bound.frame.width, bounds.height == bound.frame.height, try surface() == bound else {
                throw Missing.sourceChanged
            }
            var times: [UInt64] = []
            var opaqueCounts: [Int] = []
            for _ in 0..<2 {
                let options = SCStreamConfiguration()
                options.width = 8
                options.height = 8
                options.sourceRect = CGRect(x: bounds.maxX - 8, y: bounds.maxY - 8, width: 8, height: 8)
                options.destinationRect = CGRect(x: 0, y: 0, width: 8, height: 8)
                options.preservesAspectRatio = false
                options.scalesToFit = true
                options.showsCursor = false
                options.ignoreShadowsSingleWindow = true
                options.ignoreGlobalClipSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: options)
                guard image.width == 8, image.height == 8, try surface() == bound else { throw Missing.sourceChanged }
                var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
                let count = rgba.withUnsafeMutableBytes { buf -> Int in
                    guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                          let context = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                                                  bytesPerRow: 32, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return -1 }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                    return stride(from: 3, to: buf.count, by: 4).filter { buf[$0] == 255 }.count
                }
                opaqueCounts.append(count)
                times.append(DispatchTime.now().uptimeNanoseconds)
            }
            result["observationsNS"] = times
            result["opaquePixelsOf64"] = opaqueCounts
            guard opaqueCounts == [64,64] else { throw Missing.sampleUnavailable }
            result["status"] = "PASS"
        } catch {
            result["status"] = error is Missing ? "BLOCKED" : "UNKNOWN"
            result["reason"] = (error as? Missing)?.rawValue ?? "screenCaptureKitError"
            if !(error is Missing) { result["systemErrorCode"] = (error as NSError).code }
        }
        return result
    }
}
