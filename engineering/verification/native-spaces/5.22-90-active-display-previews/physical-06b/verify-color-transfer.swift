// From this directory: gzip -dc presentation-frames.jsonl.gz | swift verify-color-transfer.swift
// Reads only these archived synthetic-window receipts. Creates no windows and requests no permissions.
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import VideoToolbox

struct Sample: Decodable { let median, minimum, maximum: [Int] }
struct Frame: Decodable { let channel, status: Int; let qualified: Bool; let displayTime: Double?; let samples: [Sample] }
struct Event: Decodable { let epoch: Int; let sourceBracket: [Double] }
struct Window: Decodable { let events: [Event] }
struct Presentation: Decodable { let sha256: String }
struct Overview: Decodable { let crop: [Int]; let scale: Int; let sha256: String }
struct Card: Decodable { let patch: [Int] }
struct Binding: Decodable { let cardGeometry: [Card] }
struct Metrics: Decodable { let windows: [Window] }
struct Original: Decodable { let presentation: Presentation; let overview: Overview; let metrics: Metrics; let binding: Binding }
struct Pair: Decodable { let doc, epoch, phase, sourceCount, cardCount: Int; let actualSource, actualCard, predictedP3, absolutePredictionError: [Int] }
struct Colors: Decodable { let phaseComparisons: [Pair]; let overviewCentralSRGBA: [[Int]] }
struct Trial: Decodable { let input, vtSRGB, canvasSRGB: [Int]; let pixelTag, vtTag: String }
struct Synthetic: Decodable { let trials: [Trial] }
struct Diagnosis: Decodable { let colorSpace: Colors; let nativeSynthetic: Synthetic }

func read(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: name)) }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func colorModes(_ frames: [Frame], channel: Int, patch: Int, low: Double, high: Double) -> [(rgb: [Int], count: Int)] {
    var counts = [[Int]: Int]()
    for f in frames where f.channel == channel && f.qualified {
        guard let t = f.displayTime, t >= low, t < high else { continue }
        let s = f.samples[patch]
        precondition(s.minimum == s.maximum && s.median.count == 4 && s.median[3] == 255)
        counts[Array(s.median.prefix(3)), default: 0] += 1
    }
    let modes = counts.sorted { $0.value == $1.value ? $0.key.lexicographicallyPrecedes($1.key) : $0.value > $1.value }.prefix(2)
    return modes.map { (rgb: $0.key, count: $0.value) }.sorted { $0.rgb.reduce(0, +) < $1.rgb.reduce(0, +) }
}

func pixel(_ image: CGImage) -> [Int] {
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return rgba.map(Int.init)
}

@MainActor func verifyBridge(_ trial: Trial) {
    let input = trial.input
    let bgra = [UInt8(input[2]), UInt8(input[1]), UInt8(input[0]), 255]
    var storage: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess)
    let buffer = storage!
    precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
    for y in 0..<8 {
        let row = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<8 { for i in 0..<4 { row[4*x+i] = bgra[i] } }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    if trial.pixelTag != "none" {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: trial.pixelTag as CFString)!, .shouldPropagate)
    }
    var out: CGImage?
    precondition(VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &out) == noErr)
    let image = out!
    precondition(image.colorSpace?.name as String? == trial.vtTag && pixel(image) == trial.vtSRGB)
    let canvas = Canvas { c, s in c.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: s)) }.frame(width: 8, height: 8)
    let renderer = ImageRenderer(content: canvas)
    renderer.scale = 1
    precondition(renderer.cgImage.map(pixel) == trial.canvasSRGB)
}

let decoder = JSONDecoder()
let original = try decoder.decode(Original.self, from: read("result.json"))
let diagnosis = try decoder.decode(Diagnosis.self, from: read("color-and-clock-diagnosis.json"))
let stream = FileHandle.standardInput.readDataToEndOfFile()
precondition(hash(stream) == original.presentation.sha256)
let frames = try stream.split(separator: 10).map { try decoder.decode(Frame.self, from: Data($0)) }
var histogram = [Int: Int]()
for pair in diagnosis.colorSpace.phaseComparisons {
    let t = frames.filter { $0.channel == pair.doc }.compactMap(\.displayTime)
    let starts = [t.min()!] + original.metrics.windows[pair.doc].events.map { $0.sourceBracket[1] } + [t.max()!]
    let l = starts[pair.epoch] + 0.85, h = starts[pair.epoch + 1] - 0.09
    let source = colorModes(frames, channel: pair.doc, patch: 0, low: l, high: h)[pair.phase]
    let card = colorModes(frames, channel: 2, patch: pair.doc, low: l, high: h)[pair.phase]
    precondition(source == (pair.actualSource, pair.sourceCount) && card == (pair.actualCard, pair.cardCount))
    let cg = CGColor(colorSpace: srgb, components: source.rgb.map { CGFloat($0)/255 } + [1])!
    let predicted = cg.converted(to: p3, intent: .relativeColorimetric, options: nil)!.components!.prefix(3).map { Int((255*$0).rounded()) }
    let error = zip(predicted, card.rgb).map { abs($0-$1) }
    precondition(predicted == pair.predictedP3 && error == pair.absolutePredictionError)
    for v in error { histogram[v, default: 0] += 1 }
}
let bytes = try read("media/paired-overview.png")
precondition(hash(bytes) == original.overview.sha256)
let png = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
precondition(png.colorSpace?.name == CGColorSpace.sRGB)
for (n, bound) in original.binding.cardGeometry.enumerated() {
    let p = bound.patch, c = original.overview.crop, s = original.overview.scale
    let region = CGRect(x: (p[0]-c[0])*s, y: (p[1]-c[1])*s, width: p[2]*s, height: p[3]*s)
    precondition(pixel(png.cropping(to: region)!) == diagnosis.colorSpace.overviewCentralSRGBA[n])
}
MainActor.assumeIsolated { for trial in diagnosis.nativeSynthetic.trials { verifyBridge(trial) } }
print("Verified \(frames.count) frame records, \(diagnosis.colorSpace.phaseComparisons.count) independent phase pairs, both PNG crops and \(diagnosis.nativeSynthetic.trials.count) headless VideoToolbox/Canvas trials. Absolute channel errors: \(histogram.sorted { $0.key < $1.key })")
