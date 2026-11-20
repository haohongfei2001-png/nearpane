import AppKit
import CoreMedia
import CryptoKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private typealias Row = [String:Any]
private struct Refusal: Error { let reason:String; init(_ reason:String){self.reason=reason} }
private func captureUptime() -> Double { ProcessInfo.processInfo.systemUptime }
private func digest(_ data:Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
private func rect(_ values:[Double]) throws -> CGRect {
    guard values.count==4,values.allSatisfy(\.isFinite),values[2]>0,values[3]>0 else{throw Refusal("invalidRectangle")}
    return CGRect(x:values[0],y:values[1],width:values[2],height:values[3])
}
func overviewTemporaryURL(_ spelling:String) -> URL? {
    guard spelling.hasPrefix("/private/tmp/") || spelling.hasPrefix("/tmp/"),
          let resolved=realpath(spelling,nil) else{return nil}
    defer{free(resolved)}
    let canonical=String(cString:resolved)
    // The only accepted alias is the system's /tmp for /private/tmp. Refuse any
    // other symlink, traversal or synthetic argv spelling, even into an owned kit.
    guard canonical.hasPrefix("/private/tmp/"),
          spelling==canonical || (spelling.hasPrefix("/tmp/") && "/private"+spelling==canonical) else{return nil}
    return URL(fileURLWithPath:canonical)
}
private func dictionary(_ data:Data) throws -> Row {
    guard let v=try JSONSerialization.jsonObject(with:data) as? Row else{throw Refusal("invalidReadback")}
    return v
}
private func sameBinding(_ a:Row,_ b:Row) -> Bool {
    let keys=["hostPID","hostBirth","hostHash","display","space","panel","fixturePID","fixtureBirth","fixtureHash","numbers","sources","pictures","present","kinds"]
    return keys.allSatisfy { key in
        guard let left=a[key] as? NSObject,let right=b[key] as? NSObject else{return false}
        return left.isEqual(right)
    }
}
struct ImageRead {
    let pixels:Data, width:Int,height:Int,area:CGRect,scale:Int
    let start:Double,end:Double
    func marker(_ region:CGRect,document:Int) throws -> Int {
        guard area.contains(region) else{throw Refusal("markerOutsideCapturedArea")}
        let x0=Int(ceil((region.minX-area.minX)*Double(scale))),x1=Int(floor((region.maxX-area.minX)*Double(scale)))
        let y0=Int(ceil((region.minY-area.minY)*Double(scale))),y1=Int(floor((region.maxY-area.minY)*Double(scale)))
        guard x0>=0,y0>=0,x1<=width,y1<=height,x1>x0,y1>y0 else{throw Refusal("unreadableMarker")}
        return try pixels.withUnsafeBytes { (raw:UnsafeRawBufferPointer) -> Int in
            let p=raw.bindMemory(to:UInt8.self)
            let first=4*(y0*width+x0), color=PairedPreviewPalette.classify(Int(p[first+2]),Int(p[first+1]),Int(p[first]),Int(p[first+3]))
            guard let epoch=PairedPreviewPalette.epochs.indices.first(where:{color=="\(document)/\($0)"}) else{throw Refusal("unexpectedFixtureMarker")}
            for y in y0..<y1 {for x in x0..<x1 {
                let n=4*(y*width+x)
                guard p[n+3]==255,PairedPreviewPalette.classify(Int(p[n+2]),Int(p[n+1]),Int(p[n]),255)==color else{
                    throw Refusal("unconfirmedPixelsInFixtureBody")
                }
            }}
            return epoch
        }
    }
    func png() throws -> Data {
        let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let provider=CGDataProvider(data:pixels as CFData),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4*width,space:space,bitmapInfo:info,
                                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw Refusal("nativeFrameUnavailable")}
        let data=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else{throw Refusal("pngEncoderUnavailable")}
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else{throw Refusal("pngEncodingFailed")}
        return data as Data
    }
}
// Single-window SCK sources supply a full-size IOSurface. Only approved rows
// are copied into user space. White fills the space between the two AX cards.
struct WindowSampleRegion {
    let windowWidth:Int, windowHeight:Int, width:Int, height:Int
    let originX:Int, originY:Int, retained:[CGRect]
    init(window:CGRect, crop:CGRect, allowed:[CGRect], scale:Int) throws {
        guard (1...4).contains(scale), (1...2).contains(allowed.count), window.contains(crop), window != crop,
              window.width>0,window.height>0,window.width*CGFloat(scale)<=8192,window.height*CGFloat(scale)<=8192,
              !crop.isEmpty,crop.integral==crop else{throw Refusal("uncontainedWindowCrop")}
        let s=CGFloat(scale)
        // CG and AX both give top-left global display coordinates. Translate to
        // native window backing pixels, retaining only complete approved pixels.
        let values=[window.width*s,window.height*s,(crop.minX-window.minX)*s,(crop.minY-window.minY)*s,crop.width*s,crop.height*s]
        guard values.allSatisfy({$0.isFinite && $0.rounded()==$0}) else{throw Refusal("unregisteredPhysicalPixelGrid")}
        windowWidth=Int(values[0]);windowHeight=Int(values[1]);originX=Int(values[2]);originY=Int(values[3]);width=Int(values[4]);height=Int(values[5])
        retained=try allowed.map { rect in
            guard window.contains(rect) else{throw Refusal("cardOutsideNativeWindow")}
            let cut=rect.intersection(crop)
            guard !cut.isNull,!cut.isEmpty else{throw Refusal("emptyRetainedCard")}
            let x=ceil((cut.minX-crop.minX)*s),y=ceil((cut.minY-crop.minY)*s)
            let farX=floor((cut.maxX-crop.minX)*s),farY=floor((cut.maxY-crop.minY)*s)
            guard farX>x,farY>y else{throw Refusal("emptyRetainedCard")}
            return CGRect(x:x,y:y,width:farX-x,height:farY-y)
        }
        guard retained.count==1 || !retained[0].intersects(retained[1]) else{throw Refusal("overlappingRetainedCards")}
    }
    func copyBGRA(from address:UnsafeRawPointer,stride:Int) throws -> Data {
        guard stride>=4*windowWidth else{throw Refusal("invalidNativeWindowStride")}
        var output=Data(repeating:255,count:width*height*4)
        try output.withUnsafeMutableBytes { (bytes:UnsafeMutableRawBufferPointer) in
            guard let destination=bytes.baseAddress else{throw Refusal("emptyWindowCrop")}
            for r in retained {
                let x=Int(r.minX), count=Int(r.width)*4
                for y in Int(r.minY)..<Int(r.maxY) {
                    let input=address.advanced(by:(originY+y)*stride+(originX+x)*4).assumingMemoryBound(to:UInt8.self)
                    let row=destination.advanced(by:(y*width+x)*4)
                    row.copyMemory(from:input,byteCount:count)
                    for alpha in Swift.stride(from:3,to:count,by:4) where input[alpha] != 255 {throw Refusal("nativeWhiteBackingNotOpaque")}
                }
            }
        }
        return output
    }
}

private func snap(window:SCWindow,area:CGRect,allowed:[CGRect]) async throws -> ImageRead {
    let filter=SCContentFilter(desktopIndependentWindow:window)
    filter.includeMenuBar=false
    guard filter.style == .window,filter.includedWindows.count==1,let only=filter.includedWindows.first,
          only.windowID==window.windowID,let owner=window.owningApplication?.processID,only.owningApplication?.processID==owner,
          filter.contentRect.size==window.frame.size else{throw Refusal("filterIsNotExactIndependentWindow")}
    let scale=Int(filter.pointPixelScale)
    guard Float(scale)==filter.pointPixelScale else{throw Refusal("unknownPhysicalScale")}
    let region=try WindowSampleRegion(window:window.frame,crop:area,allowed:allowed,scale:scale)
    let config=SCStreamConfiguration()
    config.width=region.windowWidth;config.height=region.windowHeight
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=CGColorSpace.sRGB
    config.shouldBeOpaque=true
    config.ignoreShadowsSingleWindow=true;config.ignoreGlobalClipSingleWindow=true
    config.showsCursor=false;config.showMouseClicks=false;config.capturesAudio=false;config.captureMicrophone=false;config.includeChildWindows=false
    let began=captureUptime(),sample=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:config),ended=captureUptime()
    let info=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
    let status=(info?[.status] as? NSNumber)?.intValue
    guard status==nil || status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue,
          CMSampleBufferIsValid(sample),CMSampleBufferDataIsReady(sample),let image=CMSampleBufferGetImageBuffer(sample),
          CVPixelBufferGetWidth(image)==region.windowWidth,CVPixelBufferGetHeight(image)==region.windowHeight,
          CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw Refusal("actualNativeWindowFrameUnavailable")}
    defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
    guard let address=CVPixelBufferGetBaseAddress(image) else{throw Refusal("emptyFrame")}
    let pixels=try region.copyBGRA(from:address,stride:CVPixelBufferGetBytesPerRow(image))
    return ImageRead(pixels:pixels,width:region.width,height:region.height,area:area,scale:scale,start:began,end:ended)
}

#if !PAIRED_OVERVIEW_TEST
@main struct PairedOverview {
    static func main() async {
        let result:Row
        do {result=try await capture()} catch {
            result=["status":"BLOCKED","reason":(error as? Refusal)?.reason ?? "systemOrObserverReadFailed"]
        }
        if let data=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys){print(String(decoding:data,as:UTF8.self))}
    }
    private static func capture() async throws -> Row {
        guard CommandLine.arguments.count==2,CGPreflightScreenCaptureAccess() else{throw Refusal("permissionOrArguments")}
        guard let folder=overviewTemporaryURL(CommandLine.arguments[1]) else{throw Refusal("invalidSessionFolder")}
        let parent=folder.deletingLastPathComponent()
        guard UUID(uuidString:folder.lastPathComponent) != nil,parent.lastPathComponent.hasPrefix("nearpane-preview-pair."),
              parent.deletingLastPathComponent().path=="/private/tmp" else{throw Refusal("invalidSessionFolder")}
        for u in [parent,folder] {
            var s=stat();guard lstat(u.path,&s)==0,s.st_uid==getuid(),s.st_mode & 0o177777 == 0o40700 else{throw Refusal("unownedSessionFolder")}
        }
        let r=try dictionary(FileHandle.standardInput.readDataToEndOfFile())
        guard r["pictureInteriorsProven"] as? Bool==true,r["cardIdentityProven"] as? Bool==true,let host=r["hostPID"] as? pid_t,let h=r["hostHash"] as? String,
              let hostBirth=r["hostBirth"] as? UInt64,let fixture=r["fixturePID"] as? pid_t,let born=r["fixtureBirth"] as? UInt64,let f=r["fixtureHash"] as? String,
              let ids=r["numbers"] as? [UInt32],ids.count==2,Set(ids).count==2,let panel=r["panel"] as? UInt32,
              let sid=r["space"] as? UInt64,let displayID=r["display"] as? String,let sources=r["sources"] as? [[Double]],sources.count==2,
              r["present"] as? [Bool]==[true,true] else {throw Refusal("twoLiveProductCardsRequired")}
        var executable=[CChar](repeating:0,count:4096)
        guard proc_pidpath(getpid(),&executable,UInt32(executable.count))>0,
              let reader=overviewTemporaryURL(String(cString:executable)),reader.lastPathComponent=="paired-overview" else{
            throw Refusal("untrustedReaderExecutable")
        }
        let kit=reader.deletingLastPathComponent()
        var kitStat=stat()
        guard kit.deletingLastPathComponent().path=="/private/tmp",kit.lastPathComponent.hasPrefix("nearpane-d01."),
              lstat(kit.path,&kitStat)==0,kitStat.st_uid==getuid(),kitStat.st_mode & 0o177777 == 0o40700 else{throw Refusal("untrustedBuildDirectory")}
        let scope=kit.appendingPathComponent("paired-overview-scope"),fixtureExe=kit.appendingPathComponent("Field Notes.app/Contents/MacOS/FieldNotes")
        func confirm() throws -> Row {
            let state=try dictionary(Data(contentsOf:folder.appendingPathComponent("windows.json")))
            guard state["pid"] as? pid_t==fixture,state["birth"] as? UInt64==born,
                  state["session"] as? String==folder.lastPathComponent,state["presentation"] as? String=="paired-preview",
                  state["bundle"] as? String=="net.example.spaces-document",state["numbers"] as? [UInt32]==ids,
                  state["visible"] as? [Bool]==[true,true],state["minimized"] as? [Bool]==[false,false],
                  state["sha256"] as? [String]==Array(repeating:digest(Data()),count:2) else{throw Refusal("fixtureDocumentsNotBoundAndEmpty")}
            let p=Process(),pipe=Pipe();p.executableURL=scope;p.standardOutput=pipe
            p.arguments=[String(host),h,String(fixture),String(born),f,fixtureExe.path,String(ids[0]),String(ids[1]),String(sid)]
            try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            let fresh=try dictionary(data)
            guard p.terminationStatus==0,fresh["pictureInteriorsProven"] as? Bool==true,fresh["cardIdentityProven"] as? Bool==true,sameBinding(fresh,r),let overview=fresh["overview"] as? Row else{
                throw Refusal("signedWindowCardOrDesktopBindingChanged")
            }
            guard let census=fresh["windowCensus"] as? Row,census["expected"] as? [UInt32]==ids,
                  census["admitted"] as? Bool==true,census["unknown"] as? Int==0,census["unresolved"] as? Int==0 else{throw Refusal("isolatedDesktopMembershipUnconfirmed")}
            guard overview["ready"] as? Bool==true else{throw Refusal(overview["reason"] as? String ?? "unconfirmedCardRegion")}
            return overview
        }
        let initial=try confirm()
        guard let coordinates=initial["crop"] as? [Double],let pictureRects=initial["previews"] as? [[Double]],pictureRects.count==2,
              let cardRects=initial["cards"] as? [[Double]],cardRects.count==2,let frame=initial["panelFrame"] as? [Double],
              let sourceFrames=initial["sourceFrames"] as? [[Double]],sourceFrames.count==2 else{throw Refusal("missingReadableGeometry")}
        let crop=try rect(coordinates),areas=try sources.map(rect),cards=try cardRects.map(rect)
        let windows=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let matches=windows.displays.filter{ screen in
            CGDisplayCreateUUIDFromDisplayID(screen.displayID).map{CFUUIDCreateString(nil,$0.takeRetainedValue()) as String==displayID} ?? false
        }
        guard matches.count==1,let display=matches.first else{throw Refusal("displayMismatch")}
        func one(_ n:UInt32,_ p:pid_t) throws -> SCWindow {
            let w=windows.windows.filter{$0.windowID==n && $0.owningApplication?.processID==p && $0.isOnScreen}
            guard w.count==1 else{throw Refusal("exactOnscreenSCKWindowUnavailable")};return w[0]
        }
        let w0=try one(ids[0],fixture),w1=try one(ids[1],fixture),wp=try one(panel,host)
        guard display.frame.contains(crop),areas.allSatisfy(display.frame.contains),
              wp.owningApplication?.bundleIdentifier=="com.holdsnow.nearpane.alpha",wp.frame == (try rect(frame)),
              w0.frame == (try rect(sourceFrames[0])),w1.frame == (try rect(sourceFrames[1])),
              [w0,w1].allSatisfy({$0.owningApplication?.bundleIdentifier=="net.example.spaces-document"}) else{
            throw Refusal("sckWindowIdentityOrGeometryChanged")
        }
        guard NSDictionary(dictionary:initial).isEqual(to:try confirm()) else{throw Refusal("captureAdmissionChanged")}
        let bindingBefore=captureUptime()
        async let a=snap(window:w0,area:areas[0],allowed:[areas[0]])
        async let b=snap(window:w1,area:areas[1],allowed:[areas[1]])
        async let picture=snap(window:wp,area:crop,allowed:cards)
        let (left,right,raw)=try await (a,b,picture)
        func marker(_ read:ImageRead,region:CGRect,document:Int,site:String) throws -> Int {
            do {return try read.marker(region,document:document)}
            catch let refusal as Refusal {throw Refusal(site + (document==0 ? "One":"Two") + refusal.reason.prefix(1).uppercased() + refusal.reason.dropFirst())}
        }
        let sourceEpochs=try [marker(left,region:areas[0],document:0,site:"source"),marker(right,region:areas[1],document:1,site:"source")]
        var cardEpochs=[Int]()
        for (i, coords) in pictureRects.enumerated() {
            let p=try rect(coords)
            // Use a substantial interior below the synthetic window's title bar.
            let body=CGRect(x:p.minX+p.width*0.12,y:p.minY+p.height*0.38,width:p.width*0.76,height:p.height*0.48)
            cardEpochs.append(try marker(raw,region:body,document:i,site:"card"))
        }
        guard sourceEpochs==cardEpochs,Set(sourceEpochs).count==1 else{throw Refusal("actualSourceAndCardMarkersDiffer")}
        guard NSDictionary(dictionary:initial).isEqual(to:try confirm()) else{throw Refusal("bindingOrPhysicalInputChangedDuringImage")}
        let bindingAfter=captureUptime()
        let png=try raw.png();let output=folder.appendingPathComponent("paired-overview.png")
        try png.write(to:output,options:.withoutOverwriting)
        return ["status":"CAPTURED","file":output.lastPathComponent,"sha256":digest(png),"hostPID":host,"panel":panel,"fixturePID":fixture,
                "numbers":ids,"display":displayID,"space":sid,"hostBirth":hostBirth,"hostHash":h,"fixtureBirth":born,"fixtureHash":f,
                "bindingBefore":bindingBefore,"bindingAfter":bindingAfter,"width":raw.width,"height":raw.height,"scale":raw.scale,"crop":coordinates,
                "epoch":sourceEpochs[0],"sourceEpochs":sourceEpochs,"cardEpochs":cardEpochs,"panelSample":[raw.start,raw.end],
                "singleIncludedHostWindow":true,"beforeAfterScopeEqual":true,"isolatedProfile":true,"fixedCaptions":initial["fixedCaptions"]!,
                "sourceDocumentsEmpty":true,"otherControlsInCrop":0,"captureSource":"desktopIndependentWindow",
                "includedWindowNumbers":[panel],"filterStyle":"window","nativeTransparencyBacking":"solidWhite",
                "captureIncludesChildWindows":false,"cardGapBacking":"solidWhite","panelFrame":frame,"retainedCardFrames":cardRects,
                "retainedCardIDs":initial["cardIDs"]!,"sourceSamples":[[left.start,left.end],[right.start,right.end]]]
    }
}
#endif
