import Foundation

/// Geometry only. The caller must separately prove a live, authorized window, a settled
/// observation and current display ownership before issuing any AX operation. A proposed
/// correction does not grant access to a window or authorize restoring an old frame.
public enum ManagedWindowBoundary: Sendable {
    /// Keep the current size when possible, shrink only dimensions larger than the work area,
    /// and move no farther than necessary to bring the rectangle inside that area.
    ///
    /// `minimum` supplies dimensions only. `others` are the other managed windows' freshly
    /// confirmed frames; they are never rearranged to make room for this correction.
    /// A nil result means that the frame is already valid, contained and non-overlapping.
    public static func correction(
        frame: SurfaceRect, in workRect: SurfaceRect, minimum: SurfaceRect,
        others: [SurfaceRect] = []
    ) throws -> SurfaceRect? {
        guard frame.geometry.isValid, workRect.geometry.isValid,
              others.allSatisfy({ $0.geometry.isValid }) else {
            throw WorkspaceFailure.invalidLayout
        }
        guard minimum.width.isFinite, minimum.height.isFinite,
              minimum.width > 0, minimum.height > 0,
              frame.width >= minimum.width, frame.height >= minimum.height,
              workRect.width >= minimum.width, workRect.height >= minimum.height else {
            throw WorkspaceFailure.minimumSize
        }
        // A second unknown/out-of-bounds member is not an empty slot. Its recovery must not
        // be guessed while this window is being constrained.
        guard others.allSatisfy({ workRect.geometry.intersection($0.geometry) == $0.geometry }) else {
            throw WorkspaceFailure.conflict
        }
        let width = min(frame.width, workRect.width)
        let height = min(frame.height, workRect.height)
        let target = SurfaceRect(
            x: min(max(frame.x, workRect.x), workRect.geometry.maxX - width),
            y: min(max(frame.y, workRect.y), workRect.geometry.maxY - height),
            width: width, height: height)
        guard target.geometry.isValid,
              workRect.geometry.intersection(target.geometry) == target.geometry else {
            throw WorkspaceFailure.invalidLayout
        }
        // Rect.intersection returns nil for shared edges or corners: zero-area contact is
        // allowed, but even a fractional-point overlap must stop the proposed operation.
        guard others.allSatisfy({ target.geometry.intersection($0.geometry) == nil }) else {
            throw WorkspaceFailure.conflict
        }
        return target == frame ? nil : target
    }
}
