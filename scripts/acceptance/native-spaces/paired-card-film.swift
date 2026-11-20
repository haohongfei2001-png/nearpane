// Silent, separately timed evidence from the installed Host's single native window.
import AppKit
import AVFoundation
import CryptoKit
import ScreenCaptureKit

private typealias FilmRow=[String:Any]
private struct FilmStamp {
    let ticks:UInt64,uptime:Double,callback:Double,pts:CMTime
}
private struct FilmFrame {
    let stamp:FilmStamp,epochs:[Int],bytes:Data
}
struct CardFilmFailure:Error {
    let reason:String,details:[String:Any]
}
private struct FilmClock {
    let ratio:Double,offset:Double
    init() throws {
        let a=captureUptime(),ticks=mach_absolute_time(),b=captureUptime()
        var timebase=mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase)==KERN_SUCCESS,timebase.denom>0,b-a<=0.01 else{throw OverviewRefusal("filmPresentationClockUnavailable")}
        ratio=Double(timebase.numer)/Double(timebase.denom)/1e9
        offset=(a+b)/2-Double(ticks)*ratio
    }
    func mapped(_ ticks:UInt64)->Double {Double(ticks)*ratio+offset}
}
private func currentInput()->[UInt32] {
    [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map{CGEventSource.counterForEventType(.hidSystemState,eventType:$0)}
}
private func exactPanel(_ n:UInt32,_ host:pid_t,_ expected:CGRect)->Bool {
    guard let ids=CFArrayCreateMutable(nil,1,nil),let object=UnsafeRawPointer(bitPattern:UInt(n)) else{return false}
    CFArrayAppendValue(ids,object)
    guard let rows=CGWindowListCreateDescriptionFromArray(ids) as? [FilmRow],rows.count==1,let r=rows.first,
          r[kCGWindowNumber as String] as? UInt32==n,r[kCGWindowOwnerPID as String] as? pid_t==host,
          r[kCGWindowIsOnscreen as String] as? Bool==true,r[kCGWindowLayer as String] as? Int==Int(CGWindowLevelForKey(.floatingWindow)),
          let dict=r[kCGWindowBounds as String] as? NSDictionary,CGRect(dictionaryRepresentation:dict)==expected else{return false}
    return true
}
private final class FilmReceiver:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let queue=DispatchQueue(label:"nearpane.acceptance.card-film",qos:.userInitiated)
    let region:WindowSampleRegion,scale:Int,area:CGRect,bodies:[CGRect],window:SCWindow,host:pid_t,hid:[UInt32],clock:FilmClock
    private let lock=NSLock()
    private var active=true,frames=[FilmFrame](),idle=0,fault:String?
    let began:Double
    init(region:WindowSampleRegion,scale:Int,area:CGRect,pictures:[CGRect],window:SCWindow,host:pid_t,hid:[UInt32],clock:FilmClock,began:Double) {
        self.region=region;self.scale=scale;self.area=area;self.window=window;self.host=host;self.hid=hid;self.clock=clock;self.began=began
        bodies=pictures.map{CGRect(x:$0.minX+$0.width*0.12,y:$0.minY+$0.height*0.38,width:$0.width*0.76,height:$0.height*0.48)}
    }
    func state()->(Int,String?) {lock.withLock{(frames.count,fault)}}
    func seal(){lock.withLock{active=false}}
    func result()->([FilmFrame],Int) {lock.withLock{(frames,idle)}}
    func stop(_ why:String){lock.withLock{if active && fault==nil {fault=why;active=false}}}
    func stream(_ stream:SCStream,didStopWithError error:Error){stop("filmSystemStreamStopped")}
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen,lock.withLock({active}) else{return}
        do {
            let callback=captureUptime()
            guard let meta=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
                  let status=(meta[.status] as? NSNumber)?.intValue else{throw OverviewRefusal("filmFrameStatusMissing")}
            if status==SCFrameStatus.idle.rawValue {lock.withLock{idle+=1};return}
            if status==SCFrameStatus.started.rawValue && sample.imageBuffer==nil && state().0==0 {return}
            guard status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue else{throw OverviewRefusal("filmInterruptedOrBlankPresentation")}
            let pts=CMSampleBufferGetPresentationTimeStamp(sample)
            guard let ticks=(meta[.displayTime] as? NSNumber)?.uint64Value,ticks>0,pts.isNumeric,pts.timescale>0 else{throw OverviewRefusal("filmMissingOriginalPresentationTime")}
            let uptime=clock.mapped(ticks)
            if uptime<began && state().0==0 {return} // A sample already in flight when the first scope guard completed.
            guard lock.withLock({frames.last.map{uptime-$0.stamp.uptime<=0.75} ?? true}) else{throw OverviewRefusal("filmUnobservedPresentationInterval")}
            guard uptime>=began,uptime<=callback+0.01,callback-uptime<0.65,
                  lock.withLock({frames.last.map{$0.stamp.ticks<ticks && CMTimeCompare($0.stamp.pts,pts)<0} ?? true}) else{throw OverviewRefusal("filmDiscontinuousPresentationTime")}
            let n=state().0
            guard n<110,(n+1)*region.width*region.height*4<=96*1024*1024 else{throw OverviewRefusal("filmBoundedFrameMemoryExceeded")}
            guard currentInput()==hid,NSEvent.pressedMouseButtons==0,exactPanel(window.windowID,host,window.frame) else{throw OverviewRefusal("filmPanelOrPhysicalInputChanged")}
            guard sample.isValid,CMSampleBufferDataIsReady(sample),let image=sample.imageBuffer,
                  CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
                  CVPixelBufferGetWidth(image)==region.windowWidth,CVPixelBufferGetHeight(image)==region.windowHeight,
                  CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw OverviewRefusal("filmUnreadableNativeFrame")}
            defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
            guard let address=CVPixelBufferGetBaseAddress(image) else{throw OverviewRefusal("filmEmptyFrame")}
            let bytes=try region.copyBGRA(from:address,stride:CVPixelBufferGetBytesPerRow(image))
            let picture=ImageRead(pixels:bytes,width:region.width,height:region.height,area:area,scale:scale,start:uptime,end:callback)
            let epochs=try bodies.enumerated().map{try picture.marker($0.element,document:$0.offset)}
            guard currentInput()==hid else{throw OverviewRefusal("filmPhysicalInputDuringFrame")}
            let frame=FilmFrame(stamp:FilmStamp(ticks:ticks,uptime:uptime,callback:callback,pts:pts),epochs:epochs,bytes:bytes)
            lock.withLock{if active{frames.append(frame)}}
        } catch {stop((error as? OverviewRefusal)?.reason ?? "filmUnconfirmedCardFrame")}
    }
}

struct CardFilmScopeRead {
    let start:Double,end:Double
}
// Every source presentation and callback must lie between two complete successful
// identity checks. A sample acquired during a check uses the adjacent outer pair.
func cardFilmBracket(_ t:Double,_ callback:Double,_ guards:[CardFilmScopeRead])->[Int]? {
    guard let left=guards.lastIndex(where:{$0.end<=t}),let right=guards.firstIndex(where:{$0.start>=callback}),
          left<right,guards[right].end-guards[left].start<=2.5 else{return nil}
    return [left,right]
}

enum PairedCardFilm {
    static func capture(folder:URL,window:SCWindow,area:CGRect,cards:[CGRect],pictures:[CGRect],hid:[UInt32],bound:[String:Any],
                        confirm:() throws->Void,references:() async throws->([Int],[[Double]])) async throws->[String:Any] {
        guard CommandLine.arguments.last=="--film",ProcessInfo.processInfo.environment["NEARPANE_PAIRED_FILM"]=="1",
              let host=bound["hostPID"] as? pid_t,let fixture=bound["fixturePID"] as? pid_t,let birth=bound["fixtureBirth"] as? UInt64,
              let ids=bound["numbers"] as? [UInt32],hid.count==5,hid==currentInput(),cards.count==2,pictures.count==2 else{throw OverviewRefusal("filmSessionNotExplicitlyBound")}
        let (filter,config,region,scale)=try exactWindowCapture(window,area:area,allowed:cards)
        guard region.width.isMultiple(of:2),region.height.isMultiple(of:2),region.width*region.height<=1_000_000 else{throw OverviewRefusal("filmUnencodableNativeGeometry")}
        let command=folder.appendingPathComponent("film-marker.json"),destination=folder.appendingPathComponent("paired-cards.mp4")
        guard !FileManager.default.fileExists(atPath:command.path),!FileManager.default.fileExists(atPath:destination.path) else{throw OverviewRefusal("filmOutputAlreadyExists")}
        var guards=[CardFilmScopeRead](),refs=[FilmRow]()
        func guardScope() throws {
            let t=captureUptime();try confirm();guards.append(CardFilmScopeRead(start:t,end:captureUptime()))
        }
        func reference(_ label:String) async throws->[Int] {
            let (colors,samples)=try await references()
            guard colors.count==2,colors[0]==colors[1],samples.count==2 else{throw OverviewRefusal("filmFixtureEpochUnconfirmed")}
            refs.append(["stage":label,"epochs":colors,"samples":samples])
            return colors
        }
        try guardScope()
        let first=try await reference("initial")
        try guardScope()
        let next=(first[0]+3)%PairedPreviewPalette.epochs.count
        config.minimumFrameInterval=CMTime(value:1,timescale:12);config.queueDepth=4
        let clock=try FilmClock()
        let sink=FilmReceiver(region:region,scale:scale,area:area,pictures:pictures,window:window,host:host,hid:hid,clock:clock,began:guards.last!.end)
        let stream=SCStream(filter:filter,configuration:config,delegate:sink)
        try stream.addStreamOutput(sink,type:.screen,sampleHandlerQueue:sink.queue)
        var issued:Double?,observedNext=false,ownsMarker=false
        func describeFailure(_ error:Error)->CardFilmFailure {
            let (seen,idle)=sink.result()
            let reason=(error as? OverviewRefusal)?.reason ?? "filmCaptureServiceFailed"
            return CardFilmFailure(reason:reason,details:["status":"BLOCKED","reason":reason,"timingMeasurement":false,"publicFileSaved":false,
                "eligibleFramesBeforeStop":seen.count,"systemIdleCallbacks":idle,"scopeReads":guards.map{[$0.start,$0.end]},"sourceObservations":refs,
                "fixtureMarkerIssued":issued != nil,"secondSourceColorObserved":observedNext])
        }
        defer{if ownsMarker{try? FileManager.default.removeItem(at:command)}}
        do {
            try await stream.startCapture()
            let start=captureUptime(),until=start+5.5
            while captureUptime()<until {
                if let error=sink.state().1 {throw OverviewRefusal(error)}
                try guardScope()
                if issued==nil,sink.state().0>=3,captureUptime()-start>=1 {
                    let t=captureUptime(),mark=PairedFilmMarker(session:folder.lastPathComponent,pid:fixture,birth:birth,numbers:ids.map(Int.init),epoch:next,issued:t)
                    try JSONEncoder().encode(mark).write(to:command,options:.withoutOverwriting)
                    ownsMarker=true;issued=t
                } else if let issued,!observedNext,captureUptime()-issued>=0.3 {
                    let colors=try await reference("postCommand")
                    observedNext=colors==[next,next]
                    guard observedNext || colors==first else{throw OverviewRefusal("filmUnexpectedFixtureSource")}
                }
                try await Task.sleep(for:.milliseconds(140))
            }
            sink.seal()
            try await stream.stopCapture()
            sink.queue.sync{}
        } catch {
            sink.seal();try? await stream.stopCapture();sink.queue.sync{}
            throw describeFailure(error)
        }
        do {
        guard sink.state().1==nil else{throw OverviewRefusal(sink.state().1!)}
        try guardScope()
        let last=try await reference("terminal")
        try guardScope()
        guard let issued,observedNext,last==[next,next] else{throw OverviewRefusal("filmChangedFixturePixelsUnconfirmed")}
        let (frames,idles)=sink.result()
        guard frames.count>=5,let head=frames.first,let end=frames.last,end.stamp.uptime-head.stamp.uptime>=2,
              head.epochs==first else{throw OverviewRefusal("filmInitialMarkersOrRealDurationUnconfirmed")}
        var evidence=[FilmRow](),lastTime=head.stamp.uptime,maxGap=0.0
        for (i,f) in frames.enumerated() {
            let stamp=f.stamp,gap=stamp.uptime-lastTime
            guard (i==0 || gap>0),gap<=0.75,let bracket=cardFilmBracket(stamp.uptime,stamp.callback,guards) else{throw OverviewRefusal("filmUnobservedIntervalOrBinding")}
            guard zip(f.epochs,first).allSatisfy({$0==$1 || ($0==next && stamp.uptime>=issued)}) else{throw OverviewRefusal("filmColorNotSeenInEnrolledSources")}
            maxGap=max(maxGap,gap);lastTime=stamp.uptime
            evidence.append(["displayTicks":stamp.ticks,"presentationUptime":stamp.uptime,"callbackUptime":stamp.callback,
                             "ptsValue":stamp.pts.value,"ptsTimescale":stamp.pts.timescale,"cardEpochs":f.epochs,"scopeReads":bracket,
                             "relativeTime":Double(stamp.ticks-head.stamp.ticks)*clock.ratio,"encoded":i<frames.count-1,
                             "cropSHA256":SHA256.hash(data:f.bytes).map{String(format:"%02x",$0)}.joined()])
        }
        let temp=folder.appendingPathComponent(UUID().uuidString+".mp4")
        defer{try? FileManager.default.removeItem(at:temp)}
        let movie=try await encode(frames,width:region.width,height:region.height,ratio:clock.ratio,output:temp)
        let data=try Data(contentsOf:temp)
        try FileManager.default.moveItem(at:temp,to:destination)
        var row=bound
        row.merge(["status":"CAPTURED","file":"paired-cards.mp4","sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),
                   "captureSource":"desktopIndependentWindow","includedWindowNumbers":[window.windowID],"audioTracks":0,
                   "nativeTransparencyBacking":"solidWhite","cardGapBacking":"solidWhite","captureIncludesChildWindows":false,
                   "scopeReads":guards.map{[$0.start,$0.end]},"sourceObservations":refs,"fixtureChangedAt":issued,"initialEpoch":first[0],"newEpoch":next,
                   "bothChangedInEncodedFrames":frames.dropLast().contains{$0.epochs==[next,next]},"timingMeasurement":false,
                   "scale":scale,"width":region.width,"height":region.height,"maximumPresentationGapSeconds":maxGap,
                   "systemIdleCallbacks":idles,"frames":evidence,"container":movie] as FilmRow){_,v in v}
        return row
        } catch {throw describeFailure(error)}
    }

    // The last actual presentation closes the movie interval. No extra repeated
    // picture or guessed terminal hold is added to the writer timeline.
    private static func encode(_ frames:[FilmFrame],width:Int,height:Int,ratio:Double,output:URL) async throws->FilmRow {
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        writer.movieTimeScale=60_000
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:false,
            AVVideoAverageBitRateKey:max(900_000,width*height*10)]])
        input.expectsMediaDataInRealTime=false;input.mediaTimeScale=60_000
        let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        guard writer.canAdd(input) else{throw OverviewRefusal("filmEncoderUnavailable")};writer.add(input)
        guard writer.startWriting() else{throw OverviewRefusal("filmEncoderStartFailed")}
        writer.startSession(atSourceTime:.zero)
        let first=frames[0].stamp.ticks
        let times=frames.map{CMTime(seconds:Double($0.stamp.ticks-first)*ratio,preferredTimescale:60_000)}
        do {
            for (frame,time) in zip(frames.dropLast(),times) {
                let deadline=captureUptime()+1
                while !input.isReadyForMoreMediaData && captureUptime()<deadline {try await Task.sleep(for:.milliseconds(6))}
                guard input.isReadyForMoreMediaData,let pool=adapter.pixelBufferPool else{throw OverviewRefusal("filmEncoderUnavailable")}
                var new:CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&new)==kCVReturnSuccess,let pixel=new,
                      CVPixelBufferLockBaseAddress(pixel,[])==kCVReturnSuccess else{throw OverviewRefusal("filmEncodingBufferUnavailable")}
                guard let dst=CVPixelBufferGetBaseAddress(pixel) else{CVPixelBufferUnlockBaseAddress(pixel,[]);throw OverviewRefusal("filmEmptyEncodingBuffer")}
                frame.bytes.withUnsafeBytes { b in
                    guard let src=b.baseAddress else{return}
                    for y in 0..<height {dst.advanced(by:y*CVPixelBufferGetBytesPerRow(pixel)).copyMemory(from:src.advanced(by:y*width*4),byteCount:width*4)}
                }
                CVPixelBufferUnlockBaseAddress(pixel,[])
                guard adapter.append(pixel,withPresentationTime:time) else{throw OverviewRefusal("filmEncodingRejectedFrame")}
            }
            writer.endSession(atSourceTime:times.last!);input.markAsFinished();await writer.finishWriting()
        } catch {writer.cancelWriting();throw error}
        guard writer.status == .completed else{throw OverviewRefusal("filmEncodingFailed")}
        let asset=AVURLAsset(url:output),tracks=try await asset.loadTracks(withMediaType:.video)
        guard tracks.count==1,try await asset.loadTracks(withMediaType:.audio).isEmpty,let track=tracks.first,
              try await track.load(.naturalSize)==CGSize(width:width,height:height) else{throw OverviewRefusal("filmOutputTracksUnverified")}
        let reader=try AVAssetReader(asset:asset),samples=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        guard reader.canAdd(samples) else{throw OverviewRefusal("filmOutputUnreadable")};reader.add(samples)
        guard reader.startReading() else{throw OverviewRefusal("filmOutputUnreadable")}
        var n=0
        while let sample=samples.copyNextSampleBuffer() {
            let time=CMSampleBufferGetPresentationTimeStamp(sample)
            // AVFoundation emits a zero-sample edit marker at time zero. It has
            // no coded picture. Count only actual video access units.
            let count=CMSampleBufferGetNumSamples(sample)
            if count==0 && CMSampleBufferGetTotalSampleSize(sample)==0 {continue}
            guard count==1 else{throw OverviewRefusal("filmUnexpectedOutputSampleGroup")}
            guard n<frames.count-1,abs(time.seconds-times[n].seconds)<=1.0/60_000 else{throw OverviewRefusal("filmOutputPresentationMismatch")}
            n+=1
        }
        let duration=try await asset.load(.duration).seconds
        guard reader.status == .completed,n==frames.count-1,abs(duration-times.last!.seconds)<=0.002 else{throw OverviewRefusal("filmOutputDurationOrSampleCountChanged")}
        return ["videoTracks":1,"audioTracks":0,"encodedFrames":n,"duration":duration,"timescale":60_000]
    }

    #if CARD_FILM_TEST
    static func testEncoding(_ url:URL) async throws {
        let ticks:[UInt64]=[1,100_001,130_001,291_001,411_001]
        let frames=ticks.map{t in FilmFrame(stamp:FilmStamp(ticks:t,uptime:Double(t)/1e6,callback:Double(t)/1e6,
                       pts:CMTime(value:Int64(t),timescale:1_000_000)),epochs:[0,0],bytes:Data(repeating:255,count:64*64*4))}
        let row=try await encode(frames,width:64,height:64,ratio:0.000_001,output:url)
        guard row["encodedFrames"] as? Int==4,row["audioTracks"] as? Int==0 else{throw OverviewRefusal("offlineFilmReadbackFailed")}
    }
    #endif
}
