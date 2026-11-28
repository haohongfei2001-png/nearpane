// Makes a silent movie from the actual marked window's AppKit content and monotonic timestamps.
// The neutral canvas retains movement; it never contains any pixels from the desktop.
import AVFoundation
import CoreVideo
import Foundation
import ImageIO

enum EvidenceError: Error { case invalidImage, missingSamples, failedEncoding }

func image(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EvidenceError.invalidImage }
    return result
}

/// A transparent, uniformly colored, or empty window cannot stand in for a picture of the tools.
func inspect(_ image: CGImage) throws -> [String:Int] {
    let w = image.width, h = image.height
    guard w > 0 && h > 0 && w <= 1024 && h <= 512 else { throw EvidenceError.invalidImage }
    var pixels = [UInt8](repeating: 0, count: w*h*4)
    let result: [String:Int] = try pixels.withUnsafeMutableBytes { bytes in
        guard let c = CGContext(data: bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EvidenceError.invalidImage
        }
        c.draw(image, in:CGRect(x:0,y:0,width:w,height:h))
        var content = 0, colors = Set<Int>(), bright = 0, dark = 255
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i+3] > 32 {
            let r=Int(bytes[i]), g=Int(bytes[i+1]), b=Int(bytes[i+2])
            let l=(r*3+g*6+b)/10
            bright=max(bright,l); dark=min(dark,l); content += 1
            colors.insert((r<<16)|(g<<8)|b)
        }
        return ["pixels":content,"colors":colors.count,"contrast":max(0,bright-dark),"width":w,"height":h]
    }
    return result
}

struct Sample: Decodable {
    let x,y,width,height,uptime: Double
    let id: Int
}

@main struct Movie {
    static func main() async throws {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "inspect" {
            let facts = try inspect(image(at: URL(fileURLWithPath:args[1])))
            print(String(decoding: try JSONSerialization.data(withJSONObject:facts),as:UTF8.self))
            return
        }
        guard args.count == 4, let run = UUID(uuidString:args[1]), let wid = Int(args[2]) else { throw EvidenceError.missingSamples }
        let dir=URL(fileURLWithPath:args[0],isDirectory:true)
        let prefix="tool-frame-" + run.uuidString.lowercased() + "-"
        let files = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension=="json" }.sorted { $0.path < $1.path }
        let samples = try files.map { try JSONDecoder().decode(Sample.self,from:Data(contentsOf:$0)) }
        guard let first=samples.first, samples.count>=10, samples.allSatisfy({ $0.id == wid }) else { throw EvidenceError.missingSamples }
        let left=samples.map(\.x).min()!-8, bottom=samples.map(\.y).min()!-8
        let w=Int(ceil((samples.map { $0.x+$0.width }.max()!-left+8)/2))*2
        let h=Int(ceil((samples.map { $0.y+$0.height }.max()!-bottom+8)/2))*2
        guard (20...1000).contains(w), (20...500).contains(h) else {throw EvidenceError.missingSamples}
        let url=URL(fileURLWithPath:args[3]),writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h])
        let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h])
        writer.add(input)
        guard writer.startWriting() else {throw EvidenceError.failedEncoding}
        writer.startSession(atSourceTime:.zero)
        var valid = 0
        for (file,s) in zip(files,samples) {
            let png = try image(at:file.deletingPathExtension().appendingPathExtension("png"))
            let facts = try inspect(png)
            if facts["colors",default:0] > 6 && facts["contrast",default:0] >= 12 {valid += 1}
            guard s.uptime-first.uptime >= 0, s.uptime-first.uptime < 65 else {throw EvidenceError.missingSamples}
            let deadline = ContinuousClock.now.advanced(by:.seconds(3))
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
            var buffer: CVPixelBuffer?
            guard input.isReadyForMoreMediaData, let pool=adapter.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let buf=buffer else {throw EvidenceError.failedEncoding}
            CVPixelBufferLockBaseAddress(buf,[])
            let ctx = CGContext(data:CVPixelBufferGetBaseAddress(buf),width:w,height:h,bitsPerComponent:8,
                bytesPerRow:CVPixelBufferGetBytesPerRow(buf),space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(gray:0.28,alpha:1);ctx.fill(CGRect(x:0,y:0,width:w,height:h))
            ctx.draw(png,in:CGRect(x:s.x-left,y:s.y-bottom,width:s.width,height:s.height))
            CVPixelBufferUnlockBaseAddress(buf,[])
            guard adapter.append(buf,withPresentationTime:CMTime(seconds:s.uptime-first.uptime,preferredTimescale:60000))
            else {throw EvidenceError.failedEncoding}
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, valid >= 10, valid*2 >= samples.count else {throw EvidenceError.failedEncoding}
        print("\(samples.count) real AppKit samples, \(valid) nonblank, duration \(samples.last!.uptime-first.uptime)s, silent")
    }
}
