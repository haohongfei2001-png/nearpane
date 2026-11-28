import AppKit

@main struct Check {
    static func main() {
        let patch = CGRect(x: 40, y: 50, width: 110, height: 90)
        let row: [String: Any] = [kCGWindowOwnerPID as String: Int32(82), kCGWindowNumber as String: UInt32(17),
            kCGWindowBounds as String: patch.dictionaryRepresentation, kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0, kCGWindowLayer as String: NSWindow.Level.normal.rawValue + 1]
        precondition(PairSwitchPixels.cover(row, host: 82, patch: patch) == 17)
        precondition(PairSwitchPixels.cover(row, host: 83, patch: patch) == nil)
        precondition(PairSwitchPixels.cover(row, host: 82, patch: patch.offsetBy(dx: 1, dy: 0)) == nil)
        precondition(PairSwitchPixels.cover(row.merging([kCGWindowLayer as String: 0]) { _, n in n }, host:82, patch:patch) == nil)
        precondition(PairSwitchPixels.fraction(45, 123, 204) == 0 && PairSwitchPixels.fraction(227, 139, 53) == 1)
        precondition(abs((PairSwitchPixels.fraction(136, 131, 128) ?? 0) - 0.5) < 0.02)
        precondition(PairSwitchPixels.fraction(0, 0, 0) == nil && PairSwitchPixels.fraction(136, 240, 128) == nil)
        func result(_ values: [Double], panel: UInt32? = 17, ended: Bool = false, at time: Double = 1) -> String {
            var series = PairSwitchPixels.Series()
            for (i, value) in values.enumerated() {
                let cover = i == 0 || i == values.count - 1 ? nil : panel
                series.append(progress: value, data: Data(), time: 0.5 + Double(i), before:cover, after:cover)
            }
            return series.receipt(terminated: ended, down: time...time, up: (time+0.02)...(time+0.02),
                                  uncertainty:0.001)["status"] as? String ?? ""
        }
        precondition(result([0, 0.12, 0.45, 0.85, 1]) == "PASS")
        precondition(result([0, 0.12, 0.45, 0.85, 1], at:2) == "UNKNOWN")
        precondition(result([0, 0.12, 0.45, 0.85, 1], panel:nil) == "UNKNOWN")
        precondition(result([0, 0.12, 0.45, 0.85, 1], ended:true) == "UNKNOWN")
        precondition(result([0, 1]) == "UNKNOWN")
        precondition(result([0, 0.5, 0, 0.75, 1]) == "FAIL")
        print("PASS")
    }
}
