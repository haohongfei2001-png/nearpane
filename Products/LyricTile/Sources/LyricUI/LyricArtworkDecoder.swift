import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Serial, off-main image decoding. Only a bounded thumbnail crosses back to AppKit.
/// A cancelled request may finish an in-flight ImageIO call, but cannot publish an image.
actor LyricArtworkDecoder {
    static let maximumInputBytes = 8 * 1024 * 1024
    private static let maximumSourceDimension = 4096.0
    private static let maximumSourcePixels = 16_777_216.0
    private static let maximumThumbnailDimension = 512

    func thumbnail(from data: Data) -> Data? {
        guard !Task.isCancelled, !data.isEmpty, data.count <= Self.maximumInputBytes else { return nil }
        return autoreleasepool {
            let sourceOptions: [String: Any] = [
                kCGImageSourceShouldCache as String: false,
                kCGImageSourceShouldAllowFloat as String: false
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
                  width.isFinite, height.isFinite, width >= 1, height >= 1,
                  width <= Self.maximumSourceDimension, height <= Self.maximumSourceDimension,
                  width * height <= Self.maximumSourcePixels,
                  !Task.isCancelled else { return nil }

            let thumbnailOptions: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: Self.maximumThumbnailDimension,
                kCGImageSourceShouldCacheImmediately as String: true,
                kCGImageSourceShouldAllowFloat as String: false
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
                  thumbnail.width > 0, thumbnail.height > 0,
                  thumbnail.width <= Self.maximumThumbnailDimension,
                  thumbnail.height <= Self.maximumThumbnailDimension,
                  !Task.isCancelled else { return nil }

            // Re-encoding the thumbnail also prevents NSImage from lazily decoding the
            // original full-resolution image, extra frames, or embedded thumbnails.
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024,
                  !Task.isCancelled else { return nil }
            return Data(bytes: output.bytes, count: output.length)
        }
    }
}
