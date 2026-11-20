import AppKit

private enum MarkerTestError: Error { case invalid(String) }
private func require(_ condition: Bool, _ description: String) throws {
    if !condition { throw MarkerTestError.invalid(description) }
}

// Draw only an in-memory, opaque sRGB pixel. No NSApplication, window or display capture.
private func pixel(_ color: NSColor) throws -> [Int] {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MarkerTestError.invalid("sRGB bitmap unavailable")
        }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try require(bytes[3] == 255, "marker lost opacity")
    return bytes.prefix(3).map(Int.init)
}

@main private enum MarkerTests {
    static func main() throws {
        var samples: [String: [[Int]]] = [:]
        for paper in P0MarkerPaper.allCases {
            for (flag, count): (String?, String?) in [(nil, "1"), ("0", "1"), ("true", "1"), ("1", "2"), ("1", nil)] {
                try require(paper.alternatingColors(flag: flag, documentCount: count).isEmpty, "mode was implicitly enabled")
            }
            let base = try pixel(paper.base)
            let phases = try paper.alternatingColors(flag: "1", documentCount: "1").map(pixel)
            try require(phases.count == 2, "two distinct display phases required")
            for (rgb, offset) in zip(phases, [-8, 8]) {
                try require(rgb[0] == base[0] && rgb[2] == base[2] && rgb[1] - base[1] == offset, "incorrect phase")
            }
            let colors = [base] + phases
            for sample in colors {
                for reference in colors {
                    try require(zip(sample, reference).allSatisfy { abs($0 - $1) <= 30 }, "same endpoint escaped acceptance range")
                }
                try require(sample.max()! > 60, "black could match an endpoint")
            }
            samples[paper.rawValue] = colors
        }
        for field in samples[P0MarkerPaper.field.rawValue]! {
            for route in samples[P0MarkerPaper.route.rawValue]! {
                try require(zip(field, route).contains { abs($0 - $1) > 60 }, "endpoint palettes overlap")
            }
        }
        let result: [String: Any] = ["result": "PASS_OFFSCREEN_PALETTE", "sRGBBaseAndPhases": samples,
                                     "visibleWindowsCreated": 0, "displayCadenceMeasured": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
