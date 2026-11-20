import Foundation
import AVFoundation

@main
struct DragFilmChecks {
    static func main() async throws {
        let url=URL(fileURLWithPath:CommandLine.arguments[1]),width=96,height=64
        let display=CGRect(x:0,y:0,width:width,height:height),a=CGRect(x:6,y:8,width:40,height:36),b=CGRect(x:44,y:11,width:40,height:39)
        func raster(_ windows:[CGRect])throws->DragFilmRaster {
            var raw:CVPixelBuffer?
            guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,nil,&raw)==kCVReturnSuccess,let raw else{fatalError("testBuffer")}
            guard CVPixelBufferLockBaseAddress(raw,[])==kCVReturnSuccess,let ptr=CVPixelBufferGetBaseAddress(raw)?.assumingMemoryBound(to:UInt8.self) else{fatalError("testPixels")}
            for y in 0..<height {for x in 0..<width {
                let p=ptr+y*CVPixelBufferGetBytesPerRow(raw)+x*4,pt=CGPoint(x:x,y:y)
                let bgra:[UInt8]
                if x==8 && y==12 {bgra=[241,222,61,0]}
                else if windows[0].contains(pt){bgra=[204,123,45,255]}
                else if windows[1].contains(pt){bgra=[53,139,227,255]}
                else{bgra=[205,33,196,255]} // sentinel: private colored data outside both registered windows
                for i in 0..<4 {p[i]=bgra[i]}
            }}
            CVPixelBufferUnlockBaseAddress(raw,[])
            return try DragFilmRaster.copy(raw,width:width,height:height,display:display,windows:windows)
        }
        let before=try raster([a,b])
        precondition(before.agrees(with:[a,b],display:display,width:width,height:height))
        precondition(!before.agrees(with:[b,a],display:display,width:width,height:height))
        for y in 0..<height {for x in 0..<width {
            let offset=(y*width+x)*4,pt=CGPoint(x:x,y:y),pixel=Array(before.bytes[offset..<offset+4])
            precondition(pixel[3]==255)
            if (!a.contains(pt) && !b.contains(pt)) || (x==8 && y==12) {precondition(pixel==[47,47,47,255])}
        }}
        let moveA=CGRect(x:51,y:5,width:38,height:54),moveB=CGRect(x:3,y:5,width:38,height:54)
        let after=try raster([moveA,moveB]);precondition(after.agrees(with:[moveA,moveB],display:display,width:width,height:height))
        let ticks:[UInt64]=[1_000_000,1_055_000,1_140_000,1_275_000]
        let frames=ticks.enumerated().map { i,t in
            FilmFrame(stamp:FilmStamp(ticks:t,uptime:Double(t)/1e6,callback:Double(t)/1e6+0.003,pts:CMTime(value:Int64(t),timescale:1_000_000)),
                      epochs:[],bytes:i==3 ? Data():(i==2 ? after.bytes:before.bytes))
        }
        let record=try await PairedCardFilm.encode(frames,width:width,height:height,ratio:1e-6,output:url)
        precondition(record["encodedFrames"] as? Int==3 && record["audioTracks"] as? Int==0)
        let duration=record["duration"] as! Double;precondition(abs(duration-0.275)<0.0001)
        let asset=AVURLAsset(url:url),track=try await asset.loadTracks(withMediaType:.video)[0]
        let reader=try AVAssetReader(asset:asset),decode=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(decode);precondition(reader.startReading())
        var pts=[Double]()
        while let sample=decode.copyNextSampleBuffer() {
            guard let image=sample.imageBuffer else{continue}
            CVPixelBufferLockBaseAddress(image,.readOnly);defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
            let p=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt8.self)
            for c in 0..<3 {precondition(abs(Int(p[c])-47)<=4)};precondition(p[3]==255)
            pts.append(sample.presentationTimeStamp.seconds)
        }
        precondition(pts.count==3 && zip(pts,[0,0.055,0.14]).allSatisfy{abs($0-$1)<0.0001})
        print("{\"status\":\"PASS\",\"mode\":\"offline\",\"opaquePixelsChecked\":6144,\"decodedFrames\":3,\"audioTracks\":0,\"duration\":0.275}")
    }
}
