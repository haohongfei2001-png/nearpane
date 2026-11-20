import AppKit

// Colors belong only to the pair-pointer build's two registered test documents.
enum PairPointerPalette {
    private static let rgb = [[45, 123, 204], [227, 139, 53]]

    static func install(slot: Int, editor: NSTextView, window: NSWindow) {
        guard rgb.indices.contains(slot) else { return }
        let color = rgb[slot]
        let background = NSColor(srgbRed: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                                 blue: CGFloat(color[2]) / 255, alpha: 1)
        window.colorSpace = .sRGB
        window.isOpaque = true
        window.backgroundColor = background
        editor.drawsBackground = true
        editor.backgroundColor = background
    }

    // A single mixed, transparent or off-palette pixel invalidates the sample.
    static func slot(bgra bytes: UnsafePointer<UInt8>, stride: Int, side: Int) -> Int? {
        guard side == 8, stride >= side * 4 else { return nil }
        let matches = rgb.indices.filter { slot in
            let color = rgb[slot]
            for y in 0..<side {
                for x in 0..<side {
                    let p = bytes + y * stride + x * 4
                    guard p[3] == 255, abs(Int(p[2]) - color[0]) <= 12,
                          abs(Int(p[1]) - color[1]) <= 12, abs(Int(p[0]) - color[2]) <= 12 else { return false }
                }
            }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
