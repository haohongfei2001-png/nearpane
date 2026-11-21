import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct MovieInput: Decodable { let file: URL; let time: Double }
struct MovieError: Error {}
@main struct TitleMovie {
    static func main() async throws {
        let originalSize = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "source-size"
        guard CommandLine.arguments.count == 3 || originalSize else { throw MovieError() }
        let manifest = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath:CommandLine.arguments[2])
        let frames = try JSONDecoder().decode([MovieInput].self,from:Data(contentsOf:manifest))
        guard frames.count >= 2, !FileManager.default.fileExists(atPath:output.path) else { throw MovieError() }
        let writer = try AVAssetWriter(outputURL:output,fileType:.mp4)
        var width=360, height=102
        if originalSize {
            guard let source=CGImageSourceCreateWithURL(frames[0].file as CFURL,nil), let frame=CGImageSourceCreateImageAtIndex(source,0,nil),
                  [frame.width,frame.height].allSatisfy({ $0 > 0 && $0 <= 8192 && $0.isMultiple(of:2) }) else {throw MovieError()}
            width=frame.width; height=frame.height
        }
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height]); input.expectsMediaDataInRealTime=false
        let settings:[String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height]
        let sink=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:settings)
        guard writer.canAdd(input) else {throw MovieError()};writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? MovieError()};writer.startSession(atSourceTime:.zero)
        for frame in frames {
            guard frame.file.deletingLastPathComponent().standardizedFileURL==manifest.deletingLastPathComponent().standardizedFileURL,
                  let src=CGImageSourceCreateWithURL(frame.file as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil),
                  !originalSize || (image.width == width && image.height == height), let pool=sink.pixelBufferPool else {throw MovieError()}
            var buffer:CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let buffer else {throw MovieError()}
            CVPixelBufferLockBaseAddress(buffer,[])
            guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else {throw MovieError()}
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));CVPixelBufferUnlockBaseAddress(buffer,[])
            let end=ProcessInfo.processInfo.systemUptime+4
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < end {try await Task.sleep(for:.milliseconds(10))}
            guard input.isReadyForMoreMediaData,sink.append(buffer,withPresentationTime:CMTime(seconds:frame.time,preferredTimescale:600)) else {throw writer.error ?? MovieError()}
        }
        writer.endSession(atSourceTime:CMTime(seconds:frames.last!.time+0.1,preferredTimescale:600));input.markAsFinished();await writer.finishWriting()
        let asset=AVURLAsset(url:output);let duration=try await asset.load(.duration).seconds
        guard writer.status == .completed, try await asset.loadTracks(withMediaType:.video).count==1,
              try await asset.loadTracks(withMediaType:.audio).isEmpty, duration>0 else {throw MovieError()}
        print(String(decoding:try JSONSerialization.data(withJSONObject:["videoTracks":1,"audioTracks":0,"seconds":duration,"inputFrames":frames.count]),as:UTF8.self))
    }
}
