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
private func snap(display:SCDisplay,window:SCWindow,area:CGRect) async throws -> ImageRead {
    guard window.frame.contains(area),display.frame.contains(area),area.integral==area else{throw Refusal("uncontainedCapture")}
    let filter=SCContentFilter(display:display,including:[window]);filter.includeMenuBar=false
    guard filter.includedWindows.count==1,filter.includedWindows[0].windowID==window.windowID else{throw Refusal("filterIsNotExactWindow")}
    let scale=Int(filter.pointPixelScale)
    guard (1...4).contains(scale),Float(scale)==filter.pointPixelScale else{throw Refusal("unknownPhysicalScale")}
    let config=SCStreamConfiguration()
    config.sourceRect=area.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
    config.width=Int(area.width)*scale;config.height=Int(area.height)*scale
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=CGColorSpace.sRGB
    config.showsCursor=false;config.capturesAudio=false;config.captureMicrophone=false;config.includeChildWindows=false
    let began=captureUptime(), sample=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter, configuration:config)
    let info=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
    let status=(info?[.status] as? NSNumber)?.intValue
    guard status==nil || status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue,
          CMSampleBufferIsValid(sample),CMSampleBufferDataIsReady(sample),let image=CMSampleBufferGetImageBuffer(sample),
          CVPixelBufferGetWidth(image)==config.width,CVPixelBufferGetHeight(image)==config.height,
          CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw Refusal("actualImageUnavailable")}
    defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
    guard let address=CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to:UInt8.self) else{throw Refusal("emptyFrame")}
    var pixels=Data(capacity:4*config.width*config.height)
    for y in 0..<config.height {pixels.append(address.advanced(by:y*CVPixelBufferGetBytesPerRow(image)),count:4*config.width)}
    return ImageRead(pixels:pixels,width:config.width,height:config.height,area:area,scale:scale,start:began,end:captureUptime())
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
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL, parent=folder.deletingLastPathComponent()
        guard UUID(uuidString:folder.lastPathComponent) != nil,parent.lastPathComponent.hasPrefix("nearpane-preview-pair."),
              parent.deletingLastPathComponent().path=="/private/tmp" else{throw Refusal("invalidSessionFolder")}
        for u in [parent,folder] {
            var s=stat();guard lstat(u.path,&s)==0,s.st_uid==getuid(),s.st_mode & 0o177777 == 0o40700 else{throw Refusal("unownedSessionFolder")}
        }
        let r=try dictionary(FileHandle.standardInput.readDataToEndOfFile())
        guard r["ready"] as? Bool==true,let host=r["hostPID"] as? pid_t,let h=r["hostHash"] as? String,
              let hostBirth=r["hostBirth"] as? UInt64,let fixture=r["fixturePID"] as? pid_t,let born=r["fixtureBirth"] as? UInt64,let f=r["fixtureHash"] as? String,
              let ids=r["numbers"] as? [UInt32],ids.count==2,Set(ids).count==2,let panel=r["panel"] as? UInt32,
              let sid=r["space"] as? UInt64,let displayID=r["display"] as? String,let sources=r["sources"] as? [[Double]],sources.count==2,
              r["kinds"] as? [String]==["窗口画面","窗口画面"],r["present"] as? [Bool]==[true,true] else {throw Refusal("twoLiveProductCardsRequired")}
        let kit=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
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
            guard p.terminationStatus==0,fresh["ready"] as? Bool==true,sameBinding(fresh,r),let overview=fresh["overview"] as? Row else{
                throw Refusal("signedWindowCardOrDesktopBindingChanged")
            }
            guard overview["ready"] as? Bool==true else{throw Refusal(overview["reason"] as? String ?? "unconfirmedCardRegion")}
            return overview
        }
        let initial=try confirm()
        guard let coordinates=initial["crop"] as? [Double],let pictureRects=initial["previews"] as? [[Double]],pictureRects.count==2 else{throw Refusal("missingReadableGeometry")}
        let crop=try rect(coordinates), areas=try sources.map(rect)
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
        guard NSDictionary(dictionary:initial).isEqual(to:try confirm()) else{throw Refusal("captureAdmissionChanged")}
        let bindingBefore=captureUptime()
        async let a=snap(display:display,window:w0,area:areas[0])
        async let b=snap(display:display,window:w1,area:areas[1])
        async let picture=snap(display:display,window:wp,area:crop)
        let (left,right,raw)=try await (a,b,picture)
        let sourceEpochs=try [left.marker(areas[0],document:0),right.marker(areas[1],document:1)]
        var cardEpochs=[Int]()
        for (i, coords) in pictureRects.enumerated() {
            let p=try rect(coords)
            // Use a substantial interior below the synthetic window's title bar.
            let body=CGRect(x:p.minX+p.width*0.12,y:p.minY+p.height*0.38,width:p.width*0.76,height:p.height*0.48)
            cardEpochs.append(try raw.marker(body,document:i))
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
                "sourceDocumentsEmpty":true,"otherControlsInCrop":0,"otherNonDesktopSurfacesInCrop":0]
    }
}
#endif
