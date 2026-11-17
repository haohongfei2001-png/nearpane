import CoreGraphics
import Foundation

/// Public WindowServer metadata for precisely one already known number, even off screen.
public struct WindowSurfaceRecord {
    public let pid: Int32
    public let layer: Int
    public let frame: SurfaceRect
    public let isOnscreen, allowsContent: Bool

    public init?(number: CGWindowID) {
        guard number != kCGNullWindowID else { return nil }
        // CG's window-number CFArray stores integers as pointer values with no object callbacks.
        var raw = UnsafeRawPointer(bitPattern: UInt(number))
        guard let ids = CFArrayCreate(nil, &raw, 1, nil),
              let rows = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              row[kCGWindowNumber as String] as? UInt32 == number,
              let pid = row[kCGWindowOwnerPID as String] as? Int32, pid > 0,
              let layer = row[kCGWindowLayer as String] as? Int,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), !rect.isNull, !rect.isInfinite, !rect.isEmpty else { return nil }
        self.pid = pid; self.layer = layer
        frame = .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        isOnscreen = row[kCGWindowIsOnscreen as String] as? Bool == true
        let share = row[kCGWindowSharingState as String] as? UInt32
        allowsContent = (share == CGWindowSharingType.readOnly.rawValue || share == CGWindowSharingType.readWrite.rawValue)
            && (row[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }
}
