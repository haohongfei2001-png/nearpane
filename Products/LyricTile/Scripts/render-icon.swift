import AppKit
import Foundation

// Exact geometry from the approved, repository-owned SVG master. No web font,
// raster mockup, or generated interpretation is used in the shipped icon.
guard CommandLine.arguments.count == 2 else { fatalError("usage: render-icon.swift output.iconset") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func writeIcon(pixels: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
    cg.setAllowsAntialiasing(true)
    let shape = CGPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944), cornerWidth: 218, cornerHeight: 218, transform: nil)
    cg.saveGState(); cg.addPath(shape); cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.cgColor, NSColor(srgbRed: 0.914, green: 0.922, blue: 0.918, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 60), end: CGPoint(x: 900, y: 1000), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: CGRect(x: 42, y: 42, width: 940, height: 940), cornerWidth: 216, cornerHeight: 216, transform: nil))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor); cg.setLineWidth(4); cg.strokePath()
    cg.translateBy(x: 135, y: 135); cg.scaleBy(x: 5.89, y: 5.89)
    cg.setStrokeColor(NSColor(srgbRed: 0.208, green: 0.224, blue: 0.251, alpha: 1).cgColor)
    cg.setLineWidth(10); cg.setLineCap(.round)
    for (y, end) in [(37.0, 91.0), (64.0, 104.0), (91.0, 79.0)] {
        cg.move(to: CGPoint(x: 39, y: y)); cg.addLine(to: CGPoint(x: end, y: y)); cg.strokePath()
    }
    cg.setFillColor(NSColor(srgbRed: 0.459, green: 0.400, blue: 0.808, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: 18, y: 59, width: 10, height: 10))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try writeIcon(pixels: size, name: "icon_\(size)x\(size).png")
    try writeIcon(pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
