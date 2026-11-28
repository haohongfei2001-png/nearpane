import CoreGraphics

/// Quartz mouse motion fields are integers. Integral interpolation makes each
/// delta the actual distance between the two emitted global logical points.
enum PairPointerMotion {
    static func point(from: CGPoint, to: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x:(from.x + (to.x-from.x)*fraction).rounded(), y:(from.y + (to.y-from.y)*fraction).rounded())
    }

    @discardableResult static func apply(_ event: CGEvent, from: CGPoint, to: CGPoint) -> [Int64]? {
        let points = [from.x,from.y,to.x,to.y]
        guard points.allSatisfy({ $0.isFinite && $0 == $0.rounded() && abs($0) < 1_000_000 }) else { return nil }
        let dx = Int64(to.x-from.x), dy = Int64(to.y-from.y)
        event.setIntegerValueField(.mouseEventDeltaX,value:dx)
        event.setIntegerValueField(.mouseEventDeltaY,value:dy)
        guard event.getIntegerValueField(.mouseEventDeltaX) == dx, event.getIntegerValueField(.mouseEventDeltaY) == dy else { return nil }
        return [dx,dy]
    }
}
