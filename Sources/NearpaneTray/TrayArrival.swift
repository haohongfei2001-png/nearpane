import AppKit
import RiftletCore
import RiftletCapture
import RiftletUI

/// Unpersisted original-source evidence. No guessed flight from the center of the screen.
struct TrayArrival {
    enum Source { case selected(RiftArrivalSource), system(ScreenshotSourceMetadata) }
    let id: UUID
    let ready: TimeInterval
    let source: Source

    @MainActor func plan(image: ImportedAsset, screen: NSScreen, target: CGRect, left: Bool) -> MagnetMotionPlan? {
        guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              CGDisplayIsInMirrorSet(display) == 0 else { return nil }
        let rect: CGRect
        switch source {
        case let .selected(selection):
            guard display == selection.displayID, screen.frame == selection.displayFrame,
                  screen.backingScaleFactor == selection.backingScale else { return nil }
            rect = selection.rect
        case let .system(metadata):
            let displays = NSScreen.screens.compactMap { item -> ScreenshotDisplayGeometry? in
                guard let id = (item.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
                return .init(id: id, quartzBounds: CGDisplayBounds(id), appKitFrame: item.frame,
                             backingScale: item.backingScaleFactor, isMirrored: CGDisplayIsInMirrorSet(id) != 0)
            }
            guard case let .success(geometry) = ScreenshotSourceGeometryResolver.resolve(metadata, pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight, displays: displays, targetDisplayID: display) else { return nil }
            rect = geometry.appKitRect
        }
        return MagnetMotionPlan(sourceRect: rect, targetImageFrame: target, clippingEdgeX: left ? target.minX : target.maxX,
                                screenFrame: screen.frame, leftSide: left)
    }
}
