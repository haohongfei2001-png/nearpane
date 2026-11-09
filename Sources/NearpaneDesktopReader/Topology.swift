import AppKit
import CryptoKit
import NearpaneCore
import WindowGeometryCore

struct Topology: Equatable {
    let displays: [DisplayObservation]
    let separateSpaces: Bool
    let geometry: DesktopGeometry
    static func == (a: Self, b: Self) -> Bool { a.displays == b.displays && a.separateSpaces == b.separateSpaces }
    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(displays)) ?? Data()
        return SHA256.hash(data: Data([separateSpaces ? 1 : 0]) + bytes).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor init() throws {
        var displays = [DisplayObservation](), maps = [DisplayCoordinateTransform]()
        func rect(_ r: CGRect) -> Rect { Rect(r.minX, r.minY, r.width, r.height) }
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  CGDisplayIsInMirrorSet(n.uint32Value) == 0,
                  let turn = QuarterTurn(rawValue: Int(CGDisplayRotation(n.uint32Value).rounded()) % 360) else {
                throw GeometryError.unsupportedTopology
            }
            let id = CFUUIDCreateString(nil, uuid) as String, cg = rect(CGDisplayBounds(n.uint32Value))
            let transform = try DisplayCoordinateTransform(displayID: id, appKitFrame: rect(screen.frame),
                cgBounds: cg, backingScale: screen.backingScaleFactor, rotation: turn)
            let usable = try transform.appKitToCG(rect(screen.visibleFrame))
            guard let clipped = cg.intersection(usable), clipped == usable else { throw GeometryError.invalidGeometry }
            displays.append(.init(id: id, frame: SurfaceRect(cg), rotationDegrees: turn.rawValue, backingScale: screen.backingScaleFactor,
                                  usable: SurfaceRect(x: usable.x-cg.x, y: usable.y-cg.y, width: usable.width, height: usable.height)))
            maps.append(transform)
        }
        guard let primary = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { throw GeometryError.unsupportedTopology }
        geometry = try DesktopGeometry(displays: maps, primaryID: CFUUIDCreateString(nil, primary) as String)
        self.displays = displays; separateSpaces = NSScreen.screensHaveSeparateSpaces
    }
}
