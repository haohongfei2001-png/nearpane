// Continuous, exact-window filters. Store only color statistics and independently uniform synthetic patches.
import AppKit
import CoreMedia
import CryptoKit
import ScreenCaptureKit

struct PreviewClock:Codable {
    let uptime:Double, uncertainty:Double, machOffset:Double, hostOffset:Double, denominator:UInt32, numerator:UInt32
    static func read() throws -> Self {
        var scale=mach_timebase_info_data_t()
        guard mach_timebase_info(&scale)==KERN_SUCCESS,scale.denom>0 else{throw Refusal("machTimebaseUnavailable")}
        let begin=now(),ticks=mach_absolute_time(),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())),end=now()
        let mid=(begin+end)/2,mach=Double(ticks)*Double(scale.numer)/Double(scale.denom)/1e9
        guard end-begin<=0.01,host.isFinite,mach.isFinite else{throw Refusal("hostClockCalibrationUnavailable")}
        return Self(uptime:mid,uncertainty:(end-begin)/2,machOffset:mid-mach,hostOffset:mid-host,denominator:scale.denom,numerator:scale.numer)
    }
    func mapped(_ ticks:UInt64)->Double {Double(ticks)*Double(numerator)/Double(denominator)/1e9+machOffset}
}

private struct StreamColor:Encodable {
    let color:String, median:[Int], minimum:[Int],maximum:[Int], dominantFraction:Double
    // Never encode an image. A retained patch has one identical opaque RGBA value across all actual pixels.
    let patch:Data?
    enum CodingKeys:String,CodingKey {case color,median,minimum,maximum,dominantFraction}
}
private func sampleColor(_ pixels:CVPixelBuffer,_ frame:CGRect,_ area:CGRect,width:Int,height:Int,witness:Bool)->StreamColor? {
    guard CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA,
          CVPixelBufferGetWidth(pixels)==width,CVPixelBufferGetHeight(pixels)==height,
          let raw=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else{return nil}
    let x0=Int((area.minX-frame.minX)*2),y0=Int((area.minY-frame.minY)*2)
    guard x0>=0,y0>=0,x0+8<=CVPixelBufferGetWidth(pixels),y0+8<=CVPixelBufferGetHeight(pixels) else{return nil}
    var rgba=[[Int]](repeating:[],count:4),histogram=[UInt32:Int](),counts=[String:Int]()
    for y in y0..<(y0+8) {for x in x0..<(x0+8) {
        let k=y*CVPixelBufferGetBytesPerRow(pixels)+4*x
        let point=[Int(raw[k+2]),Int(raw[k+1]),Int(raw[k]),Int(raw[k+3])]
        for c in 0..<4 {rgba[c].append(point[c])}
        let key=UInt32(point[0])<<24 | UInt32(point[1])<<16 | UInt32(point[2])<<8 | UInt32(point[3])
        histogram[key,default:0]+=1
    }}
    for (key,n) in histogram {
        counts[PairedPreviewPalette.classify(Int(key>>24),Int((key>>16)&255),Int((key>>8)&255),Int(key&255)),default:0]+=n
    }
    let dist=rgba.map{$0.sorted()},low=dist.map{$0[0]},high=dist.map{$0[63]},median=dist.map{($0[31]+$0[32])/2}
    let mode=counts.max{$0.value<$1.value},color=(mode?.value ?? 0)>=52 ? mode!.key:"unknown"
    let exact=witness && low==high && low[3]==255 && color.contains("/")
    let patch=exact ? Data((0..<64).flatMap{_ in low.map(UInt8.init)}):nil
    return StreamColor(color:color,median:median,minimum:low,maximum:high,dominantFraction:Double(mode?.value ?? 0)/64,patch:patch)
}
private struct StreamRecord:Encodable {
    let channel:Int, sequence:Int,status:Int,callback:Double,displayTicks:UInt64?,displayTime:Double?,pts:Double?,hostPTS:Double?
    var samples:[StreamColor]
    let pixelColorSpace:String?
    var offsets:[Int]=[]
}
private final class Receiver:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let slot:Int,crop:Crop,clock:PreviewClock,witness:Bool
    let delivery=DispatchQueue(label:"nearpane.acceptance.stream.receive",qos:.userInitiated)
    private let lock=NSLock()
    private var frames=[StreamRecord](),failure:String?,newPixelFrames=0
    init(_ slot:Int,_ crop:Crop,_ clock:PreviewClock,_ witness:Bool){self.slot=slot;self.crop=crop;self.clock=clock;self.witness=witness}
    func stream(_ stream:SCStream,didStopWithError error:Error){lock.withLock{failure="streamStopped"+String((error as NSError).code)}}
    func status()->(Int,String?){lock.withLock{(newPixelFrames,failure)}}
    func since(_ index:Int)->[StreamRecord]{lock.withLock{Array(frames.dropFirst(index))}}
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType){
        guard type == .screen else{return}
        let callback=now(),meta=(CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
        let status=(meta?[.status] as? NSNumber)?.intValue ?? -1
        let ticks=(meta?[.displayTime] as? NSNumber)?.uint64Value
        let display=ticks.flatMap{$0>0 ? clock.mapped($0):nil}
        let pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        var samples=[StreamColor](),colorSpace:String?
        if status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue,buffer.isValid,
           let image=buffer.imageBuffer,CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess {
            defer {CVPixelBufferUnlockBaseAddress(image,.readOnly)}
            if let cs=CVImageBufferGetColorSpace(image)?.takeUnretainedValue(),let name=cs.name as String? {
                colorSpace=[CGColorSpace.sRGB as String,CGColorSpace.displayP3 as String,CGColorSpace.extendedSRGB as String].contains(name) ? name:"other"
            }
            samples=crop.patches.compactMap{sampleColor(image,crop.rect,$0,width:crop.config.width,height:crop.config.height,witness:witness && crop.filter.pointPixelScale==2)}
        }
        lock.withLock {
            guard frames.count<3600 else{failure="boundedStreamQueueExceeded";return}
            if samples.count==crop.patches.count {newPixelFrames+=1}
            frames.append(StreamRecord(channel:slot,sequence:frames.count+1,status:status,callback:callback,displayTicks:ticks,
                                       displayTime:display,pts:pts.isFinite ? pts:nil,hostPTS:pts.isFinite ? pts+clock.hostOffset:nil,
                                       samples:samples,pixelColorSpace:colorSpace))
        }
    }
}
private struct StreamGuard:Encodable {
    let time:Double,fullBinding:Bool,cardKinds:[String],valid:Bool,issue:String?
}
private struct StreamSummary:Encodable {
    let mode:String,rates:[Int],crops:Int,clocks:[PreviewClock],guards:[StreamGuard],pulseStarted:Double?,stopped:[Bool],reason:String?
    let packedBytes:Int,packedSHA256:String
    let requestedColorSpace:String,markerHoldSeconds:Double,phaseChannelDeviation:Int
}
enum PairedStreams {
    static func offlineChecks() throws {
        let clock=try PreviewClock.read()
        guard abs(clock.mapped(mach_absolute_time())-now())<0.01 else{throw Refusal("machClockCheckFailed")}
        let area=CGRect(x:20,y:20,width:4,height:4)
        var pixel:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,8,8,kCVPixelFormatType_32BGRA,nil,&pixel)==kCVReturnSuccess,let pixel,
              CVPixelBufferLockBaseAddress(pixel,[])==kCVReturnSuccess else{throw Refusal("offlineBufferUnavailable")}
        defer{CVPixelBufferUnlockBaseAddress(pixel,[])}
        guard let bytes=CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to:UInt8.self) else{throw Refusal("offlineBufferUnavailable")}
        var count=0
        for (epoch,pair) in PairedPreviewPalette.epochs.enumerated(){for (doc,rgb) in pair.enumerated(){for phase in [-5,5] {
            for y in 0..<8 {for x in 0..<8 {
                let k=y*CVPixelBufferGetBytesPerRow(pixel)+4*x
                bytes[k]=UInt8(rgb[2]+phase);bytes[k+1]=UInt8(rgb[1]+phase);bytes[k+2]=UInt8(rgb[0]+phase);bytes[k+3]=255
            }}
            let s=sampleColor(pixel,area,area,width:8,height:8,witness:true)
            guard s?.color=="\(doc)/\(epoch)",s?.patch?.count==256,s?.median==rgb.map({$0+phase})+[255],s?.minimum==s?.maximum
            else{throw Refusal("fixtureSRGBPhaseOrUniformRawMismatch")};count+=1
        }}}
        bytes[1]=0
        guard let partial=sampleColor(pixel,area,area,width:8,height:8,witness:true),partial.patch==nil,
              partial.minimum[1]==0,partial.minimum[1]<partial.maximum[1],
              sampleColor(pixel,area,area.offsetBy(dx:1,dy:0),width:8,height:8,witness:true)==nil
        else{throw Refusal("unverifiedPixelsEscapedBoundCapture")}
        try emit(["calibratedClockAndPixelChecks":count+2])
    }
    static func run(_ request:Request,_ crops:[Crop],_ input:[UInt32],_ folder:URL,_ confirm:() throws->[String],witness:Bool) async throws {
        let first=try PreviewClock.read()
        let receivers=crops.enumerated().map{Receiver($0.offset,$0.element,first,witness)}
        var streams=[SCStream](),enabled=[Int](),guards=[StreamGuard](),clocks=[first],pulse:Double?,issue:String?
        var stopped=Array(repeating:false,count:3),consumed=[0,0,0],packed=Data()
        func flushFrames(terminal:Bool=false) throws {
            for (i,receiver) in receivers.enumerated() {
                for var item in receiver.since(consumed[i]) {
                    let t=item.displayTime ?? item.hostPTS
                    let bracketed=t.map{frameTime in
                        guard let lower=guards.last(where:{$0.time<=frameTime}),let upper=guards.first(where:{$0.time>=item.callback}) else{return false}
                        return lower.valid && upper.valid && upper.time-lower.time<=1.2 && frameTime<=item.callback+0.005 &&
                               !guards.contains(where:{!$0.valid && $0.time>=lower.time && $0.time<=upper.time})
                    } ?? false
                    if !bracketed {
                        // A last callback newer than this checkpoint can still get a later scope read.
                        if !terminal && item.callback>(guards.last?.time ?? 0) {break}
                        item.samples=[]
                    }
                    item.offsets=item.samples.map{s in
                        guard let data=s.patch,data.count==256 else{return -1}
                        let n=packed.count;packed.append(data);return n
                    }
                    try emit(["streamFrame":item]);consumed[i]+=1
                }
            }
        }
        try emit(["streamClock":first])
        func guardScope(full:Bool) throws {
            if let reason=scope(request,crops,input) {guards.append(StreamGuard(time:now(),fullBinding:full,cardKinds:[],valid:false,issue:reason));throw Refusal(reason)}
            let kinds=full ? try confirm():[]
            if full {
                let point=try PreviewClock.read();clocks.append(point);try emit(["streamClock":point])
                guard abs(point.machOffset-first.machOffset)<=0.002,abs(point.hostOffset-first.hostOffset)<=0.002 else{throw Refusal("calibratedHostClockChanged")}
            }
            let observation=StreamGuard(time:now(),fullBinding:full,cardKinds:kinds,valid:true,issue:nil)
            guards.append(observation);try emit(["streamGuard":observation])
            if full {try flushFrames()}
        }
        do {
            guard crops.count==3 else{throw Refusal("threeExactFiltersRequired")}
            try guardScope(full:true)
            for (i,crop) in crops.enumerated() {
                let output=receivers[i],stream=SCStream(filter:crop.filter,configuration:crop.config,delegate:output)
                try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:output.delivery)
                streams.append(stream)
            }
            for (i,stream) in streams.enumerated(){try await stream.startCapture();enabled.append(i)}
            let begin=now();var fullAt=begin
            while true {
                let t=now(),full=t-fullAt>=2.0
                try guardScope(full:full);if full{fullAt=now()}
                if let failure=receivers.compactMap({$0.status().1}).first{throw Refusal(failure)}
                if pulse==nil && t-begin>=2.0 && receivers.allSatisfy({$0.status().0>=2}) {
                    try Data().write(to:folder.appendingPathComponent("preview-start"),options:.withoutOverwriting)
                    pulse=now()
                }
                if pulse==nil && t-begin>=5.0 {throw Refusal("threeResidentStreamsDidNotBecomeReady")}
                if let pulse,t-pulse>=22.2 {break}
                try await Task.sleep(for:.milliseconds(200))
            }
            try guardScope(full:true)
        } catch {issue=(error as? Refusal)?.reason ?? "residentStreamSetupOrScopeUnavailable"}
        for i in enabled.reversed() {
            do{try await streams[i].stopCapture();stopped[i]=true}catch{issue=issue ?? "streamStopUnconfirmed"}
        }
        try flushFrames(terminal:true)
        if !packed.isEmpty {try packed.write(to:folder.appendingPathComponent("stream-patches.rgba"),options:.withoutOverwriting)}
        let digest=SHA256.hash(data:packed).map{String(format:"%02x",$0)}.joined()
        let summary=StreamSummary(mode:"three-resident-SCStreams",rates:[60,60,60],crops:crops.count,clocks:clocks,guards:guards,pulseStarted:pulse,
                                  stopped:stopped,reason:issue,packedBytes:packed.count,packedSHA256:digest,
                                  requestedColorSpace:CGColorSpace.sRGB as String,markerHoldSeconds:3.6,phaseChannelDeviation:5)
        try emit(["streamSession":summary])
        if let issue{throw Refusal(issue)}
    }
}
