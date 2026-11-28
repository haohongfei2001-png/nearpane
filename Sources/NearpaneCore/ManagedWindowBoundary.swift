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
        others: [SurfaceRect] = [], lastConfirmed: SurfaceRect? = nil
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
        func free(_ rect: SurfaceRect) -> Bool {
            workRect.geometry.intersection(rect.geometry) == rect.geometry &&
                others.allSatisfy { rect.geometry.intersection($0.geometry) == nil }
        }
        if !free(target) {
            // A diagonal drag against a shared tile edge can cross the screen edge too.
            // Constrain the changed axis against this window's last witnessed free slot.
            // A resize, a jump across the sibling, or an already occupied slot has no such witness.
            guard frame != target, let prior = lastConfirmed, prior.geometry.isValid,
                  prior.width == frame.width, prior.height == frame.height,
                  frame.geometry.intersection(prior.geometry) != nil, free(prior) else {
                throw WorkspaceFailure.conflict
            }
            let alongRow = SurfaceRect(x: target.x, y: prior.y, width: width, height: height)
            let alongColumn = SurfaceRect(x: prior.x, y: target.y, width: width, height: height)
            let rowFree = free(alongRow), columnFree = free(alongColumn)
            if rowFree && columnFree {
                let dx = abs(target.x - prior.x), dy = abs(target.y - prior.y)
                if dx == dy { return prior }
                return dx < dy ? alongColumn : alongRow
            }
            if rowFree { return alongRow }
            if columnFree { return alongColumn }
            return prior
        }
        return target == frame ? nil : target
    }
}
