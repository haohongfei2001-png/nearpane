// ScreenCaptureKit display stream of the two enrolled fixture window IDs.
// The desktop, menu bar, overlays, child windows, pointer and audio are excluded.
// Real frames stay in bounded memory until the caller revalidates the fixture identities.
import AppKit
import AVFoundation
import CryptoKit
import CoreMedia
import Darwin
import ScreenCaptureKit
import Security
import VideoToolbox

private typealias JSON = [String: Any]
private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
private struct Space: Codable, Equatable { let id: UInt64, type: Int, uuid: UUID }
private struct Topology: Codable { let display: UUID, records: [Space], current: UInt64 }
private struct Window: Codable { let pid: pid_t, birth: UInt64, number: UInt32, executable: String, identifier: String }
private struct Pair: Codable { let topology: Topology, sourceWindow: Window, targetWindow: Window, target: UInt64, hostPID: pid_t, hid: [UInt32] }
private struct Binding: Codable { let nonce: UUID, guardian: pid_t, guardianBirth: UInt64, request: Pair; let endpoints: [String: Endpoint]? }
private struct Endpoint: Codable {
    let space: UInt64, display: UUID, wallpaper: String, crop: [Double], rgb: [Int]
}
private struct End: Codable { let nonce: UUID, allowMovie: Bool, pressed: Double, ended: Double }
private let uptime = { ProcessInfo.processInfo.systemUptime }

private func json(_ value: JSON, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
}

private func birth(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let n = Int32(MemoryLayout.size(ofValue: info))
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, n) == n,
          info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

private func hardware() -> [UInt32] {
    [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
     .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
}

private func exactGeneration(_ w:Window)->Bool {
    guard birth(w.pid)==w.birth else {return false}
    var path=[CChar](repeating:0,count:4096)
    return proc_pidpath(w.pid,&path,UInt32(path.count))>0 && String(cString:path)==w.executable
}
private func pairIntact(_ p:Pair)->Bool {
    hardware()==p.hid && exactGeneration(p.sourceWindow) && exactGeneration(p.targetWindow)
}

// This is an independent metadata read after a callback. ScreenCaptureKit does not provide
// an atomic physical-layer census for a displayTime. Unknown window identities never leave this process.
private func inventory(_ p: Pair, ordered:Bool = false) -> (UInt64?, [UInt32]?) {
    guard let rows = NPReadInventory() as? [JSON], rows.count == 1, let row = rows.first,
          let display = row["Display Identifier"] as? String, UUID(uuidString: display) == p.topology.display,
          let spaces = row["Spaces"] as? [JSON], spaces.count == p.topology.records.count else { return (nil, nil) }
    for (a, b) in zip(spaces, p.topology.records) {
        guard a["id64"] as? UInt64 == b.id, a["type"] as? Int == b.type,
              UUID(uuidString: a["uuid"] as? String ?? "") == b.uuid else { return (nil, nil) }
    }
    let current = (row["Current Space"] as? JSON)?["id64"] as? UInt64
    if !ordered {return(current,nil)}
    // Only the window numbers enter the receipt. Foreign titles and application names are never read.
    let ordered = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [JSON])?.compactMap {
        $0[kCGWindowNumber as String] as? UInt32
    }
    return (current, ordered)
}

private struct WallpaperProof {
    var source="unavailable",fileURL=false,rootOwned=false,regular=false,systemVolume=false,readOnly=false,recognizedImage=false
    var fingerprint:String?
    var fields:JSON {["source":source,"fileURL":fileURL,"rootOwned":rootOwned,"regularFile":regular,
                      "sameSystemVolume":systemVolume,"readOnlyVolume":readOnly,"recognizedImage":recognizedImage,
                      "qualified":fingerprint != nil]}
}

private func wallpaperProof(_ url:URL?) -> WallpaperProof {
    var proof=WallpaperProof()
    guard let url,url.isFileURL else { return proof }
    proof.fileURL=true
    // Resolve to a real, existing file, then allow only these two Apple's system-image directories.
    // No path, name, digest or metadata of an untrusted or personal asset enters the receipt.
    guard let raw=realpath(url.path,nil) else {proof.source="unresolved";return proof}
    defer {free(raw)}
    let path=String(cString:raw)
    if path.hasPrefix("/System/Library/Desktop Pictures/") {proof.source="systemDesktopPictures"}
    else if path.hasPrefix("/System/Library/Wallpapers/") {proof.source="systemWallpapers"}
    else {proof.source="outsideSealedSystemWallpaperDirectories";return proof}
    var file=stat(),system=stat(),volume=statfs()
    guard lstat(path,&file)==0,stat("/System/Library",&system)==0,statfs(path,&volume)==0 else {return proof}
    proof.rootOwned=file.st_uid==0 && file.st_mode&0o022==0
    proof.regular=file.st_mode&S_IFMT==S_IFREG && file.st_size>0
    proof.systemVolume=file.st_dev==system.st_dev
    proof.readOnly=volume.f_flags&UInt32(MNT_RDONLY) != 0
    proof.recognizedImage=["heic","jpg","jpeg","png","tif","tiff"].contains(URL(fileURLWithPath:path).pathExtension.lowercased())
    if proof.rootOwned && proof.regular && proof.systemVolume && proof.readOnly && proof.recognizedImage {
        let fingerprint="\(path)/\(file.st_dev)/\(file.st_ino)/\(file.st_size)/\(file.st_mtimespec.tv_sec)/\(file.st_mtimespec.tv_nsec)"
        proof.fingerprint=SHA256.hash(data:Data(fingerprint.utf8)).map {String(format:"%02x",$0)}.joined()
    }
    return proof
}

private func wallpaper(_ screen:NSScreen)->String? {
    wallpaperProof(NSWorkspace.shared.desktopImageURL(for:screen)).fingerprint
}

private enum TrustedOwner:String {
    case agent="com.apple.wallpaper.agent",server="com.apple.WindowServer",manager="com.apple.WindowManager",finder="com.apple.finder"
    var executable:String {
        switch self {
        case .agent:return "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
        case .server:return "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
        case .manager:return "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
        case .finder:return "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        }
    }
    private static let all:[Self]=[.agent,.server,.manager,.finder]
    private static let lock=NSLock()
    private static var previous=[pid_t:(UInt64,Self)]()
    static func identify(_ pid:pid_t) -> Self? {
        var name=[CChar](repeating:0,count:4096),info=proc_bsdinfo()
        let size=Int32(MemoryLayout.size(ofValue:info))
        guard proc_pidpath(pid,&name,UInt32(name.count))>0,let result=all.first(where:{$0.executable==String(cString:name)}),
              proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size,info.pbi_pid==UInt32(pid),info.pbi_start_tvsec>0 else {return nil}
        let generation=info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec
        if lock.withLock({previous[pid]?.0==generation && previous[pid]?.1==result}) {return result}
        var code:SecCode?,requirement:SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecRequirementCreateWithString(("anchor apple and identifier \""+result.rawValue+"\"") as CFString,[],&requirement)==errSecSuccess,let requirement,
              SecCodeCheckValidity(code,[],requirement)==errSecSuccess else {return nil}
        lock.withLock{previous[pid]=(generation,result)}
        return result
    }
}

private struct ProbeSurface {
    let value:UInt32?,category:String
}
private func probeSurface(_ crop:CGRect,_ pair:Pair)->ProbeSurface {
    guard let rows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [JSON] else {return .init(value:nil,category:"noSystemLayerList")}
    let desktop=Int(CGWindowLevelForKey(.desktopWindow))
    for row in rows {
        guard let bounds=row[kCGWindowBounds as String] as? [String:Any],let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary) else {return .init(value:nil,category:"unknownBounds")}
        guard rect.intersects(crop) else {continue}
        guard let alpha=row[kCGWindowAlpha as String] as? Double else {return .init(value:nil,category:"unknownOpacity")}
        if alpha<=0 {continue}
        guard let level=row[kCGWindowLayer as String] as? Int,let number=row[kCGWindowNumber as String] as? UInt32,
              let pid=row[kCGWindowOwnerPID as String] as? pid_t else {return .init(value:nil,category:"unknownIntersectingLayer")}
        if let own=[pair.sourceWindow,pair.targetWindow].first(where:{$0.pid==pid && $0.number==number}),birth(pid)==own.birth {
            guard alpha>=0.999,rect.insetBy(dx:12,dy:12).contains(crop) else {return .init(value:nil,category:"fixtureEdgeOrTranslucentRegion")}
            return .init(value:number,category:number==pair.sourceWindow.number ? "sourceFixture":"targetFixture")
        }
        let controller=TrustedOwner.identify(pid)
        guard alpha>=0.999,rect.contains(crop) else {return .init(value:nil,category:"partiallyCoveredByAnotherSurface")}
        if controller == .agent && level==desktop-2 {return .init(value:0,category:"signedSystemWallpaper")}
        if controller == .server && level==desktop-3 {return .init(value:0,category:"signedSystemBackdrop")}
        switch controller {
        case .finder:return .init(value:nil,category:"FinderSurfaceMayContainUserIcons")
        case .manager:return .init(value:nil,category:"WindowManagerSurfaceMayContainUserPixels")
        case .agent,.server:return .init(value:nil,category:"unqualifiedSystemLayer")
        case nil:return .init(value:nil,category:"otherOwnerObscuresCrop")
        }
    }
    return .init(value:nil,category:"noPositivePhysicalLayer")
}
private func layerAtProbe(_ crop:CGRect,_ p:Pair)->UInt32? { probeSurface(crop,p).value }

private func physicalFilter(_ content:SCShareableContent,_ display:SCDisplay,_ p:Pair,report:inout JSON)->SCContentFilter {
    let allowed=Set([p.sourceWindow.pid,p.targetWindow.pid])
    let excluded=content.applications.filter { app in
        if allowed.contains(app.processID) {return false}
        return app.bundleIdentifier != TrustedOwner.agent.rawValue || TrustedOwner.identify(app.processID) != .agent
    }
    let filter=SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
    filter.includeMenuBar=false
    func scope(_ w:Window)->JSON {
        ["cataloguedAppCount":content.applications.filter{$0.processID==w.pid && $0.bundleIdentifier==w.identifier}.count,
         "excluded":excluded.contains{$0.processID==w.pid},"includedApplicationEcho":filter.includedApplications.contains{$0.processID==w.pid},
         "includedWindowEcho":filter.includedWindows.contains{$0.windowID==w.number && $0.owningApplication?.processID==w.pid}]
    }
    report=["source":scope(p.sourceWindow),"target":scope(p.targetWindow),"excludedOtherApplicationCount":excluded.count,
            "filterModeDisplay":filter.style == .display]
    return filter
}

private func colorBand(_ candidate:[Int],_ expected:[Int]?)->String {
    guard let expected,candidate.count==3,expected.count==3 else {return "unavailable"}
    let difference=zip(candidate,expected).map{abs($0-$1)}.max() ?? 255
    for (upper,label) in [(10,"0–10"),(20,"11–20"),(30,"21–30"),(45,"31–45"),(60,"46–60"),(90,"61–90"),(128,"91–128")] where difference<=upper {return label}
    return "129–255"
}
private func rgb(_ img: CGImage) -> [Int]? {
    var data = [UInt8](repeating: 0, count: 4)
    return data.withUnsafeMutableBytes { bytes in
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB), let c = CGContext(data: bytes.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high; c.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard bytes[3] >= 245 else { return nil }
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }
}

// Diagnostic comparison with the older raw BGRA reader. Never persist raw physical colors.
private func directColor(_ pixels: CVPixelBuffer) -> [Int]? {
    guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {return nil}
    defer {CVPixelBufferUnlockBaseAddress(pixels, .readOnly)}
    guard let base=CVPixelBufferGetBaseAddress(pixels) else {return nil}
    var sum=[Int](repeating:0,count:3)
    for y in 0..<4 {
        let line=base.advanced(by:y*CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to:UInt8.self)
        for x in 0..<4 {
            guard line[x*4+3]>=245 else {return nil}
            for k in 0..<3 {sum[k]+=Int(line[x*4+2-k])}
        }
    }
    return sum.map{(($0/16+4)/8)*8}
}

// These authenticated negative-level system backdrops do not count as ordinary user windows.
// They do not authorize a physical pixel read. The actual foremost crop surface is proved separately.
private func censusBackdrop(_ detail:JSON,space:UInt64)->Bool {
    guard let code=detail["code"] as? JSON,code["apple"] as? Bool==true,let number=detail["number"] as? UInt32,
          let pid=detail["pid"] as? pid_t,let layer=detail["layer"] as? Int,
          (detail["forward"] as? [UInt64])?.contains(space)==true,(detail["reverse"] as? [UInt64])?.contains(space)==true,
          let owner=TrustedOwner.identify(pid),code["identifier"] as? String==owner.rawValue else {return false}
    let level=Int(CGWindowLevelForKey(.desktopWindow))
    guard (owner == .manager && layer==level-1) || (owner == .agent && layer==level-2) || (owner == .server && layer==level-3) else {return false}
    var raw=UnsafeRawPointer(bitPattern:UInt(number))
    guard let ids=CFArrayCreate(nil,&raw,1,nil),let rows=CGWindowListCreateDescriptionFromArray(ids) as? [JSON],rows.count==1,
          rows[0][kCGWindowNumber as String] as? UInt32==number,rows[0][kCGWindowOwnerPID as String] as? pid_t==pid,
          rows[0][kCGWindowLayer as String] as? Int==layer, let box=rows[0][kCGWindowBounds as String] as? JSON,
          CGRect(dictionaryRepresentation:box as CFDictionary)==CGDisplayBounds(CGMainDisplayID()) else {return false}
    return true
}
private func desktopCensus(_ p:Pair)->(Bool,JSON) {
    let ids=[p.topology.current,p.target]
    guard let census=NPContractMemberReport(ids as CFArray,p.hostPID) as? JSON else {return(false,["available":false])}
    var output:JSON=[:],clean=true
    for (index,window) in [p.sourceWindow,p.targetWindow].enumerated() {
        let sid=ids[index],key=index==0 ? "source":"target"
        guard let row=census[String(sid)] as? JSON,let windows=row["ordinary"] as? [JSON],let other=row["otherMembers"] as? Int,
              let unknown=row["unresolved"] as? Int,let details=row["otherDetails"] as? [JSON] else {
            output[key]=["available":false];clean=false;continue
        }
        let exact=windows.filter{$0["pid"] as? pid_t==window.pid && $0["number"] as? UInt32==window.number}
        let accepted=details.filter{censusBackdrop($0,space:sid)}.count
        let safe=exact.count==1 && windows.count==1 && birth(window.pid)==window.birth && unknown==0 && other==details.count && other==accepted
        output[key]=["available":true,"ordinaryCount":windows.count,"exactFixtureCount":exact.count,"unclassifiedMembers":unknown,
                     "otherMembers":other,"verifiedNegativeSystemBackdrops":accepted,"verifiedSharedOverlays":row["verifiedSharedOverlays"] ?? NSNull(),
                     "verifiedHostPanels":row["verifiedHostPanels"] ?? NSNull(),"systemMenus":row["systemMenuSurfaces"] ?? NSNull(),"qualified":safe]
        clean=clean && safe
    }
    return (clean,output)
}
private func cleanDesktops(_ p:Pair)->Bool {desktopCensus(p).0}

private func probeRect(_ pair: [SCWindow], display: SCDisplay) -> CGRect? {
    let overlap = pair[0].frame.intersection(pair[1].frame).intersection(display.frame).insetBy(dx: 24, dy: 24)
    guard !overlap.isNull, overlap.width >= 32, overlap.height >= 32 else { return nil }
    return CGRect(x: floor(overlap.midX - 12), y: floor(overlap.midY - 12), width: 24, height: 24)
}

private func rectangle(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }

private func probeConfiguration(_ r: CGRect, _ display: SCDisplay, _ hz: Int) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    c.sourceRect = r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    c.width=4;c.height=4;c.colorSpaceName=CGColorSpace.sRGB
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.minimumFrameInterval = CMTime(value: 1, timescale: Int32(hz))
    c.showsCursor = false; c.capturesAudio = false; c.captureMicrophone = false; c.includeChildWindows = false
    return c
}

// Read the actual compositor ordering and current Space independently of ScreenCaptureKit delivery.
// Only the two verified fixture IDs or strongly authenticated system wallpaper may be named in a proof.
private struct SurfaceReading {
    let start:Double, end:Double, space:UInt64?, visible:String?, reason:String, bound:Bool
    var receipt:JSON {["from":start,"to":end,"sameDisplayAndInput":bound,"space":space as Any? ?? NSNull(),"visible":visible as Any? ?? NSNull(),"reason":reason]}
}

private final class PresentationSurfaces: @unchecked Sendable {
    let pair:Pair, crop:CGRect, screen:NSScreen, endpoints:[String:Endpoint]
    private let queue=DispatchQueue(label:"nearpane.acceptance.presentation-surfaces",qos:.userInteractive)
    private let lock=NSLock()
    private var history=[SurfaceReading](), timer:DispatchSourceTimer?
    init(_ p:Pair,_ crop:CGRect,_ screen:NSScreen,_ endpoints:[String:Endpoint]) {
        pair=p;self.crop=crop;self.screen=screen;self.endpoints=endpoints
    }
    func start() {
        let source=DispatchSource.makeTimerSource(queue:queue)
        source.setEventHandler { [weak self] in self?.sample() }
        source.schedule(deadline:.now(),repeating:.milliseconds(5),leeway:.microseconds(350))
        timer=source;source.resume()
    }
    func stop() {timer?.cancel();timer=nil;queue.sync{}}
    private func sample() {
        let start=uptime()
        var sid:UInt64?,label:String?,reason="fixtureGenerationOrHumanInput"
        defer {
            let bound=sid != nil && pairIntact(pair)
            let row=SurfaceReading(start:start,end:uptime(),space:sid,visible:bound ? label:nil,reason:bound ? reason:"fixtureInputOrDisplayChanged",bound:bound)
            lock.withLock {
                // The whole recorder is capped at 25s. Keep more than the frame-delivery window without per-frame reallocations.
                if history.count>=1024 {history.removeFirst(512)}
                history.append(row)
            }
        }
        guard pairIntact(pair) else {return}
        guard let current=inventory(pair).0,let endpoint=endpoints[String(current)] else {reason="spaceOrTopology";return}
        sid=current
        let layer=probeSurface(crop,pair)
        guard let number=layer.value else {reason=layer.category;return}
        if number==pair.sourceWindow.number {label="source";reason="exactOpaqueFixture"}
        else if number==pair.targetWindow.number {label="target";reason="exactOpaqueFixture"}
        else if number==0 && wallpaper(screen)==endpoint.wallpaper {label="appleWallpaper";reason="verifiedSealedWallpaper"}
        else {reason="wallpaperChanged";return}
    }
    func observations(_ time:Double)->(SurfaceReading?,[SurfaceReading]) {
        lock.withLock {
            var low=0,high=history.count
            while low<high {
                let mid=(low+high)/2
                if history[mid].start<time {low=mid+1} else {high=mid}
            }
            let span=(low>0 && history[low-1].end>=time) ? history[low-1]:nil
            return(span,Array(history[low..<min(history.count,low+2)].filter{$0.start<=time+0.050}))
        }
    }
}

// This single physical SCStream persists no image. Its callback records the WindowServer presentation and
// hands the OS-owned buffer to a bounded observer. Pixel interpretation occurs only after scoped metadata.
private final class DisplayProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pair:Pair, endpoints:[String:Endpoint], surfaces:PresentationSurfaces
    let queue=DispatchQueue(label:"nearpane.acceptance.physical-presentations",qos:.userInteractive)
    private var records=[JSON?](),unresolved=[Int:JSON](),error=false
    private var scale=mach_timebase_info_data_t()
    var rows:[JSON] {queue.sync{Array(records.prefix(while:{$0 != nil}).compactMap{$0})}}
    var failed:Bool {queue.sync{error}}
    var timebase:JSON {["numerator":scale.numer,"denominator":scale.denom]}
    init(_ p:Pair,_ crop:CGRect,_ screen:NSScreen,_ endpoints:[String:Endpoint]) {
        pair=p;self.endpoints=endpoints;surfaces=PresentationSurfaces(p,crop,screen,endpoints)
        super.init();mach_timebase_info(&scale)
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {queue.async{self.error=true}}
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen else {return}
        guard records.count<6000 else {error=true;return}
        let received=uptime(),index=records.count
        let info=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
        let ticks=(info?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let t=Double(ticks)*Double(scale.numer)/Double(scale.denom)/1e9
        let status=info?[.status] as? Int ?? -1
        let base:JSON=["origin":"sck-display","displayTime":t,"presentationMachTicks":ticks,"callback":received,"status":status,"safe":false]
        records.append(nil)
        guard ticks>0 && t-received<=0.050 else {
            records[index]=base.merging(["blockedBy":"missingOrInvalidPresentationTime"]){_,new in new};return
        }
        let complete=status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue
        // Retain the OS buffer only until the first two actual post-presentation reads (maximum 50ms).
        let pixel=complete ? CMSampleBufferGetImageBuffer(sample):nil
        unresolved[index]=base
        schedule(index,base,t,pixel,first:true)
    }
    private func schedule(_ index:Int,_ base:JSON,_ t:Double,_ pixel:CVPixelBuffer?,first:Bool) {
        let deadline=t+(first ? 0.018:0.050)
        queue.asyncAfter(deadline:.now()+max(0,deadline-uptime())){[self] in
            let (spanning,post)=surfaces.observations(t)
            if post.count<2,first,uptime()<t+0.050 {schedule(index,base,t,pixel,first:false);return}
            var row=base
            row["postPresentationSurfaces"]=post.map(\.receipt)
            if let spanning {row["spanningSurface"]=spanning.receipt}
            row["metadataThrough"]=post.last?.end ?? uptime()
            defer {records[index]=row;unresolved.removeValue(forKey:index)}
            guard post.count==2 else {row["blockedBy"]="twoActualPostPresentationReadsUnavailable";return}
            let a=post[0],b=post[1]
            guard a.start>=t,a.start<=a.end,a.end<=b.start,b.start<=b.end,b.end-t<=0.050 else {row["blockedBy"]="postPresentationReadExceeded50ms";return}
            if base["status"] as? Int==SCFrameStatus.blank.rawValue,a.bound,b.bound,let space=a.space,space==b.space,
               spanning.map({$0.bound && $0.space==space}) ?? true {
                // Apple's explicit display-blank status contains no image; the signed display and issued pair can be
                // proved independently even when a blank screen has no visible foreground surface to attribute.
                row["blankDisplayBound"]=true;row["space"]=space
            }
            guard a.bound,b.bound,let space=a.space,let visible=a.visible,space==b.space,visible==b.visible else {row["blockedBy"]="twoPostPresentationSurfacesDisagree";return}
            if let spanning,spanning.visible != visible || spanning.space != space {
                row["blockedBy"]="surfaceChangedAcrossPresentation";return
            }
            row["space"]=space;row["visible"]=visible;row["safe"]=true
            guard let pixel else {return}
            guard CVPixelBufferGetWidth(pixel)==4,CVPixelBufferGetHeight(pixel)==4,CVPixelBufferGetPixelFormatType(pixel)==kCVPixelFormatType_32BGRA,
                  let raw=directColor(pixel) else {row["blockedBy"]="nonopaqueOrUnreadableNativeCrop";row["safe"]=false;return}
            var image:CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(pixel,options:nil,imageOut:&image)==noErr,let image,image.width==4,image.height==4,
                  let color=rgb(image) else {row["blockedBy"]="nativeSRGBCropUnavailable";row["safe"]=false;return}
            if visible=="source" || visible=="target" {
                row["colorPipeline"]="sRGB CGImage for stream and reference"
                row["sourceColorMaxDeltaBand"]=colorBand(color,endpoints[String(pair.topology.current)]?.rgb)
                row["targetColorMaxDeltaBand"]=colorBand(color,endpoints[String(pair.target)]?.rgb)
                row["directBGRAAgreesWithSRGB"]=comparison(raw,color)
            }
            row["lit"]=(color.max() ?? 0)>24
            row["matchesSource"]=comparison(color,endpoints[String(pair.topology.current)]?.rgb)
            row["matchesTarget"]=comparison(color,endpoints[String(pair.target)]?.rgb)
        }
    }
    func finish() async {
        // Deliver queued native samples and their actual follow-up observations. Keep any incomplete record explicit.
        queue.sync{}
        try? await Task.sleep(for:.milliseconds(105))
        surfaces.stop()
        queue.sync {for i in records.indices where records[i]==nil {records[i]=(unresolved[i] ?? [:]).merging(["blockedBy":"recorderStoppedBeforePresentationProof"]){_,new in new}}}
    }
    private func comparison(_ sample:[Int],_ expected:[Int]?)->Bool {
        guard let expected,expected.count==3 else {return false}
        return zip(sample,expected).allSatisfy{abs($0-$1)<=30}
    }
}

private struct Picture { let time: Double, bytes: Data }
private final class Frames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nearpane.acceptance.visual")
    let request: Pair, width: Int, height: Int
    private let lock = NSLock()
    private(set) var records = [JSON](), pictures = [Picture]()
    private var totalBytes = 0
    private(set) var droppedMovie = false, identityChanged = false, stoppedEarly = false
    private var scale = mach_timebase_info_data_t()

    init(_ request: Pair, width: Int, height: Int) {
        self.request = request; self.width = width; self.height = height
        super.init()
        mach_timebase_info(&scale)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { stoppedEarly = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let received = uptime()
        let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = attachment?[.status] as? Int
        let labels = ["complete", "idle", "blank", "suspended", "started", "stopped"]
        let name = status.flatMap { labels.indices.contains($0) ? labels[$0] : nil } ?? "unknown"
        let ticks = (attachment?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let when = ticks == 0 ? nil : Double(ticks) * Double(scale.numer) / Double(scale.denom) / 1e9
        let (space, order) = inventory(request,ordered:true)
        let source = request.sourceWindow.number, target = request.targetWindow.number
        let visible = order.map { $0.filter { $0 == source || $0 == target } }
        var row: JSON = ["callback": received, "status": name, "ticks": ticks, "displayTime": when as Any? ?? NSNull(),
                         "space": space as Any? ?? NSNull(), "visibleEnrolled": visible as Any? ?? NSNull()]
        if let order, let foremost = order.firstIndex(where: { $0 == source || $0 == target }) {
            row["otherWindowsAhead"] = foremost
        }
        let intact = pairIntact(request) && [request.topology.current, request.target].contains(space ?? 0)
        row["identitiesIntact"] = intact
        var image: Picture?
        if intact, (name == "complete" || name == "started"), let when,
           let buf = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(buf) == width,
           CVPixelBufferGetHeight(buf) == height, CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA,
           CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            if let address = CVPixelBufferGetBaseAddress(buf) {
                let step = CVPixelBufferGetBytesPerRow(buf)
                var opaque = 0, dark = 0, transparent = 0, anyLight = 0
                var bytes = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let start = address.advanced(by: step * y).assumingMemoryBound(to: UInt8.self)
                    bytes.append(start, count: width * 4)
                    for x in 0..<width {
                        let c = start.advanced(by: x * 4), a = c[3]
                        if a <= 4 { transparent += 1 }
                        if a >= 250 {
                            opaque += 1
                            if max(c[0], c[1], c[2]) <= 12 { dark += 1 } else { anyLight += 1 }
                        }
                    }
                }
                row["opaque"] = opaque; row["dark"] = dark; row["transparent"] = transparent; row["lit"] = anyLight
                image = Picture(time: when, bytes: bytes)
            }
        }
        lock.withLock {
            identityChanged = identityChanged || !intact
            if records.count < 6_000 { records.append(row) } else { stoppedEarly = true }
            if identityChanged || totalBytes + (image?.bytes.count ?? 0) > 64 * 1024 * 1024 {
                droppedMovie = true
                pictures.removeAll(keepingCapacity: false)
            }
            if let image, !droppedMovie {
                totalBytes += image.bytes.count
                pictures.append(image)
            }
        }
    }

    func ready() -> Bool {
        lock.withLock {
            !identityChanged && records.contains {
                $0["space"] as? UInt64 == request.topology.current &&
                ($0["visibleEnrolled"] as? [UInt32])?.contains(request.sourceWindow.number) == true &&
                ($0["opaque"] as? Int ?? 0) >= 4
            }
        }
    }
    func completed() -> ([JSON], [Picture], Bool, Bool, Bool) {
        lock.withLock { (records, pictures, droppedMovie, identityChanged, stoppedEarly) }
    }
}

private func writeMovie(_ pictures: [Picture], width: Int, height: Int, to url: URL) async throws {
    guard let first = pictures.first, let last = pictures.last, last.time > first.time else { throw Failure("fewer than two distinct captured frames") }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    guard writer.canAdd(input) else { throw Failure("silent video output unavailable") }
    writer.add(input)
    guard writer.startWriting() else { throw Failure("video writer did not start") }
    writer.startSession(atSourceTime: .zero)
    let deadline = uptime() + 7
    var previous = -1.0
    for frame in pictures where frame.time > previous {
        previous = frame.time
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, uptime() < deadline else { throw Failure("video writer stalled") }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adapter.pixelBufferPool else { throw Failure("video pool missing") }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure("video buffer unavailable") }
        guard let address = CVPixelBufferGetBaseAddress(result) else { CVPixelBufferUnlockBaseAddress(result, []); throw Failure("video mapping unavailable") }
        frame.bytes.withUnsafeBytes { src in
            let source = src.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let line = address.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: UInt8.self)
                let row = y * width * 4
                for x in stride(from: 0, to: width * 4, by: 4) {
                    let missing = 255 - Int(source[row+x+3])
                    for k in 0..<3 { line[x+k] = UInt8(min(255, Int(source[row+x+k]) + missing * 84 / 255)) }
                    line[x+3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        guard adapter.append(result, withPresentationTime: CMTime(seconds: frame.time - first.time, preferredTimescale: 60_000)) else {
            throw Failure("video append failed")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure("video writer failed") }
    let asset = AVURLAsset(url: url)
    guard try await asset.loadTracks(withMediaType: .video).count == 1,
          try await asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure("invalid silent movie tracks") }
}

@main private struct P0Visual {
    @MainActor static func main() async {
        guard [2,3].contains(CommandLine.arguments.count) else { exit(2) }
        if CommandLine.arguments[1]=="--wallpaper-metadata",CommandLine.arguments.count==2 {
            let fields=NSScreen.screens.map{wallpaperProof(NSWorkspace.shared.desktopImageURL(for:$0)).fields}
            print(String(decoding:try! JSONSerialization.data(withJSONObject:["screens":fields],options:.sortedKeys),as:UTF8.self));return
        }
        if CommandLine.arguments[1]=="--test-wallpaper-file",CommandLine.arguments.count==3 {
            let fields=wallpaperProof(URL(fileURLWithPath:CommandLine.arguments[2])).fields
            print(String(decoding:try! JSONSerialization.data(withJSONObject:fields,options:.sortedKeys),as:UTF8.self));return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-encoder" {
            let path = URL(fileURLWithPath: CommandLine.arguments[2])
            guard !FileManager.default.fileExists(atPath: path.path) else { exit(2) }
            let frames = (0..<6).map { index in
                Picture(time: Double(index) / 30, bytes: Data(repeating: UInt8(30 + index * 20), count: 64 * 32 * 4))
            }
            do { try await writeMovie(frames, width: 64, height: 32, to: path) } catch { exit(2) }
            return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do { try await capture(directory) }
        catch {
            try? json(["error": (error as? Failure)?.message ?? "native display stream unavailable"], directory.appendingPathComponent("error.json"))
            exit(2)
        }
    }

    @MainActor private static func verifyTarget(_ p:Pair,display:SCDisplay,screen:NSScreen,crop:CGRect,hz:Int,endpoint:Endpoint,
                                                 stream:SCStream,probe:DisplayProbe,end:End) async -> JSON {
        var result:JSON=["eligible":false,"sameStream":true,"independentTargetAndDisplayAgree":false,"linkedToNativeTarget":false]
        var observations=[JSON]()
        func check(_ stage:String)->(Bool,Bool) {
            let start=uptime(),current=inventory(p).0,layer=probeSurface(crop,p)
            let flags=["sameHumanInput":hardware()==p.hid,"sourceGeneration":exactGeneration(p.sourceWindow),
                       "targetGeneration":exactGeneration(p.targetWindow),"sameTargetSpace":current==p.target,
                       "sameSealedWallpaper":wallpaper(screen)==endpoint.wallpaper,"foremostExactTarget":layer.value==p.targetWindow.number]
            let failures=flags.filter{!$0.value}.keys.sorted()
            observations.append(["stage":stage,"from":start,"to":uptime(),"checks":flags,"failed":failures,
                  "space":current==p.target ? "target":(current==p.topology.current ? "source":"unbound"),"surface":layer.category])
            // Retrying a metadata query leaves all pixels and user input alone. Never re-admit a known foreign window, HID or Space.
            let transient=failures==["foremostExactTarget"] && ["signedSystemWallpaper","signedSystemBackdrop","WindowManagerSurfaceMayContainUserPixels",
                "unqualifiedSystemLayer","noSystemLayerList","noPositivePhysicalLayer"].contains(layer.category)
            return(failures.isEmpty,transient)
        }
        do {
            result["endRequest"]=["callerConfirmed":end.allowMovie,"positivePress":end.pressed>0,"independentEndAfterPress":end.ended>end.pressed]
            guard end.allowMovie,end.pressed>0,end.ended>end.pressed else {throw Failure("independent caller did not bind an issued interval")}
            var cleanReads=0
            let limit=uptime()+0.65
            for index in 0..<8 {
                let (scoped,transient)=check("terminal-admission-\(index+1)")
                if !scoped && !transient {throw Failure("terminal target foreground, bound process, wallpaper or physical input changed")}
                if scoped {
                    let census=desktopCensus(p)
                    observations[observations.count-1]["membership"]=census.1
                    observations[observations.count-1]["censusQualified"]=census.0
                    if [census.1["source"],census.1["target"]].contains(where:{part in
                        guard let facts=part as? JSON,let n=facts["ordinaryCount"] as? Int,let exact=facts["exactFixtureCount"] as? Int else {return false}
                        return n>exact
                    }) {throw Failure("terminal census found a different ordinary window")}
                    cleanReads=census.0 ? cleanReads+1:0
                } else {cleanReads=0}
                if cleanReads==2 {break}
                guard uptime()<limit,index<7 else {throw Failure("two consecutive clean foreground and desktop censuses were not observed within 650 ms")}
                try await Task.sleep(for:.milliseconds(35))
            }
            result["confirmedConsecutiveCensuses"]=cleanReads
            let current=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
            guard let freshDisplay=current.displays.first(where:{$0.displayID==display.displayID}),current.displays.count==1 else {throw Failure("physical display changed")}
            let pair=try [p.sourceWindow,p.targetWindow].map { w -> SCWindow in
                let windows=current.windows.filter{$0.windowID==w.number && $0.owningApplication?.processID==w.pid && $0.owningApplication?.bundleIdentifier==w.identifier}
                guard windows.count==1 else {throw Failure("current capture catalogue omitted a bound fixture")};return windows[0]
            }
            let validCrop=probeRect(pair,display:freshDisplay)==crop && rectangle(crop)==endpoint.crop
            result["freshFramesAgreeWithEnrolledCrop"]=validCrop;result["shareableTargetOnScreen"]=pair[1].isOnScreen
            guard validCrop,pair[1].isOnScreen,check("fresh-geometry").0 else {throw Failure("current target geometry or visibility disagreed with enrollment")}
            var scope:JSON=[:]
            let active=physicalFilter(current,freshDisplay,p,report:&scope),config=probeConfiguration(crop,freshDisplay,hz)
            result["freshFilterOwnership"]=scope;result["eligible"]=true
            guard active.style == .display else {throw Failure("current physical filter lost its display binding")}
            let only=SCContentFilter(display:freshDisplay,including:[pair[1]]);only.includeMenuBar=false
            let from=uptime()
            let own=try await SCScreenshotManager.captureImage(contentFilter:only,configuration:config)
            guard check("after-isolated-target").0,own.width==4,own.height==4,let reference=rgb(own) else {throw Failure("current isolated target calibration unavailable")}
            let real=try await SCScreenshotManager.captureImage(contentFilter:active,configuration:config)
            guard check("after-display-target").0,real.width==4,real.height==4,let displayed=rgb(real) else {throw Failure("current display calibration unavailable")}
            let sampledAt=uptime()
            result["sampleRequested"]=from;result["sampleReturned"]=sampledAt
            result["fixtureVsEnrolledBand"]=colorBand(reference,endpoint.rgb);result["displayVsCurrentFixtureBand"]=colorBand(displayed,reference)
            guard (reference.max() ?? 0)>45,zip(reference,endpoint.rgb).allSatisfy({abs($0-$1)<=30}),
                  zip(displayed,reference).allSatisfy({abs($0-$1)<=30}) else {throw Failure("fresh displayed pixels and independent target fixture color did not agree")}
            result["independentTargetAndDisplayAgree"]=true
            func targetTail()->ArraySlice<JSON>? {
                let rows=probe.rows
                guard let position=rows.lastIndex(where:{[0,4].contains($0["status"] as? Int ?? -1)}),
                      rows[position]["matchesTarget"] as? Bool==true,rows[position]["lit"] as? Bool==true else {return nil}
                let tail=rows[position...]
                guard tail.allSatisfy({[0,1,4].contains($0["status"] as? Int ?? -1) && $0["visible"] as? String=="target" &&
                                      $0["space"] as? UInt64==p.target && $0["safe"] as? Bool==true}) else {return nil}
                return tail
            }
            func linked()->Double? {
                guard let tail=targetTail(),let lastCheck=tail.last?["callback"] as? Double else {return nil}
                // An owned idle sample may carry only the last matching native complete frame; use an actual display time.
                return tail.reversed().compactMap { row -> Double? in
                    guard let t=row["displayTime"] as? Double,t>=max(end.ended,sampledAt),uptime()-t<=0.05,
                          max(row["metadataThrough"] as? Double ?? 0,lastCheck)>=t else {return nil}
                    return t
                }.first
            }
            if targetTail()==nil {
                // Re-enumerate the permitted apps from the *current* destination. Update only this same physical stream.
                // Keep all events before, during and after the update; a real handoff gap still fails the 50-ms gate.
                result["filterUpdateRequested"]=uptime()
                try await stream.updateContentFilter(active)
                result["filterUpdateReturned"]=uptime()
            }
            let deadline=uptime()+0.9
            repeat {
                guard check("native-presentation-link").0 else {throw Failure("target changed while binding the native display presentation")}
                if let stamp=linked() {
                    result["linkedToNativeTarget"]=true;result["nativeTargetTime"]=stamp;result["observations"]=observations;return result
                }
                try await Task.sleep(for:.milliseconds(20))
            } while uptime()<deadline
            throw Failure("current display and fixture matched but the continuous native stream did not show the target color")
        } catch {
            result["observations"]=observations
            result["reason"]=(error as? Failure)?.message ?? "guarded target endpoint query unavailable"
            return result
        }
    }

    @MainActor private static func capture(_ directory: URL) async throws {
        let b = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: directory.appendingPathComponent("binding.json")))
        let p = b.request
        var admission:JSON=["nonce":b.nonce.uuidString,"sourceSpace":p.topology.current,"targetSpace":p.target]
        let receipt=directory.appendingPathComponent("admission.json")
        defer {try? json(admission,receipt)}
        let reader=NPReadOnlySpacesOpen()==1
        let gate:[String:Bool]=["screenPermission":CGPreflightScreenCaptureAccess(),"nativeInventory":reader,"guardianGeneration":birth(b.guardian)==b.guardianBirth,
                               "fixtureGenerationsAndInput":pairIntact(p),"sourceCurrent":reader && inventory(p).0==p.topology.current]
        admission["initial"]=gate
        let initialFailures=gate.filter{!$0.value}.keys.sorted()
        guard initialFailures.isEmpty else {throw Failure("Initial physical admission: "+initialFailures.joined(separator:", "))}
        let all = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let displays = all.displays.filter {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID($0.displayID)?.takeRetainedValue() else { return false }
            return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String) == p.topology.display
        }
        admission["matchingPhysicalDisplays"]=displays.count
        guard displays.count == 1, let display = displays.first, CGDisplayIsActive(display.displayID) != 0,
              CGDisplayIsInMirrorSet(display.displayID) == 0, CGDisplayIsAsleep(display.displayID) == 0,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else {
            throw Failure("active physical display could not be matched")
        }
        var matchesPerWindow=[Int]()
        let included = try [p.sourceWindow,p.targetWindow].map { w -> SCWindow in
            let names = ["org.nearpane.acceptance.LifecycleWindow", "net.example.spaces-route-witness", "net.example.spaces-document"]
            let matches = all.windows.filter { $0.windowID == w.number && $0.owningApplication?.processID == w.pid && $0.owningApplication?.bundleIdentifier == w.identifier }
            matchesPerWindow.append(matches.count);admission["matchingEnrolledWindows"]=matchesPerWindow
            guard names.contains(w.identifier), w.executable.hasPrefix("/private/tmp/nearpane-d01."), matches.count == 1, let only = matches.first else {
                throw Failure("ScreenCaptureKit cannot bind both enrolled fixtures, including the off-Space endpoint")
            }
            return only
        }
        let allowed = Set(included.map(\.windowID))
        guard allowed.count == 2 else { throw Failure("window identity collision") }
        let crop = probeRect(included, display: display)
        let hz = max(1, min(60, screen.maximumFramesPerSecond))
        let wall=wallpaperProof(NSWorkspace.shared.desktopImageURL(for:screen)),census=desktopCensus(p)
        let surface=crop.map{probeSurface($0,p)}
        admission["wallpaper"]=wall.fields;admission["membership"]=census.1
        admission["crop"]=crop.map(rectangle) as Any? ?? NSNull();admission["foremostSurface"]=surface?.category ?? "noCommonRectangle"
        var reasons=[String]()
        if crop==nil {reasons.append("no common interior rectangle on the physical display")}
        if wall.fingerprint==nil {reasons.append("wallpaper: "+wall.source)}
        if !census.0 {reasons.append("exclusive ordinary desktop membership unconfirmed")}
        if surface?.value != p.sourceWindow.number {reasons.append("physical crop: "+(surface?.category ?? "unavailable"))}
        admission["failed"]=reasons
        try json(admission,receipt)
        var filterScope:JSON=[:]
        let displayFilter=physicalFilter(all,display,p,report:&filterScope)
        admission["filterOwnership"]=filterScope
        admission["displayFilterMode"]=displayFilter.style == .display
        if CommandLine.arguments.last == "enroll" {
            guard reasons.isEmpty,let crop,let fingerprint=wall.fingerprint,displayFilter.style == .display else {
                throw Failure("Endpoint admission: "+(reasons.isEmpty ? "not a display composition" : reasons.joined(separator:", ")))
            }
            let sourceOnly=SCContentFilter(display:display,including:[included[0]])
            sourceOnly.includeMenuBar=false
            let config=probeConfiguration(crop,display,hz)
            let marker=try await SCScreenshotManager.captureImage(contentFilter:sourceOnly,configuration:config)
            guard marker.width==4,marker.height==4,let expected=rgb(marker),(expected.max() ?? 0)>45 else {admission["markerReference"]=false;throw Failure("owned document reference crop was transparent or dark")}
            admission["markerReference"]=true
            func stillSafe()->Bool {
                pairIntact(p) && inventory(p).0==p.topology.current && layerAtProbe(crop,p)==p.sourceWindow.number && wallpaper(screen)==fingerprint
            }
            guard stillSafe() else {admission["beforePhysicalSample"]=false;throw Failure("foreground fixture or wallpaper changed before marker calibration")}
            admission["beforePhysicalSample"]=true
            let image=try await SCScreenshotManager.captureImage(contentFilter:displayFilter,configuration:config)
            let safe=stillSafe()
            admission["afterPhysicalSample"]=safe
            guard safe else {throw Failure("physical crop ownership changed during marker calibration")}
            let physical=(image.width==4 && image.height==4) ? rgb(image) : nil
            admission["physicalSampleSizeConfirmed"]=image.width==4 && image.height==4
            let agrees=physical.map{candidate in zip(candidate,expected).allSatisfy{abs($0-$1)<=30}} ?? false
            admission["actualDisplayMatchesOwnedReference"]=agrees
            guard agrees,let color=physical,(color.max() ?? 0)>45 else {throw Failure("actual display crop did not match the enrolled document's color")}
            // Persist only the color from the exact allowlisted synthetic window. The physical crop provides a yes/no comparison.
            let ep=Endpoint(space:p.topology.current,display:p.topology.display,wallpaper:fingerprint,crop:rectangle(crop),rgb:expected)
            try JSONEncoder().encode(ep).write(to:directory.appendingPathComponent("endpoint.json"),options:.atomic)
            return
        }
        var probe:DisplayProbe?,observerStream:SCStream?
        let a=b.endpoints?[String(p.topology.current)],z=b.endpoints?[String(p.target)]
        let qualified=a?.display==p.topology.display && z?.display==p.topology.display && a?.space==p.topology.current && z?.space==p.target
        let geometry=crop != nil && a?.crop==crop.map(rectangle) && z?.crop==a?.crop
        let distinct=a?.rgb.count==3 && z?.rgb.count==3 && zip(a?.rgb ?? [],z?.rgb ?? []).contains{abs($0-$1)>60}
        let approvedWallpaper=a != nil && z != nil && a?.wallpaper==wall.fingerprint && z?.wallpaper != nil
        admission["endpointCalibration"]=["sourceEnrolled":a != nil,"targetEnrolled":z != nil,"displayAndSpaceIDs":qualified,
                                         "commonCrop":geometry,"distinctMarkerColors":distinct,"sourceWallpaperMatches":approvedWallpaper]
        if !qualified {reasons.append("both independent endpoint calibrations are required")}
        if !geometry {reasons.append("physical crop does not match enrolled anchors")}
        if !distinct {reasons.append("controlled source and target marker colors are not distinguishable")}
        if !approvedWallpaper {reasons.append("current wallpaper does not match the enrolled source")}
        admission["failed"]=reasons
        if reasons.isEmpty,let crop,let endpoints=b.endpoints {
            let observer = DisplayProbe(p, crop, screen, endpoints)
            let probeConfig=probeConfiguration(crop,display,hz)
            // Ask the physical display for native cadence. Each complete/idle sample keeps its own WindowServer time.
            probeConfig.minimumFrameInterval = .zero;probeConfig.queueDepth=5
            let independent = SCStream(filter: displayFilter, configuration: probeConfig, delegate: observer)
            do {
                guard displayFilter.style == .display else { throw Failure("independent probe is not a display-bound stream") }
                observer.surfaces.start()
                try independent.addStreamOutput(observer, type: .screen, sampleHandlerQueue: observer.queue)
                try await independent.startCapture()
                probe = observer; observerStream = independent
            } catch {admission["streamStartError"]="physical display stream could not start";try? await independent.stopCapture();await observer.finish()}
        }
        admission["physicalStreamArmed"]=probe != nil
        try json(admission,receipt)
        let filter = SCContentFilter(display: display, including: included)
        filter.includeMenuBar = false
        guard Set(filter.includedWindows.map(\.windowID)) == allowed,
              Set(filter.includedApplications.map(\.processID)).isSubset(of: Set([p.sourceWindow.pid, p.targetWindow.pid])) else {
            throw Failure("ScreenCaptureKit did not echo the exact window allowlist")
        }
        let config = SCStreamConfiguration()
        let width = 192, height = min(512, max(2, 2 * Int((Double(width) * display.frame.height / display.frame.width / 2).rounded())))
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(hz))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.includeChildWindows = false; config.shouldBeOpaque = false; config.queueDepth = 5
        let output = Frames(p, width: width, height: height)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        let start = uptime(), deadline = start + 25
        let endFile = directory.appendingPathComponent("end.json")
        var ready=false,physicalSourceReady=false,end:End?
        while uptime() < deadline && birth(b.guardian) == b.guardianBirth {
            if !ready,output.ready() {
                physicalSourceReady=probe?.rows.suffix(20).contains { row in
                    row["safe"] as? Bool==true && row["lit"] as? Bool==true && row["matchesSource"] as? Bool==true &&
                    row["visible"] as? String=="source" && row["space"] as? UInt64==p.topology.current &&
                    (row["displayTime"] as? Double ?? 0)>0 && uptime()-(row["callback"] as? Double ?? 0)<=0.15
                } ?? false
                if physicalSourceReady || probe==nil || uptime()-start>2.5 {
                    admission["sourceFrameReadyBeforePress"]=physicalSourceReady;try json(admission,receipt)
                    try json(["ready":true,"physicalReady":physicalSourceReady,"physicalAdmission":admission,
                              "nonce":b.nonce.uuidString,"start":start,"pid":getpid(),"display":p.topology.display.uuidString],
                             directory.appendingPathComponent("ready.json"))
                    ready=true
                }
            }
            if let bytes = try? Data(contentsOf: endFile), let e = try? JSONDecoder().decode(End.self, from: bytes), e.nonce == b.nonce {
                end = e; break
            }
            if !ready && uptime() - start > 5 { break }
            try await Task.sleep(for: .milliseconds(12))
        }
        var terminal:JSON=[:]
        if let end,let observerStream,let probe,let crop,let endpoint=b.endpoints?[String(p.target)] {
            terminal=await verifyTarget(p,display:display,screen:screen,crop:crop,hz:hz,endpoint:endpoint,stream:observerStream,probe:probe,end:end)
        }
        try? await stream.stopCapture()
        if let observerStream {try? await observerStream.stopCapture()}
        if let probe {await probe.finish()}
        output.queue.sync {}
        let (records, pictures, discarded, changed, failed) = output.completed()
        let post = inventory(p).0
        var saved = false
        let destination = directory.appendingPathComponent("verified-pair.mp4")
        let pending = directory.appendingPathComponent(".writing-" + b.nonce.uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: pending) }
        if let end, end.allowMovie, end.pressed > 0, end.ended > end.pressed, ready, !changed, !failed, !discarded,
           birth(b.guardian) == b.guardianBirth, pairIntact(p), post == p.target {
            do {
                try await writeMovie(pictures, width: width, height: height, to: pending)
                if pairIntact(p) && inventory(p).0 == p.target {
                    try FileManager.default.moveItem(at: pending, to: destination)
                    saved = true
                }
            } catch {}
        }
        try json(["nonce": b.nonce.uuidString, "ready": ready, "display": p.topology.display.uuidString,
                  "requestedHz": hz, "refreshLimitHz": screen.maximumFramesPerSecond, "displayModeHz": CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0,
                  "width": width, "height": height, "filterStyle": filter.style.rawValue,
                  "windows": allowed.sorted(), "wallpaperIncluded": false, "audioEnabled": false,
                  "physical": ["presentationReviewVersion":3,"machTimebase":probe?.timebase ?? [:],"terminalTarget":terminal,"armed":probe != nil,"sourceFrameReadyBeforePress":physicalSourceReady,"admission":admission,"censusAfter":probe != nil && cleanDesktops(p),
                               "filter": "display-excluding-other-apps", "crop": crop.map(rectangle) as Any? ?? NSNull(),
                               "error": probe?.failed ?? false, "frames": probe?.rows ?? []] as JSON,
                  "changed": changed, "stoppedEarly": failed, "start": start, "stop": uptime(), "postSpace": post as Any? ?? NSNull(),
                  "movie": saved, "memoryCapExceeded": discarded && !changed, "frames": records],
                 directory.appendingPathComponent("frames.json"))
    }
}
