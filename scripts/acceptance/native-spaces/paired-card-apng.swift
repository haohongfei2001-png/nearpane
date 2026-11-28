// An APNG alternative to the H.264 viewing copy. Both consume the same sealed FilmFrame array.
import AppKit
import CoreMedia
import CryptoKit
import ImageIO
import zlib

extension Data {
  fileprivate mutating func appendBE<T: FixedWidthInteger>(_ n: T) {
    var be = n.bigEndian
    Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
  }
  fileprivate mutating func chunk(_ name: String, _ payload: Data) {
    let tag = Data(name.utf8)
    appendBE(UInt32(payload.count))
    append(tag)
    append(payload)
    var crc = tag.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, 4) }
    if !payload.isEmpty {
      crc = payload.withUnsafeBytes {
        crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count))
      }
    }
    appendBE(UInt32(crc))
  }
}
enum PairedCardAPNG {
  static let filename = "paired-cards.apng", limit = 48 * 1024 * 1024
  private static func imageData(_ source: Data, width: Int, height: Int) throws -> Data {
    guard source.count == width * height * 4 else {
      throw OverviewRefusal("losslessCropSizeChanged")
    }
    let stride = 1 + 4 * width
    var scan = Data(count: stride * height)  // PNG filter 0. Preserve the source's sRGB bytes with an exact BGRA → RGBA permutation.
    try scan.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
      try source.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        let sourceBytes = src.bindMemory(to: UInt8.self)
        let outputBytes = out.bindMemory(to: UInt8.self)
        for y in 0..<height {
          for x in 0..<width {
            let sourceOffset = (y * width + x) * 4
            let destination = y * stride + 1 + x * 4
            guard sourceBytes[sourceOffset + 3] == 255 else {
              throw OverviewRefusal("losslessNonOpaqueSource")
            }
            outputBytes[destination] = sourceBytes[sourceOffset + 2]
            outputBytes[destination + 1] = sourceBytes[sourceOffset + 1]
            outputBytes[destination + 2] = sourceBytes[sourceOffset]
            outputBytes[destination + 3] = sourceBytes[sourceOffset + 3]
          }
        }
      }
    }
    var length = compressBound(UInt(scan.count))
    var data = Data(count: Int(length))
    let status = data.withUnsafeMutableBytes { out in
      scan.withUnsafeBytes { src in
        compress2(
          out.bindMemory(to: UInt8.self).baseAddress, &length,
          src.bindMemory(to: UInt8.self).baseAddress, UInt(src.count), Z_BEST_SPEED)
      }
    }
    guard status == Z_OK else { throw OverviewRefusal("losslessPNGCompressionFailed") }
    data.count = Int(length)
    return data
  }
  private static func validate(_ png: Data, against frames: [FilmFrame], width: Int, height: Int)
    throws
  {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      CGImageSourceGetCount(src) == frames.count - 1,
      let cs = CGColorSpace(name: CGColorSpace.sRGB)
    else { throw OverviewRefusal("losslessSystemDecoderCountChanged") }
    let fmt = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    for (i, frame) in frames.dropLast().enumerated() {
      try autoreleasepool {
        guard let img = CGImageSourceCreateImageAtIndex(src, i, nil), img.width == width,
          img.height == height
        else { throw OverviewRefusal("losslessSystemDecoderSizeChanged") }
        var decoded = Data(count: width * height * 4)
        try decoded.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
          guard
            let ctx = CGContext(
              data: out.baseAddress, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: cs, bitmapInfo: fmt)
          else { throw OverviewRefusal("losslessSystemDecoderUnavailable") }
          ctx.setBlendMode(.copy)
          ctx.interpolationQuality = .none
          ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard decoded == frame.bytes else {
          throw OverviewRefusal("losslessSystemDecoderPixelMismatch")
        }
      }
    }
  }
  static func write(_ frames: [FilmFrame], width: Int, height: Int, ratio: Double, folder: URL)
    throws -> [String: Any]
  {
    guard (2...110).contains(frames.count), width > 0, height > 0, width <= 8192, height <= 8192,
      width * height <= 1_000_000,
      ratio.isFinite, ratio > 0, let first = frames.first, first.stamp.ticks > 0
    else { throw OverviewRefusal("invalidLosslessInterval") }
    let scale = 60_000
    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    var header = Data()
    var animation = Data()
    header.appendBE(UInt32(width))
    header.appendBE(UInt32(height))
    header.append(contentsOf: [8, 6, 0, 0, 0])
    png.chunk("IHDR", header)
    png.chunk("sRGB", Data([0]))
    animation.appendBE(UInt32(frames.count - 1))
    animation.appendBE(UInt32(1))
    png.chunk("acTL", animation)
    // Keep all original rational source PTS and display ticks, including the terminal boundary.
    let clocks = frames.map {
      [
        NSNumber(value: $0.stamp.ticks), NSNumber(value: $0.stamp.pts.value),
        NSNumber(value: $0.stamp.pts.timescale), NSNumber(value: $0.stamp.pts.epoch),
      ]
    }
    var original = Data("NearpanePresentationTimes".utf8)
    original.append(contentsOf: [0, 0, 0, 0, 0])
    original.append(try JSONSerialization.data(withJSONObject: clocks))
    png.chunk("iTXt", original)
    var seq: UInt32 = 0
    var previous = 0
    var maxError = 0.0
    var maxDelayError = 0.0
    for (i, frame) in frames.dropLast().enumerated() {
      let next = frames[i + 1].stamp
      guard frame.stamp.pts.isNumeric, next.pts.isNumeric, next.ticks > frame.stamp.ticks,
        CMTimeCompare(next.pts, frame.stamp.pts) > 0
      else { throw OverviewRefusal("losslessClockReversed") }
      let elapsed = Double(next.ticks - first.stamp.ticks) * ratio
      guard elapsed <= 10 else { throw OverviewRefusal("losslessIntervalOutOfBounds") }
      let boundary = Int((elapsed * Double(scale)).rounded())
      let ticks = boundary - previous
      guard ticks > 0, ticks <= Int(UInt16.max) else {
        throw OverviewRefusal("losslessFrameDelayUnrepresentable")
      }
      var control = Data()
      control.appendBE(seq)
      seq += 1
      control.appendBE(UInt32(width))
      control.appendBE(UInt32(height))
      control.appendBE(UInt32(0))
      control.appendBE(UInt32(0))
      control.appendBE(UInt16(ticks))
      control.appendBE(UInt16(scale))
      control.append(contentsOf: [0, 0])
      png.chunk("fcTL", control)
      let compressed = try imageData(frame.bytes, width: width, height: height)
      guard png.count + compressed.count + 32 < limit else {
        throw OverviewRefusal("losslessFileLimitExceeded")
      }
      if i == 0 {
        png.chunk("IDAT", compressed)
      } else {
        var f = Data()
        f.appendBE(seq)
        seq += 1
        f.append(compressed)
        png.chunk("fdAT", f)
      }
      maxError = max(maxError, abs(Double(boundary) / Double(scale) - elapsed))
      maxDelayError = max(
        maxDelayError,
        abs(Double(ticks) / Double(scale) - Double(next.ticks - frame.stamp.ticks) * ratio))
      previous = boundary
    }
    png.chunk("IEND", Data())
    try validate(png, against: frames, width: width, height: height)
    let temporary = folder.appendingPathComponent(UUID().uuidString + ".tmp")
    let file = folder.appendingPathComponent(filename)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try png.write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.moveItem(at: temporary, to: file)
    return [
      "status": "CAPTURED", "file": filename,
      "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
      "width": width, "height": height, "frames": frames.count - 1, "plays": 1, "timescale": scale,
      "maxPlaybackBoundaryErrorMicroseconds": maxError * 1e6,
      "maxFrameDelayErrorMicroseconds": maxDelayError * 1e6,
      "originalPTS": "NearpanePresentationTimes",
      "systemDecodedExactBGRAFrames": frames.count - 1, "includesTerminalPicture": false,
    ]
  }
}
