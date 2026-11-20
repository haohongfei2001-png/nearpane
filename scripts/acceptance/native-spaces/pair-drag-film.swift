// Silent recording of only the two synthetic documents during the existing right-hand drag.
import AppKit
import CryptoKit
import ScreenCaptureKit
import Security

private typealias FilmJSON = [String:Any]
private func output(_ record: FilmJSON) throws {
    var data = try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf:data)
}
private func fail(_ reason:String)->OverviewRefusal { OverviewRefusal(reason) }
private func canonical(_ path:String)->String? {
    guard let p=realpath(path,nil) else{return nil}
    defer{free(p)};return String(cString:p)
}
private func privateObject(_ path:String,directory:Bool)->Bool {
    var s=stat()
    return lstat(path,&s)==0 && s.st_uid==getuid() && s.st_mode & 0o177777 == (directory ? 0o40700:0o100600)
}
private func read<T:Decodable>(_ type:T.Type,_ url:URL)throws->T {
    guard privateObject(url.path,directory:false),
          let data=try? Data(contentsOf:url),data.count<100_000 else{throw fail("privateControlUnavailable")}
    return try JSONDecoder().decode(type,from:data)
}
private struct Geometry:Decodable {
    let clock:Double,displayUUID:String,members:[UInt32],cg:[[Double]],ax:[[Double]]
}
private struct Start:Decodable {
    let attempt:String,session:String,folder:String,app:String,display:String,space:UInt64,spaceUUID:String
    let pid:pid_t,birth:UInt64,hash:String,hostPID:pid_t,hostBirth:UInt64,hostHash:String
    let hid:[UInt32],numbers:[UInt32],hashes:[String],geometry:Geometry,expected:[[Double]]
}
private struct Event:Decodable {let type:Int,beforePost:Double,afterPost:Double}
private struct End:Decodable {let attempt:String,events:[Event],after:[Geometry]}
private func rect(_ values:[Double])->CGRect? {
    guard values.count==4,values.allSatisfy(\.isFinite),values[2]>0,values[3]>0 else{return nil}
    return CGRect(x:values[0],y:values[1],width:values[2],height:values[3])
}
private func near(_ a:CGRect,_ b:CGRect)->Bool {
    abs(a.minX-b.minX)<=1 && abs(a.minY-b.minY)<=1 && abs(a.width-b.width)<=1 && abs(a.height-b.height)<=1
}
private func signed(_ pid:pid_t,_ hash:String,_ identifier:String)->Bool {
    guard hash.count==40,hash.allSatisfy(\.isHexDigit) else{return false}
    let requirement="identifier \""+identifier+"\" and cdhash H\""+hash+"\" and anchor apple generic and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
    var code:SecCode?,test:SecRequirement?
    return SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess &&
        SecRequirementCreateWithString(requirement as CFString,[],&test)==errSecSuccess && code != nil && test != nil &&
        SecCodeCheckValidity(code!,[],test)==errSecSuccess
}
private func sameProcess(_ pid:pid_t,_ birth:UInt64,_ path:String)->Bool {
    var b=proc_bsdinfo(),bytes=[CChar](repeating:0,count:4096)
    let n=Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,n)==n && b.pbi_uid==getuid() &&
        b.pbi_start_tvsec*1_000_000+b.pbi_start_tvusec==birth && proc_pidpath(pid,&bytes,UInt32(bytes.count))>0 &&
        canonical(String(cString:bytes))==path
}

private struct Scope {
    let start:Start,displayID:CGDirectDisplayID,display:CGRect,hostExecutable:String,fixtureExecutable:String,guardian:pid_t
    init(_ s:Start, _ folder:URL)throws {
        let session=folder.deletingLastPathComponent(),kit=session.deletingLastPathComponent()
        let installed=URL(fileURLWithPath:"/Applications/Nearpane.app")
        guard canonical(folder.path)==folder.path,folder.lastPathComponent=="right-drag-film-"+s.attempt,
              UUID(uuidString:s.attempt) != nil,session.lastPathComponent==s.session,UUID(uuidString:s.session) != nil,
              canonical(kit.deletingLastPathComponent().path)=="/private/tmp",kit.lastPathComponent.hasPrefix("nearpane-d01."),
              [folder,session,kit].allSatisfy({privateObject($0.path,directory:true)}),
              canonical(s.folder)==session.path,canonical(s.app)==kit.appendingPathComponent("Field Notes.app").path,
              let hostURL=Bundle(url:installed)?.executableURL,let host=canonical(hostURL.path),
              host.hasPrefix("/Applications/Nearpane.app/Contents/MacOS/"),
              let fixture=canonical(s.app+"/Contents/MacOS/FieldNotes"),s.hid.count==13,
              s.numbers.count==2,Set(s.numbers).count==2,!s.numbers.contains(0),s.geometry.members==s.numbers,
              s.hashes.count==2,s.hashes.allSatisfy({$0.count==64 && $0.allSatisfy(\.isHexDigit)}),
              s.geometry.cg.count==2,s.geometry.ax.count==2,s.expected.count==2,
              NPReadOnlySpacesOpen()==1 else{throw fail("privatePairOrReadOnlyWindowInventoryUnavailable")}
        guard CGPreflightScreenCaptureAccess() else{throw fail("screenCapturePreflightDeniedForSignedFilmCollector")}
        start=s;displayID=CGMainDisplayID();display=CGDisplayBounds(displayID)
        hostExecutable=host;fixtureExecutable=fixture;guardian=getppid()
        try validateSignatures()
    }
    func validateFiles()throws {
        for (slot,name) in ["A","B"].enumerated() {
            let path=start.folder+"/"+name+".txt",fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else{throw fail("registeredDocumentUnavailable")}
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            var st=stat()
            guard fstat(fd,&st)==0,st.st_uid==getuid(),st.st_mode & 0o177777==0o100600,st.st_nlink==1,st.st_size<=4096,
                  let bytes=try file.read(upToCount:4097),let text=String(data:bytes,encoding:.utf8) else{throw fail("privateDocumentIdentityChanged")}
            let seed="Field Notes "+name+" "+start.session+"\n",suffix=text.dropFirst(seed.count)
            guard text.hasPrefix(seed),suffix.utf8.count%12==0,suffix.utf8.allSatisfy({(48...57).contains($0)}),
                  SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==start.hashes[slot] else{throw fail("registeredSyntheticTextChanged")}
        }
    }
    func validateSignatures()throws {
        try validateFiles()
        guard signed(start.pid,start.hash,"net.example.spaces-document"),signed(start.hostPID,start.hostHash,"com.holdsnow.nearpane.alpha")
        else{throw fail("signedPIDsChanged")}
    }
    func frames()throws->[CGRect] {
        let s=start
        var displays:UInt32=0
        guard getppid()==guardian, p2Physical()==s.hid,sameProcess(s.pid,s.birth,fixtureExecutable),
              sameProcess(s.hostPID,s.hostBirth,hostExecutable),CGMainDisplayID()==displayID,
              CGGetActiveDisplayList(0,nil,&displays) == .success,displays==1,CGDisplayBounds(displayID)==display,
              let uuid=CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil,uuid) as String).lowercased()==s.geometry.displayUUID.lowercased(),
              let inv=NPReadInventory() as? [FilmJSON],inv.count==1,let one=inv.first,one["Display Identifier"] as? String==s.display,
              (one["Current Space"] as? FilmJSON)?["id64"] as? UInt64==s.space,
              (one["Spaces"] as? [FilmJSON])?.contains(where:{$0["id64"] as? UInt64==s.space && $0["type"] as? Int==0 &&
                  ($0["uuid"] as? String)?.lowercased()==s.spaceUUID.lowercased()})==true,
              let members=NPReadCatalogSpaceWindowNumbers(s.space) as? [UInt32],Set(s.numbers).isSubset(of:Set(members)),
              s.numbers.allSatisfy({NPReadWindowSpaces($0) as? [UInt64]==[s.space]})
        else{throw fail("enrolledSpaceInputDisplayOrProcessChanged")}
        guard let ids=CFArrayCreateMutable(nil,2,nil) else{throw fail("enrolledWindowMetadataUnavailable")}
        for n in s.numbers {CFArrayAppendValue(ids,UnsafeRawPointer(bitPattern:UInt(n)))}
        guard let rows=CGWindowListCreateDescriptionFromArray(ids) as? [FilmJSON],rows.count==2 else{throw fail("twoWindowsUnavailable")}
        return try s.numbers.map { n in
            let matches=rows.filter{$0[kCGWindowNumber as String] as? UInt32==n}
            guard matches.count==1,let r=matches.first,r[kCGWindowOwnerPID as String] as? pid_t==s.pid,
                  r[kCGWindowIsOnscreen as String] as? Bool==true,r[kCGWindowLayer as String] as? Int==0,
                  r[kCGWindowAlpha as String] as? Double==1,let bounds=r[kCGWindowBounds as String] as? NSDictionary,
                  let f=CGRect(dictionaryRepresentation:bounds),display.contains(f),f.width>40,f.height>40 else{throw fail("enrolledWindowBoundsOrOpacityChanged")}
            return f
        }
    }
}

struct DragFilmRaster {
    let bytes:Data,boxes:[CGRect],counts:[Int]
    // Only premultiplied pixels from the exact two-window inclusion filter enter here. Flatten its
    // transparent background onto one fixed gray. The recorded file always has opaque pixels.
    static func copy(_ image:CVPixelBuffer,width:Int,height:Int,display:CGRect,windows:[CGRect])throws->Self {
        guard CVPixelBufferGetWidth(image)==width,CVPixelBufferGetHeight(image)==height,
              CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw fail("invalidTwoWindowBuffer")}
        defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to:UInt8.self) else{throw fail("missingTwoWindowPixels")}
        var data=Data(count:width*height*4),boxes=[CGRect](repeating:.null,count:2),counts=[0,0]
        guard windows.count==2,display.width>0,display.height>0 else{throw fail("unboundMatteGeometry")}
        let allowed=windows.map { f in CGRect(x:(f.minX-display.minX)*Double(width)/display.width,
            y:(f.minY-display.minY)*Double(height)/display.height,width:f.width*Double(width)/display.width,height:f.height*Double(height)/display.height) }
        let stride=CVPixelBufferGetBytesPerRow(image)
        data.withUnsafeMutableBytes { (out:UnsafeMutableRawBufferPointer) in
            let dst=out.bindMemory(to:UInt8.self)
            for y in 0..<height {
                let row=base+y*stride
                for x in 0..<width {
                    let i=(y*width+x)*4,point=CGPoint(x:Double(x)+0.5,y:Double(y)+0.5)
                    guard allowed[0].contains(point) || allowed[1].contains(point) else {
                        dst[i]=47;dst[i+1]=47;dst[i+2]=47;dst[i+3]=255;continue
                    }
                    let p=row+x*4,alpha=Int(p[3])
                    if x%3==0,y%3==0,let slot=PairPointerPalette.slot(red:p[2],green:p[1],blue:p[0],alpha:p[3]) {
                        counts[slot]+=1;boxes[slot]=boxes[slot].union(CGRect(x:x,y:y,width:1,height:1))
                    }
                    for k in 0..<3 {dst[i+k]=UInt8(min(255,min(alpha,Int(p[k]))+(255-alpha)*47/255))}
                    dst[i+3]=255
                }
            }
        }
        return Self(bytes:data,boxes:boxes,counts:counts)
    }
    func agrees(with frames:[CGRect],display:CGRect,width:Int,height:Int)->Bool {
        guard frames.count==2 else{return false}
        return frames.indices.allSatisfy { i in
            let f=frames[i],sx=Double(width)/display.width,sy=Double(height)/display.height
            let scaled=CGRect(x:(f.minX-display.minX)*sx,y:(f.minY-display.minY)*sy,width:f.width*sx,height:f.height*sy)
            return counts[i]>=8 && !boxes[i].isNull && scaled.insetBy(dx:-1.5,dy:-1.5).contains(boxes[i])
        }
    }
}

private struct Captured {
    let picture:FilmFrame,raster:DragFilmRaster,kind:String
    var row:FilmJSON {["displayTime":picture.stamp.uptime,"machTicks":picture.stamp.ticks,"callback":picture.stamp.callback,
                       "origin":kind,"markerCounts":raster.counts,"markerBoxPixels":raster.boxes.map{$0.isNull ? [] : [$0.minX,$0.minY,$0.width,$0.height]}]}
}
private final class Recorder:NSObject,SCStreamDelegate,SCStreamOutput,@unchecked Sendable {
    let queue=DispatchQueue(label:"nearpane.acceptance.right-drag-film")
    let scope:Scope,width:Int,height:Int,clock:PreviewClock
    private var records=[Captured](),reason:String?,idle=0,active=true
    private var unchanged:(stamp:FilmStamp,previousPicture:UInt64)?
    init(_ scope:Scope)throws {
        self.scope=scope;clock=try PreviewClock.read();width=512;height=max(2,2*Int((512*scope.display.height/scope.display.width/2).rounded()))
        guard height<=640 else{throw fail("unsupportedDisplayAspect")}
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {queue.async{if self.active {self.reason="twoWindowStreamStopped"}}}
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard active,reason==nil,type == .screen else{return}
        do {
            if let f=try frame(buffer,kind:"SCStream") {
                if let last=records.last,last.picture.stamp.ticks>=f.picture.stamp.ticks{throw fail("nonMonotonicStreamPresentation")}
                guard records.count<100 else{throw fail("boundedFilmFrameBudget")}
                records.append(f);unchanged=nil
            }
        } catch {reason=(error as? OverviewRefusal)?.reason ?? "unqualifiedSystemFrame"}
    }
    func frame(_ buffer:CMSampleBuffer,kind:String)throws->Captured? {
        let callback=captureUptime()
        guard let meta=(CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
              let status=(meta[.status] as? NSNumber)?.intValue else{throw fail("missingPresentationStatus")}
        if status==SCFrameStatus.idle.rawValue {
            if kind=="SCStream" {
                idle+=1
                if let previous=records.last, let ticks=(meta[.displayTime] as? NSNumber)?.uint64Value, ticks>previous.picture.stamp.ticks {
                    let when=clock.mapped(ticks),pts=buffer.presentationTimeStamp
                    if when+clock.uncertainty<=callback,callback-when<=0.15 {
                        _=try scope.frames()
                        unchanged=(FilmStamp(ticks:ticks,uptime:when,callback:callback,pts:pts),previous.picture.stamp.ticks)
                    }
                }
            }
            return nil
        }
        if status==SCFrameStatus.started.rawValue && buffer.imageBuffer==nil{return nil}
        guard [SCFrameStatus.complete.rawValue,SCFrameStatus.started.rawValue].contains(status),buffer.isValid,let image=buffer.imageBuffer,
              let ticks=(meta[.displayTime] as? NSNumber)?.uint64Value,ticks>0 else{throw fail("missingRealPresentationTimeOrPixels")}
        let t=clock.mapped(ticks),pts=buffer.presentationTimeStamp
        guard pts.isNumeric,PreviewClock.presentationBounds(display:t,pts:pts.seconds+clock.hostOffset,callback:callback) != nil,
              callback-t<=0.25 else{throw fail("unboundTwoWindowPresentationClock")}
        // SCK can deliver a buffer just ahead of displayTime. The scoped, read-only guards
        // must be performed after that presentation before its bytes are retained.
        if t+clock.uncertainty>captureUptime(){Thread.sleep(forTimeInterval:max(0,t+clock.uncertainty-captureUptime()+0.0001))}
        let windows=try scope.frames()
        let raster=try DragFilmRaster.copy(image,width:width,height:height,display:scope.display,windows:windows)
        _=try scope.frames()
        let stamp=FilmStamp(ticks:ticks,uptime:t,callback:callback,pts:pts)
        return Captured(picture:FilmFrame(stamp:stamp,epochs:[],bytes:raster.bytes),raster:raster,kind:kind)
    }
    func snapshot()throws->[Captured] {try queue.sync {if let reason{throw fail(reason)};return records}}
    func idleEnd()->(stamp:FilmStamp,previousPicture:UInt64)? {queue.sync{unchanged}}
    func freeze(){queue.sync{active=false}}
    func endFrame(_ buffer:CMSampleBuffer)throws->Captured? {try queue.sync{try frame(buffer,kind:"SCScreenshotManager")}}
}

#if !PAIR_DRAG_FILM_SELFTEST
@main
private struct PairDragFilmMain {
    static func main() async {
        do {try await run()}
        catch {try? output(["status":"UNKNOWN","reason":(error as? OverviewRefusal)?.reason ?? "unverifiedTwoWindowFilm"]);exit(2)}
    }
    static func run() async throws {
        _=umask(0o077)
        guard CommandLine.arguments.count==2 else{throw fail("missingPrivateAttemptDirectory")}
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]),s=try read(Start.self,dir.appendingPathComponent("start.json")),scope=try Scope(s,dir)
        let startFrames=s.geometry.cg.compactMap(rect),startAX=s.geometry.ax.compactMap(rect),current=try scope.frames()
        guard startFrames.count==2,startAX.count==2,zip(startFrames,startAX).allSatisfy(near),zip(current,startFrames).allSatisfy(near) else{throw fail("originalPairGeometryChanged")}
        let available=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let windows=available.windows.filter{s.numbers.contains($0.windowID) && $0.owningApplication?.processID==s.pid && $0.isOnScreen}
        guard available.displays.count==1,let d=available.displays.first,d.displayID==scope.displayID,d.frame==scope.display,
              windows.count==2,Set(windows.map(\.windowID))==Set(s.numbers) else{throw fail("twoShareableDocumentsUnavailable")}
        let filter=SCContentFilter(display:d,including:windows);filter.includeMenuBar=false
        guard Set(filter.includedWindows.map(\.windowID))==Set(s.numbers),Set(filter.includedApplications.map(\.processID)).isSubset(of:[s.pid]) else{throw fail("windowInclusionFilterUnbound")}
        let receiver=try Recorder(scope),config=SCStreamConfiguration()
        config.width=receiver.width;config.height=receiver.height;config.sourceRect=CGRect(origin:.zero,size:d.frame.size)
        config.showsCursor=false;config.showMouseClicks=false;config.capturesAudio=false;config.captureMicrophone=false
        config.includeChildWindows=false;config.ignoreShadowsDisplay=true;config.shouldBeOpaque=false
        config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=CGColorSpace.sRGB
        config.minimumFrameInterval=CMTime(value:1,timescale:15);config.queueDepth=3
        let stream=SCStream(filter:filter,configuration:config,delegate:receiver)
        try stream.addStreamOutput(receiver,type:.screen,sampleHandlerQueue:receiver.queue)
        try await stream.startCapture()
        var stopped=false
        defer{if !stopped{receiver.freeze();stream.stopCapture{_ in}}}
        let readyDeadline=captureUptime()+1.5
        var first:Captured?
        while first==nil,captureUptime()<readyDeadline {
            first=try receiver.snapshot().last(where:{$0.picture.stamp.uptime>=s.geometry.clock && $0.raster.agrees(with:startFrames,display:scope.display,width:receiver.width,height:receiver.height)})
            if first==nil{try await Task.sleep(for:.milliseconds(15))}
        }
        guard let first else{throw fail("originalBothColorMarkersNotObserved")}
        try output(["status":"READY","attempt":s.attempt,"sourceDisplayUptime":first.picture.stamp.uptime])
        let endFile=dir.appendingPathComponent("end.json"),deadline=captureUptime()+7
        while !FileManager.default.fileExists(atPath:endFile.path),captureUptime()<deadline {
            _=try scope.frames();_=try receiver.snapshot();try await Task.sleep(for:.milliseconds(35))
        }
        guard FileManager.default.fileExists(atPath:endFile.path) else{throw fail("secondIndependentNativeReadUnavailable")}
        let end=try read(End.self,endFile),target=s.expected.compactMap(rect)
        guard end.attempt==s.attempt,end.after.count==2,target.count==2,!zip(target,startFrames).allSatisfy(near),
              let down=end.events.first,let up=end.events.last,end.events.count>=5,down.type==1,up.type==2,
              end.events.dropFirst().dropLast().allSatisfy({$0.type==6}),end.events.allSatisfy({$0.beforePost<=$0.afterPost}),
              zip(end.events,end.events.dropFirst()).allSatisfy({$0.afterPost<=$1.beforePost}),down.beforePost>first.picture.stamp.uptime,
              up.afterPost<=end.after[0].clock,end.after[0].clock<end.after[1].clock,
              end.after.allSatisfy({ g in g.displayUUID==s.geometry.displayUUID && g.members==s.numbers && g.cg.compactMap(rect).count==2 &&
                    g.ax.compactMap(rect).count==2 && zip(g.cg.compactMap(rect),target).allSatisfy(near) && zip(g.ax.compactMap(rect),target).allSatisfy(near) })
        else{throw fail("gestureOrTwoIndependentTargetReadbacksUnbound")}
        // Current pictures may be static after AppKit's layout. Take two fresh, exact-filter
        // endpoint samples with native displayTime. A timestamp without pixels never extends the movie.
        var tail=[Captured](),endpointReadIssues=[String](),confirmedTerminalImages=0
        for _ in 0..<2 {
            guard zip(try scope.frames(),target).allSatisfy(near) else{throw fail("targetPairChangedAtEndpoint")}
            do {
                let buffer=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:config)
                guard buffer.isValid,let image=buffer.imageBuffer else{throw fail("terminalFilterImageUnavailable")}
                let atEndpoint=try scope.frames()
                guard zip(atEndpoint,target).allSatisfy(near),
                      try DragFilmRaster.copy(image,width:receiver.width,height:receiver.height,display:scope.display,windows:atEndpoint)
                        .agrees(with:target,display:scope.display,width:receiver.width,height:receiver.height),
                      zip(try scope.frames(),target).allSatisfy(near) else{throw fail("terminalFixtureMarkersChanged")}
                confirmedTerminalImages+=1
                if let frame=try receiver.endFrame(buffer),frame.picture.stamp.uptime>=end.after[1].clock,
                   frame.raster.agrees(with:target,display:scope.display,width:receiver.width,height:receiver.height){tail.append(frame)}
            } catch let e as OverviewRefusal {
                guard ["missingPresentationStatus","missingRealPresentationTimeOrPixels","unboundTwoWindowPresentationClock"].contains(e.reason) else{throw e}
                endpointReadIssues.append(e.reason)
            }
            try await Task.sleep(for:.milliseconds(80))
        }
        receiver.freeze();try await stream.stopCapture();stopped=true
        try scope.validateSignatures()
        let lastScope=try scope.frames()
        guard zip(lastScope,target).allSatisfy(near) else{throw fail("targetLayoutNoLongerBound")}
        var byTick=[UInt64:Captured]()
        for f in try receiver.snapshot()+tail where f.picture.stamp.ticks>=first.picture.stamp.ticks {
            if byTick[f.picture.stamp.ticks]==nil {byTick[f.picture.stamp.ticks]=f}
        }
        let frames=byTick.sorted{$0.key<$1.key}.map(\.value)
        let ending=frames.filter{$0.picture.stamp.uptime>=end.after[1].clock &&
            $0.raster.agrees(with:target,display:scope.display,width:receiver.width,height:receiver.height)}
        var chosen:[Captured], pictures:[FilmFrame], boundary:FilmJSON
        if ending.count>=2,let final=ending.last,let endIndex=frames.firstIndex(where:{$0.picture.stamp.ticks==final.picture.stamp.ticks}) {
            chosen=Array(frames[...endIndex]);pictures=chosen.map(\.picture)
            boundary=["kind":"realCompletePresentation","uptime":final.picture.stamp.uptime,"ticks":final.picture.stamp.ticks]
        } else if let idle=receiver.idleEnd(),idle.stamp.uptime>=end.after[1].clock,confirmedTerminalImages>=1,
                  let anchor=frames.last(where:{$0.kind=="SCStream"}),anchor.picture.stamp.ticks==idle.previousPicture,
                  anchor.picture.stamp.uptime>=up.afterPost,anchor.raster.agrees(with:target,display:scope.display,width:receiver.width,height:receiver.height) {
            // Apple's idle status means no display change since the preceding real complete
            // picture. Only its native displayTime closes that picture's duration. No new
            // picture is constructed or encoded for idle or for an unstamped screenshot.
            chosen=frames.filter{$0.picture.stamp.ticks<=anchor.picture.stamp.ticks}
            pictures=chosen.map(\.picture)+[FilmFrame(stamp:idle.stamp,epochs:[],bytes:Data())]
            boundary=["kind":"SCFrameStatusIdle","uptime":idle.stamp.uptime,"ticks":idle.stamp.ticks,"heldCompleteTicks":idle.previousPicture]
        } else {throw fail("noNativeEndpointAfterBothReadbacks")}
        guard pictures.count>=3,let last=pictures.last,last.stamp.uptime-down.beforePost<7 else{throw fail("filmIntervalUnbound")}
        let tmp=dir.appendingPathComponent("encoding.mp4"),dest=dir.appendingPathComponent("verified.mp4")
        defer{try? FileManager.default.removeItem(at:tmp)}
        let clock=receiver.clock,ratio=Double(clock.numerator)/Double(clock.denominator)/1e9
        let encoding=try await PairedCardFilm.encode(pictures,width:receiver.width,height:receiver.height,ratio:ratio,output:tmp)
        let bytes=try Data(contentsOf:tmp)
        guard bytes.count<=10_000_000 else{throw fail("boundedMovieSizeExceeded")}
        try FileManager.default.moveItem(at:tmp,to:dest)
        let encoded=encoding["encodedFrames"] as? Int ?? 0
        let frameRows=chosen.enumerated().map { i,f in
            var row=f.row
            row["encoded"]=i<encoded
            row["sha256OfMattedBGRA"]=SHA256.hash(data:f.raster.bytes).map{String(format:"%02x",$0)}.joined()
            return row
        }
        try output(["status":"CAPTURED","attempt":s.attempt,"source":"SCContentFilter(display:including:twoRegisteredWindows)",
                    "fixturePID":s.pid,"fixtureBirth":s.birth,"fixtureHash":s.hash,"fixtureWindows":s.numbers,
                    "sourceFrames":s.geometry.cg,"targetFrames":s.expected,"displayUUID":s.geometry.displayUUID,"spaceUUID":s.spaceUUID,
                    "mouseDownUptime":down.beforePost,"mouseUpUptime":up.afterPost,"twoAXAndCGReadbacks":end.after.map(\.clock),
                    "nativeEnd":boundary,"confirmedTerminalImages":confirmedTerminalImages,"endpointReadIssues":endpointReadIssues,"encoding":encoding,"frames":frameRows,"width":receiver.width,"height":receiver.height,
                    "noCursorOrSidebar":true,"matteSRGB":[47,47,47],"codec":"H.264 (lossy)","noAudio":true,
                    "sha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()])
    }
}
#endif
