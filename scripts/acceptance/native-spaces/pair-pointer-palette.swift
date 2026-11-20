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

    static func slot(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Int? {
        guard alpha == 255 else { return nil }
        return rgb.indices.first {
            abs(Int(red) - rgb[$0][0]) <= 12 && abs(Int(green) - rgb[$0][1]) <= 12 && abs(Int(blue) - rgb[$0][2]) <= 12
        }
    }

    // A single mixed, transparent or off-palette pixel invalidates the sample.
    static func slot(bgra bytes: UnsafePointer<UInt8>, stride: Int, side: Int) -> Int? {
        guard side == 8, stride >= side * 4 else { return nil }
        guard let measured = slot(red:bytes[2],green:bytes[1],blue:bytes[0],alpha:bytes[3]) else { return nil }
        for y in 0..<side {
            for x in 0..<side {
                let p = bytes + y * stride + x * 4
                guard slot(red:p[2],green:p[1],blue:p[0],alpha:p[3]) == measured else { return nil }
            }
        }
        return measured
    }
}
