import Foundation
import NearpaneCore

/// Tracks event continuity, not who moved a window. No mouse or AX side effects here.
struct BoundaryChangeTracker {
    private struct Change {
        let revision: UUID
        let eventTime: TimeInterval
        var offeredFrame: SurfaceRect?
        var offeredAt: TimeInterval?
    }
    private var change: Change?
    var pending: Bool { change != nil }
    var revision: UUID? { change?.revision }

    mutating func received(at time: TimeInterval) {
        change = .init(revision: UUID(), eventTime: time)
    }

    func isSettled(at time: TimeInterval, buttonDown: Bool) -> Bool {
        guard let change, time.isFinite, change.eventTime.isFinite, !buttonDown else { return false }
        return time - change.eventTime >= 0.25
    }

    mutating func offer(_ frame: SurfaceRect, at time: TimeInterval, buttonDown: Bool) throws -> UUID {
        try require(frame.geometry.isValid && isSettled(at: time, buttonDown: buttonDown),
                    "窗口外部变化尚未稳定。")
        change?.offeredFrame = frame
        change?.offeredAt = time
        return change!.revision
    }

    func validate(_ revision: UUID, frame: SurfaceRect, at time: TimeInterval, buttonDown: Bool) throws {
        guard let change, let offeredAt = change.offeredAt,
              change.revision == revision, change.offeredFrame == frame,
              offeredAt.isFinite, time.isFinite, time >= offeredAt, time - offeredAt <= 3,
              isSettled(at: time, buttonDown: buttonDown) else {
            throw Refusal("窗口边界见证已过期、发生新变化或已被使用。")
        }
    }

    mutating func consume(_ revision: UUID, frame: SurfaceRect, at time: TimeInterval, buttonDown: Bool) throws {
        try validate(revision, frame: frame, at: time, buttonDown: buttonDown)
        change = nil
    }
}
