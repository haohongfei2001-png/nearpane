import AppKit
import ImageIO
import ScreenCaptureKit

/// Can this Mac's sealed default image, scaled to fill, supply the material that
/// the read-only product worker actually needs? No captured pixels leave the observer.
@MainActor enum SealedCornerComparison {
    private static let asset = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.heic")

    private static func bytes(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        try data.withUnsafeMutableBytes { raw in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CornerDesktopMaterial.Missing.sampleUnavailable }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    static func run(_ nonce: UUID) async -> [String: Any] {
        typealias Missing = CornerDesktopMaterial.Missing
        var row: [String: Any] = ["status":"UNKNOWN", "scope":"sealedDefaultAspectFillComparedWithAppleWallpaperOnly",
            "challenge":nonce.uuidString, "windowWrites":0, "inputEvents":0, "storedFrames":0, "productionQualified":false]
        do {
            let bound = try CornerDesktopMaterial.surface()
            // The material request derives the current corner and full shadow footprint. It has no window-write grant.
            let footprintData = try await Task.detached {
                let result = NPObserveProductCornerMaterial(nonce.uuidString as CFString) as NSDictionary
                return try JSONSerialization.data(withJSONObject: result)
            }.value
            let report = try JSONSerialization.jsonObject(with: footprintData) as? [String: Any]
            guard report?["status"] as? String == "PASS", let home = report?["before"] as? [String: Any],
                  let native = home["native"] as? UInt64, let space = home["space"] as? String,
                  let display = home["display"] as? String, UUID(uuidString: display) == bound.displayUUID,
                  let cold = report?["cold"] as? [String: Any], let frame = cold["shadowFootprint"] as? [Double],
                  frame.count == 4, let screen = NSScreen.screens.first else { throw Missing.display }
            let check = { try CornerDesktopMaterial.surface() == bound &&
                NPCornerObserverMatchesHome(display as CFString, space as CFString, native) &&
                NSWorkspace.shared.desktopImageURL(for: screen)?.resolvingSymlinksInPath() == asset.resolvingSymlinksInPath() }
            guard try check(), let source = CGImageSourceCreateWithURL(asset as CFURL, nil),
                  CGImageSourceGetCount(source) == 1, let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0, image.height > 0, image.width * image.height <= 42_000_000 else { throw Missing.systemAsset }
            let area = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            let region = area.offsetBy(dx: -bound.frame.minX, dy: -bound.frame.minY)
            let screenSize = bound.frame.size
            let scale = max(screenSize.width / CGFloat(image.width), screenSize.height / CGFloat(image.height))
            let originX = (screenSize.width - CGFloat(image.width) * scale) / 2
            let originY = (screenSize.height - CGFloat(image.height) * scale) / 2
            let crop = CGRect(x: (region.minX-originX)/scale, y: (region.minY-originY)/scale,
                              width: region.width/scale, height: region.height/scale).integral
            guard bound.frame.contains(area), let reference = image.cropping(to:crop) else { throw Missing.systemAsset }
            let inventory = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            let targets = inventory.windows.filter { $0.windowID == bound.number && $0.owningApplication?.processID == bound.pid && $0.frame == bound.frame }
            guard targets.count == 1, let displaySource = inventory.displays.first(where:{ $0.displayID == bound.display && $0.frame == bound.frame }),
                  try check() else { throw Missing.shareableWallpaper }
            let filter = SCContentFilter(display:displaySource, including:targets)
            filter.includeMenuBar = false
            let px = CGFloat(filter.pointPixelScale), w = Int(region.width*px), h = Int(region.height*px)
            guard (1...4).contains(px), w > 0, h > 0, w*h <= 1_048_576 else { throw Missing.display }
            let expected = try bytes(reference, width:w, height:h)
            let config = SCStreamConfiguration()
            config.width = w; config.height = h; config.sourceRect = region
            config.destinationRect = CGRect(x:0,y:0,width:w,height:h)
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.preservesAspectRatio = false; config.scalesToFit = true
            config.backgroundColor = CGColor.clear
            var samples = [[String: Int]]()
            for i in 0..<2 {
                if i > 0 { try await Task.sleep(for:.milliseconds(80)) }
                guard try check() else { throw Missing.sourceChanged }
                let picture = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                guard picture.width == w, picture.height == h, try check() else { throw Missing.sourceChanged }
                let actual = try bytes(picture,width:w,height:h)
                var matched = 0, opaque = 0, worst = 0
                for offset in stride(from:0,to:actual.count,by:4) {
                    let delta = (0..<3).map { abs(Int(actual[offset+$0])-Int(expected[offset+$0])) }.max()!
                    worst = max(worst,delta)
                    if actual[offset+3] == 255 && expected[offset+3] == 255 {
                        opaque += 1
                        if delta <= 1 { matched += 1 }
                    }
                }
                samples.append(["opaque":opaque,"withinOneRGBLevel":matched,"maxChannelDifference":worst])
            }
            row["native"] = native; row["shadowFootprint"] = frame; row["pixelsPerFrame"] = w*h; row["samples"] = samples
            let matching = samples.allSatisfy { $0["withinOneRGBLevel"] == w*h }
            row["status"] = matching ? "PASS" : "FAIL"
            row["reason"] = matching ? "sealedFillMatchesActualMaterialTwice" : "sealedFillDiffersFromActualWallpaper"
        } catch { row["reason"] = (error as? Missing)?.rawValue ?? "observationUnavailable" }
        return row
    }
}
