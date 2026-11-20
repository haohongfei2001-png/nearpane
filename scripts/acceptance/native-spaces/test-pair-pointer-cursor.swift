import CoreGraphics
import Darwin

/// Reads only the explicitly supplied system service identity, and never inspects live windows or input.
@main struct PairPointerCursorTest {
    static func main() {
        let rect = CGRect(x:20,y:30,width:35,height:42), at = CGPoint(x:21,y:39)
        precondition(PairSystemCursor.footprint(rect,cursor:at,candidate:at))
        precondition(!PairSystemCursor.footprint(rect,cursor:nil,candidate:at))
        precondition(!PairSystemCursor.footprint(rect,cursor:.zero,candidate:at))
        precondition(!PairSystemCursor.footprint(rect,cursor:at,candidate:.zero))
        precondition(!PairSystemCursor.footprint(.init(x:0,y:0,width:1440,height:900),cursor:at,candidate:at))
        precondition(PairSystemCursor.generation(getpid()) == nil)
        if CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) {
            precondition(PairSystemCursor.generation(pid) != nil)
            print("PASS: live Apple WindowServer exact executable, signing requirement, kernel UID and stable birth")
        }
        print("PASS: five cursor footprints and unrelated process excluded")
    }
}
