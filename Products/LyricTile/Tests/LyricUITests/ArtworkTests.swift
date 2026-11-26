import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LyricUI

@Suite("Native artwork memory boundary")
struct ArtworkTests {
    @Test func decodedCoverIsBoundedWithoutChangingItsAspectRatio() async throws {
        let authoredImage = try image(width: 1600, height: 900)
        let encoded = try encode([authoredImage], type: .png)
        let decoder = LyricArtworkDecoder()
        let value = await decoder.thumbnail(from: encoded)
        let thumbnail = try #require(value)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 512)
        #expect(decoded.height == 288)
        #expect(thumbnail.count < 2 * 1024 * 1024)
    }
    @Test func smallCompressedDataCannotBypassThePixelDimensionBoundary() async throws {
        // A flat, extremely wide image compresses to few bytes. A byte-only limit
        // would miss it; the production decoder must inspect actual image dimensions.
        let encoded = try encode([image(width: 5000, height: 1)], type: .png)
        #expect(encoded.count < 8 * 1024 * 1024)
        let decoder = LyricArtworkDecoder()
        let result = await decoder.thumbnail(from: encoded)
        #expect(result == nil)
    }
    @Test func animationAndNonImageDataRemainMissingArtwork() async throws {
        let frame = try image(width: 8, height: 8)
        let animation = try encode([frame, frame], type: .gif)
        let decoder = LyricArtworkDecoder()
        let animated = await decoder.thumbnail(from: animation)
        let invalid = await decoder.thumbnail(from: Data("authored non-image test input".utf8))
        #expect(animated == nil)
        #expect(invalid == nil)
    }
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    private func encode(_ images: [CGImage], type: UTType) throws -> Data {
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes as CFMutableData, type.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return Data(bytes: bytes.bytes, count: bytes.length)
    }
}
