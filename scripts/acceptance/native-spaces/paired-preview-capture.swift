import AppKit
import CoreMedia
import CryptoKit
import ScreenCaptureKit

private struct Request: Decodable, Equatable {
    let display: String, space: UInt64, hostPID: pid_t, hostBirth: UInt64, panel: UInt32
    let fixturePID: pid_t, fixtureBirth: UInt64, numbers: [UInt32], sources: [[Double]], pictures: [[Double]]
    let hostHash: String, fixtureHash: String
}
private struct Refusal: Error { let reason:String; init(_ reason:String) {self.reason=reason} }
private struct Crop { let number: UInt32, pid: pid_t, rect: CGRect, patches:[CGRect], filter: SCContentFilter, config: SCStreamConfiguration }
private struct Observation: Encodable {
    let start:Double,end:Double,color:String,displayTime:Double?,frameStatus:Int?
    var patch:Data? = nil
    private enum CodingKeys:String,CodingKey {case start,end,color,displayTime,frameStatus}
}
private struct FilterGeometry:Encodable {
    let window:UInt32,frame:[Double],filterRect:[Double],requested:[Double],includedWindowCount:Int,nativePointPixelScale:Float
}
private func numbers(_ r:CGRect)->[Double] {[r.minX,r.minY,r.width,r.height]}
private struct PendingWitness {let batch:Int,epoch:Int,uptime:Double,data:Data}
private struct Witness:Encodable {
    let file:String,sha256:String,epoch:Int,batch:Int,hostPID:pid_t,fixturePID:pid_t,numbers:[UInt32],panel:UInt32
    let uptime:Double,bindingBefore:Double,bindingAfter:Double,cardKinds:[String],physicalFourPatch:Bool
}
private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func emit<T:Encodable>(_ value:T) throws { FileHandle.standardOutput.write(try JSONEncoder().encode(value)+Data([10])) }
private func birth(_ pid:pid_t) -> UInt64? {
    var info=proc_bsdinfo();let size=Int32(MemoryLayout.size(ofValue:info))
    guard pid>1,proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size,info.pbi_pid==UInt32(pid),info.pbi_uid==getuid(),info.pbi_start_tvsec>0 else{return nil}
    return info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec
}
private func hardware() -> [UInt32] { [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map{CGEventSource.counterForEventType(.hidSystemState,eventType:$0)} }
private func scope(_ r:Request,_ crops:[Crop],_ input:[UInt32]) -> String? {
    guard hardware()==input,NSEvent.pressedMouseButtons==0,birth(r.hostPID)==r.hostBirth,birth(r.fixturePID)==r.fixtureBirth,
          let scopes=NPReadInventory() as? [[String:Any]],scopes.count==1,scopes[0]["Display Identifier"] as? String==r.display,
          (scopes[0]["Current Space"] as? [String:Any])?["id64"] as? UInt64==r.space,
          let forward=NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32],
          r.numbers.allSatisfy({forward.contains($0) && NPReadWindowSpaces($0) as? [UInt64]==[r.space]}),
          let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else{return "scopeInputOrSignedGenerationOrSpaceChanged"}
    for (index,crop) in crops.enumerated() {
        let kind=index==2 ? "Panel" : "Source"+String(index+1)
        var found=false
        for row in rows {
            guard let box=row[kCGWindowBounds as String] as? NSDictionary,let bounds=CGRect(dictionaryRepresentation:box) else{return "unreadableWindowBoundsBefore"+kind}
            if row[kCGWindowNumber as String] as? UInt32==crop.number {
                found=row[kCGWindowOwnerPID as String] as? Int32==crop.pid && bounds.contains(crop.rect)
                break
            }
            if crop.patches.contains(where:{bounds.intersects($0)}), (row[kCGWindowAlpha as String] as? Double ?? 1)>0 {
                let pid=row[kCGWindowOwnerPID as String] as? pid_t
                let who=pid==r.fixturePID ? "Fixture" : pid==r.hostPID ? "Host":"Other"
                return kind+"OccludedBy"+who
            }
        }
        if !found{return "boundWindowUnavailableAt"+kind}
    }
    return nil
}
private func observe(_ crop:Crop,witness requestedWitness:Bool) async -> [Observation] {
    let witness=requestedWitness && crop.filter.pointPixelScale==2
    let t=now();var displayed:Double?, status:Int?
    func sample(_ color:String)->Observation{Observation(start:t,end:now(),color:color,displayTime:displayed,frameStatus:status)}
    func uniform(_ color:String)->[Observation]{let value=sample(color);return crop.patches.map{_ in value}}
    do {
        let raw=try await SCScreenshotManager.captureSampleBuffer(contentFilter:crop.filter,configuration:crop.config)
        let attachment=(CMSampleBufferGetSampleAttachmentsArray(raw,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
        status=(attachment?[.status] as? NSNumber)?.intValue
        if let ticks=(attachment?[.displayTime] as? NSNumber)?.uint64Value,ticks>0 {var scale=mach_timebase_info_data_t();mach_timebase_info(&scale);displayed=Double(ticks)*Double(scale.numer)/Double(scale.denom)/1e9}
        // A capture service blank has no usable panel pixels. Only a sampled neutral
        // or transparent patch from an actual image may establish a blank marker.
        if status==SCFrameStatus.blank.rawValue{return uniform("unknown")}
        guard status==nil || status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue,
              CMSampleBufferIsValid(raw),CMSampleBufferDataIsReady(raw),let pixels=CMSampleBufferGetImageBuffer(raw),
              CVPixelBufferGetWidth(pixels)==crop.config.width,CVPixelBufferGetHeight(pixels)==crop.config.height,CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels,.readOnly)==kCVReturnSuccess else{return uniform("unknown")}
        defer{CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        guard let bytes=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else{return uniform("unknown")}
        let finished=now()
        return crop.patches.map { patch in
            let x0=Int((patch.minX-crop.rect.minX)*2),y0=Int((patch.minY-crop.rect.minY)*2)
            var counts=[String:Int](),rgba=Data(),solidOpaque=true,first:UInt32?
            for y in y0..<(y0+8) {for x in x0..<(x0+8) {let k=y*CVPixelBufferGetBytesPerRow(pixels)+4*x
                let red=bytes[k+2],green=bytes[k+1],blue=bytes[k],alpha=bytes[k+3]
                counts[PairedPreviewPalette.classify(Int(red),Int(green),Int(blue),Int(alpha)),default:0]+=1
                if witness {
                    let pixel=UInt32(red)<<24 | UInt32(green)<<16 | UInt32(blue)<<8 | UInt32(alpha)
                    if alpha != 255 || (first != nil && pixel != first) {solidOpaque=false}
                    if first==nil {first=pixel}
                    rgba.append(contentsOf:[red,green,blue,alpha])
                }
            }}
            let dominant=counts.first(where:{$0.value>=52})?.key ?? "unknown"
            return Observation(start:t,end:finished,color:dominant,displayTime:displayed,frameStatus:status,
                               patch:witness && solidOpaque && counts[dominant]==64 && dominant.contains("/") ? rgba:nil)
        }
    } catch {return uniform("unknown")}
}
@main struct PairedCapture {
    static func main() async {
        do{try await capture()}catch{try? emit(["refusal":(error as? Refusal)?.reason ?? "captureUnavailable"]);exit(2)}
    }
    static func capture() async throws {
        let data=FileHandle.standardInput.readDataToEndOfFile();let r=try JSONDecoder().decode(Request.self,from:data)
        let sourceOnly=CommandLine.arguments.count==3 && CommandLine.arguments[2]=="--sources"
        guard CommandLine.arguments.count==2 || sourceOnly,CGPreflightScreenCaptureAccess(),NPReadOnlySpacesOpen()==1,
              Set(r.numbers).count==2,r.numbers.count==2,(r.pictures.count==2 || sourceOnly),r.sources.count==2 else{throw Refusal("invalidCaptureAdmission")}
        guard let folder=PreviewCensus.ownedTemporaryURL(CommandLine.arguments[1]) else{throw Refusal("unownedTriggerDirectory")}
        let temp=folder.deletingLastPathComponent();var info=stat()
        guard UUID(uuidString:folder.lastPathComponent) != nil,temp.lastPathComponent.hasPrefix("nearpane-preview-pair."),
              temp.deletingLastPathComponent().path=="/private/tmp",PreviewCensus.ownedTemporaryURL(temp.path) != nil,
              lstat(folder.path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o077==0 else{throw Refusal("unownedTriggerDirectory")}
        guard let kit=PreviewCensus.kit(CommandLine.arguments[0]) else{throw Refusal("unqualifiedBuildDirectory")}
        func confirmCards() throws -> [String] {
            let child=Process(),pipe=Pipe()
            child.executableURL=kit.appendingPathComponent("paired-scope")
            child.arguments=[String(r.hostPID),r.hostHash,String(r.fixturePID),String(r.fixtureBirth),r.fixtureHash,
                             kit.appendingPathComponent("Field Notes.app/Contents/MacOS/FieldNotes").path,
                             String(r.numbers[0]),String(r.numbers[1]),String(r.space)]
            child.standardOutput=pipe;try child.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();child.waitUntilExit()
            guard child.terminationStatus==0,let proof=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Refusal("missingSignedScopeReadback")}
            if sourceOnly {
                guard proof["sourceProven"] as? Bool==true,proof["space"] as? UInt64==r.space,proof["display"] as? String==r.display,
                      proof["fixtureBirth"] as? UInt64==r.fixtureBirth,proof["hostBirth"] as? UInt64==r.hostBirth,
                      proof["fixturePID"] as? pid_t==r.fixturePID,proof["hostPID"] as? pid_t==r.hostPID,proof["numbers"] as? [UInt32]==r.numbers,
                      let census=proof["windowCensus"] as? [String:Any],let rows=census["expectedEvidence"] as? [[String:Any]],
                      r.numbers.enumerated().allSatisfy({i,n in
                          guard let row=rows.first(where:{$0["number"] as? UInt32==n}),row["accepted"] as? Bool==true,
                                let b=row["bounds"] as? [Double],b.count==4 else{return false}
                          return r.sources[i]==[floor(b[0]+b[2]/2)-2,floor(b[1]+b[3]/2)-2,4,4]
                      }) else{throw Refusal("independentSourceBindingChanged")}
                return []
            }
            guard (try? JSONDecoder().decode(Request.self,from:data))==r,proof["ready"] as? Bool==true,
                  proof["cardIdentityProven"] as? Bool==true,let kinds=proof["kinds"] as? [String],kinds.count==2 else{throw Refusal("independentCardBindingChanged")}
            return kinds
        }
        _ = try confirmCards()
        var lastBinding=now()
        let available=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        guard let display=available.displays.first(where:{ d in CGDisplayCreateUUIDFromDisplayID(d.displayID).map{CFUUIDCreateString(nil,$0.takeRetainedValue()) as String}==r.display }) else{throw Refusal("displayUnavailable")}
        var crops=[Crop](),filterGeometry=[FilterGeometry]()
        var groups=[(r.numbers[0],r.fixturePID,[r.sources[0]]),(r.numbers[1],r.fixturePID,[r.sources[1]])]
        if !sourceOnly {groups.append((r.panel,r.hostPID,r.pictures))}
        for (id,pid,regions) in groups {
            guard let window=available.windows.first(where:{$0.windowID==id && $0.owningApplication?.processID==pid && $0.isOnScreen}) else{throw Refusal("boundWindowUnavailable")}
            let patches=try regions.map { raw -> CGRect in
                guard raw.count==4,raw.allSatisfy(\.isFinite),raw[0].rounded()==raw[0],raw[1].rounded()==raw[1],raw[2]==4,raw[3]==4 else{throw Refusal("invalidROI")}
                return CGRect(x:raw[0],y:raw[1],width:4,height:4)
            }
            let rect=patches.dropFirst().reduce(patches[0]){$0.union($1)}
            guard rect.width<=8,rect.height<=400,window.frame.contains(rect),display.frame.contains(rect) else{throw Refusal("uncontainedROI")}
            let filter=SCContentFilter(display:display,including:[window]);filter.includeMenuBar=false
            guard filter.includedWindows.count==1,filter.includedWindows.first?.windowID==id else{throw Refusal("unboundedFilter")}
            let config=SCStreamConfiguration();config.sourceRect=rect.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
            config.width=Int(rect.width)*2;config.height=Int(rect.height)*2;config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=CGColorSpace.sRGB
            config.showsCursor=false;config.capturesAudio=false;config.captureMicrophone=false;config.includeChildWindows=false
            filterGeometry.append(FilterGeometry(window:id,frame:numbers(window.frame),filterRect:numbers(filter.contentRect),requested:numbers(config.sourceRect),
                                                 includedWindowCount:filter.includedWindows.count,nativePointPixelScale:filter.pointPixelScale))
            crops.append(Crop(number:id,pid:pid,rect:rect,patches:patches,filter:filter,config:config))
        }
        try emit(["filterGeometry":filterGeometry])
        let input=hardware(),began=now(),regions=crops
        if sourceOnly {
            if let reason=scope(r,regions,input){throw Refusal(reason)}
            async let a=observe(regions[0],witness:false);async let b=observe(regions[1],witness:false)
            let samples=await [a,b].flatMap{$0}
            if let reason=scope(r,regions,input){throw Refusal(reason)}
            _=try confirmCards();try emit(["sources":samples]);return
        }
        let witness=ProcessInfo.processInfo.environment["NEARPANE_PAIRED_EVIDENCE"]=="1"
        var triggered=false,batches=0,pending=[PendingWitness]()
        func validateAndSave() throws {
            let kinds=try confirmCards(),after=now()
            if witness && kinds.count==2 && after-lastBinding<=3.0 {
                for item in pending {
                    let name=String(format:"preview-%05d.rgba",item.batch)
                    try item.data.write(to:folder.appendingPathComponent(name),options:.withoutOverwriting)
                    let hash=SHA256.hash(data:item.data).map{String(format:"%02x",$0)}.joined()
                    let proof=Witness(file:name,sha256:hash,epoch:item.epoch,batch:item.batch,hostPID:r.hostPID,fixturePID:r.fixturePID,
                                      numbers:r.numbers,panel:r.panel,uptime:item.uptime,bindingBefore:lastBinding,bindingAfter:after,cardKinds:kinds,physicalFourPatch:true)
                    try emit(["witness":proof])
                }
            }
            pending.removeAll(keepingCapacity:true);lastBinding=after
        }
        while now()-began<16.5 && batches<180 {
            if now()-lastBinding>=1.0 {try validateAndSave()}
            if let reason=scope(r,regions,input){throw Refusal(reason)}
            async let s0=observe(regions[0],witness:witness);async let s1=observe(regions[1],witness:witness);async let panel=observe(regions[2],witness:witness)
            let batch=await [s0,s1,panel].flatMap{$0}
            if let reason=scope(r,regions,input){throw Refusal(reason)}
            try emit(["batch":batch]);batches+=1
            if witness,batch.count==4,let epoch=PairedPreviewPalette.epochs.indices.first(where:{ e in
                batch.map(\.color)==["0/\(e)","1/\(e)","0/\(e)","1/\(e)"]
            }),batch.allSatisfy({$0.patch?.count==256}) {
                pending.append(PendingWitness(batch:batches,epoch:epoch,uptime:batch[2].end,data:batch.compactMap{$0.patch}.reduce(into:Data()){$0.append($1)}))
            }
            if !triggered && now()-began>=1.5 {
                try Data().write(to:folder.appendingPathComponent("preview-start"),options:.withoutOverwriting);triggered=true
                try emit(["pulseStarted":now()])
            }
            try await Task.sleep(for:.milliseconds(65))
        }
        guard triggered else{throw Refusal("initialSamplesIncomplete")}
        try validateAndSave()
        try emit(["completedBatches":batches])
    }
}
