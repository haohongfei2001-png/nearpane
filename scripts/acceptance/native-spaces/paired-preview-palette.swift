import Foundation

// Two different colors per epoch. No window reuses a color during a run.
enum PairedPreviewPalette {
    static let epochs = [
        [[218,55,50], [35,115,230]], [[232,166,30], [102,48,195]],
        [[48,181,61], [213,47,158]], [[30,181,191], [148,76,29]],
        [[137,198,23], [47,65,167]], [[177,30,90], [33,127,93]],
        [[231,102,30], [134,40,143]]
    ]
    static let seconds = 2.1
    static func classify(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> String {
        if a < 15 || (a > 210 && max(r,g,b)-min(r,g,b) <= 18) { return "blank" }
        guard a >= 235 else { return "unknown" }
        var nearest = Int.max, second = Int.max, result = "unknown"
        for (epoch, pair) in epochs.enumerated() {
            for (document, color) in pair.enumerated() {
                let error = max(abs(r-color[0]), abs(g-color[1]), abs(b-color[2]))
                if error < nearest { second = nearest; nearest = error; result = "\(document)/\(epoch)" }
                else if error < second { second = error }
            }
        }
        return nearest <= 29 && second-nearest >= 9 ? result : "unknown"
    }
}
