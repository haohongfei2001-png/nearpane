import CoreGraphics
import Foundation

/// Offline only. Constructs and serializes local Quartz records without posting any event.
@main struct PairPointerMotionTest {
    static func main() {
        let start = CGPoint(x:1350,y:246), end = CGPoint(x:1402,y:379)
        var previous = start, total = [Int64(0),Int64(0)]
        for i in 1...9 {
            let p = PairPointerMotion.point(from:start,to:end,fraction:CGFloat(i)/9)
            let e = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDragged,mouseCursorPosition:p,mouseButton:.left)!
            precondition(e.getIntegerValueField(.mouseEventDeltaX) == 0 && e.getIntegerValueField(.mouseEventDeltaY) == 0)
            let actual = PairPointerMotion.apply(e,from:previous,to:p)!
            let copy = CGEvent(withDataAllocator:nil,data:e.data!)!
            precondition(copy.location == p && actual == [copy.getIntegerValueField(.mouseEventDeltaX),copy.getIntegerValueField(.mouseEventDeltaY)])
            for axis in 0..<2 { total[axis] += actual[axis] }
            previous = p
        }
        precondition(total == [52,133] && previous == end)
        let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:end,mouseButton:.left)!
        precondition(PairPointerMotion.apply(up,from:end,to:end) == [0,0])
        precondition(PairPointerMotion.apply(up,from:end,to:CGPoint(x:1401.25,y:379)) == nil)
        print("PASS: nine unposted, serialized motion records; endpoints [52,133]; stationary release [0,0]")
    }
}
