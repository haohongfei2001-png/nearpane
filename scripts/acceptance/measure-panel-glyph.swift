// Use the real AX button bounds in panel-local coordinates on the single-window capture.
import AppKit

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 9, let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[0]))) else {
    fail("Expected an owned PNG, panel frame, and unique AX button frame")
}
let geometry = args.dropFirst().compactMap(Double.init)
guard geometry.count == 8, geometry.allSatisfy(\.isFinite) else { fail("Invalid geometry") }
let panel = CGRect(x: geometry[0], y: geometry[1], width: geometry[2], height: geometry[3])
let button = CGRect(x: geometry[4], y: geometry[5], width: geometry[6], height: geometry[7])
guard !panel.isEmpty, !button.isEmpty, panel.contains(button) else { fail("Uncontained AX button") }
let scale = Double(image.pixelsWide) / panel.width
guard scale > 0, abs(scale - Double(image.pixelsHigh) / panel.height) < 0.001 else { fail("PNG scale mismatch") }
let x0 = Int(ceil((button.minX - panel.minX) * scale)), x1 = Int(floor((button.maxX - panel.minX) * scale))
let y0 = Int(ceil((button.minY - panel.minY) * scale)), y1 = Int(floor((button.maxY - panel.minY) * scale))
let w = x1 - x0, h = y1 - y0
guard w >= 5, h >= 5, x0 >= 0, y0 >= 0, x1 <= image.pixelsWide, y1 <= image.pixelsHigh else { fail("Invalid pixel crop") }

var pixels = [Int](), border = [Int:Int]()
for y in 0..<h {
    for x in 0..<w {
        guard let p = image.colorAt(x: x0+x, y: y0+y)?.usingColorSpace(.sRGB), p.alphaComponent >= 0.999 else {
            fail("Need rendered, opaque sRGB samples to compare visible colours")
        }
        let rgb = (Int((255*p.redComponent).rounded()) << 16) | (Int((255*p.greenComponent).rounded()) << 8) | Int((255*p.blueComponent).rounded())
        pixels.append(rgb)
        if x == 0 || y == 0 || x == w-1 || y == h-1 { border[rgb, default:0] += 1 }
    }
}
// Perimeter establishes the flat button fill. Neighbouring pixels in the glyph must agree
// in all four directions, excluding antialiasing. An ambiguous crop produces no contrast result.
guard let bg = border.max(by: { $0.value < $1.value }), bg.value > (w+h-2) else { fail("No dominant local background") }
var solid = [Int:Int]()
for y in 1..<h-1 {
    for x in 1..<w-1 {
        let i = y*w+x, color = pixels[i]
        if color != bg.key && [-w, w, -1, 1].allSatisfy({pixels[i+$0] == color}) { solid[color, default:0] += 1 }
    }
}
let inks = solid.sorted { $0.value > $1.value }
guard let fg = inks.first, fg.value >= 5, inks.count == 1 || fg.value > inks[1].value*2 else { fail("No unambiguous solid glyph") }
var adjacent = 0
for y in 0..<h {
    for x in 0..<w where pixels[y*w+x] == fg.key {
        let radius = Int(ceil(2*scale))
        if [(-1,0),(1,0),(0,1),(0,-1)].contains(where: { dx,dy in
            (1...radius).contains { step in
                let nx = x + step*dx, ny = y + step*dy
                return nx >= 0 && nx < w && ny >= 0 && ny < h && pixels[ny*w+nx] == bg.key
            }
        }) { adjacent += 1 }
    }
}
guard adjacent >= 5 else { fail("Glyph is not adjacent to measured background") }
func luminance(_ color: Int) -> Double {
    let channels = [16,8,0].map { Double((color >> $0) & 255) / 255 }.map {
        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
    }
    return channels[0]*0.2126 + channels[1]*0.7152 + channels[2]*0.0722
}
let lo = min(luminance(fg.key), luminance(bg.key)), hi = max(luminance(fg.key), luminance(bg.key))
let result: [String:Any] = ["imagePixelCrop":[x0,y0,w,h], "space":"sRGB", "scale":scale,
    "solidGlyphPixels":fg.value, "nearbyBackgroundWitnesses":adjacent,
    "glyph":String(format:"#%06x", fg.key), "background":String(format:"#%06x", bg.key), "ratio":(hi+0.05)/(lo+0.05)]
print(String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self))
