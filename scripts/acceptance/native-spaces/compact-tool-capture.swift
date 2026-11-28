import Foundation
#if !COMPACT_TOOL_TEST
import AppKit
import CoreMedia
import CryptoKit
import ScreenCaptureKit
import Security

private struct Refusal: Error { let reason:String; init(_ reason:String){self.reason=reason} }
private typealias Row=[String:Any]
private struct Binding:Decodable { let pid:pid_t,birth:UInt64,hash:String,panel:UInt32,display:String,space:UInt64,spaceUUID:String }
private struct FixedPanel:Equatable {let rect:CGRect,hid:[UInt32],controls:[String:Int]}
private let labels:Set<String> = ["点播放按钮开始收音","复制当前文字","开始或恢复收音","展开截图方式","文件拖放区","截图与文件托盘","暂停","待命"]
private let necessary=["voice-capture-toggle","tray-content","tray-camera-entry","tray-file-drop"]
private func attr(_ el:AXUIElement,_ key:String)->CFTypeRef? {
    var raw:CFTypeRef?
    return AXUIElementCopyAttributeValue(el,key as CFString,&raw) == .success ? raw:nil
}
private func isolatedWriter(_ pid:pid_t) -> Bool {
    guard let text=ProcessInfo.processInfo.environment["NEARPANE_TEST_HOME"] else{return false}
    let home=URL(fileURLWithPath:text), parent=home.deletingLastPathComponent()
    guard home.lastPathComponent=="home",parent.lastPathComponent.hasPrefix("nearpane-native-acceptance."),
          let user=getpwuid(getuid())?.pointee.pw_dir,
          parent.deletingLastPathComponent().path==String(cString:user)+"/Library/Caches",
          home.resolvingSymlinksInPath().standardizedFileURL==home.standardizedFileURL else{return false}
    for url in [parent,home] {var s=stat();guard lstat(url.path,&s)==0,s.st_uid==getuid(),s.st_mode & 0o177777 == 0o40700 else{return false}}
    let p=Process(),pipe=Pipe()
    p.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
    p.arguments=["-a","-p",String(pid),"-t",home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles/writer.lock").path]
    p.standardOutput=pipe
    guard (try? p.run()) != nil else{return false}
    let result=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
    return p.terminationStatus==0 && String(decoding:result,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)==String(pid)
}
private func hostWindow(_ r:Binding)throws->FixedPanel {
    guard isolatedWriter(r.pid) else{throw Refusal("isolatedProfileWriterUnverified")}
    var path=[CChar](repeating:0,count:4096),bsd=proc_bsdinfo()
    let size=Int32(MemoryLayout.size(ofValue:bsd))
    var guest:SecCode?,disk:SecStaticCode?,info:CFDictionary?,req:SecRequirement?
    guard proc_pidpath(r.pid,&path,UInt32(path.count))>0,String(cString:path)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
          proc_pidinfo(r.pid,PROC_PIDTBSDINFO,0,&bsd,size)==size,bsd.pbi_uid==getuid(),bsd.pbi_pid==UInt32(r.pid),
          bsd.pbi_start_tvsec*1_000_000+bsd.pbi_start_tvusec==r.birth,
          SecRequirementCreateWithString("identifier \"com.holdsnow.nearpane.alpha\"" as CFString,[],&req)==errSecSuccess,let req,
          SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:r.pid] as CFDictionary,[],&guest)==errSecSuccess,let guest,
          SecCodeCheckValidity(guest,[],req)==errSecSuccess,SecCodeCopyStaticCode(guest,[],&disk)==errSecSuccess,let disk,
          SecCodeCopySigningInformation(disk,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
          let hash=(info as? Row)?[kSecCodeInfoUnique as String] as? Data,hash.map({String(format:"%02x",$0)}).joined()==r.hash else{throw Refusal("installedHostChanged")}
    guard AXIsProcessTrusted(),CGPreflightScreenCaptureAccess(),let console=CGSessionCopyCurrentDictionary() as? Row,
          console[kCGSessionOnConsoleKey as String] as? Bool==true,console[kCGSessionUserIDKey as String] as? UInt32==getuid(),
          console["CGSSessionScreenIsLocked"] as? Bool != true,NSEvent.pressedMouseButtons==0,
          let flag=CFPreferencesCopyAppValue("GloballyEnabled" as CFString,"com.apple.WindowManager" as CFString),
          CFGetTypeID(flag)==CFBooleanGetTypeID(),flag as? Bool==true else{throw Refusal("stageManagerOrCapturePermissionUnavailable")}
    guard NPReadOnlySpacesOpen()==1,let inv=NPReadInventory() as? [Row],inv.count==1,
          inv[0]["Display Identifier"] as? String==r.display,(inv[0]["Current Space"] as? Row)?["id64"] as? UInt64==r.space,
          (inv[0]["Spaces"] as? [Row])?.filter({$0["id64"] as? UInt64==r.space && $0["type"] as? Int==0 && ($0["uuid"] as? String)?.uppercased()==r.spaceUUID.uppercased()}).count==1,
          let inventory=NPContractMemberReport([NSNumber(value:r.space)] as CFArray,r.pid) as? [String:Row],
          let census=inventory[String(r.space)],census["unresolved"] as? Int==0,census["otherMembers"] as? Int==0,
          let normal=census["ordinary"] as? [Row],normal.isEmpty else{throw Refusal("currentOrdinarySpaceIsNotProvenEmpty")}
    let os=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [Row]
    let own=os?.filter{$0[kCGWindowNumber as String] as? UInt32==r.panel && $0[kCGWindowOwnerPID as String] as? Int32==r.pid &&
                      $0[kCGWindowLayer as String] as? Int==Int(CGWindowLevelForKey(.floatingWindow))}
    guard let own,own.count==1,let box=own[0][kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:box),
          let screen=NSScreen.screens.first,NSScreen.screens.count==1,
          let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,CGDisplayBounds(id).contains(rect),
          rect.width>=30,rect.height>=30,rect.width<=CGDisplayBounds(id).width*0.5,rect.height<screen.visibleFrame.height*0.66 else{throw Refusal("windowIsNotOneCompactVisiblePanel")}
    // isOnScreen alone allows covered windows. Stop if another visible surface covers any part of the tool.
    for row in os ?? [] {
        if row[kCGWindowNumber as String] as? UInt32==r.panel {break}
        guard let b=row[kCGWindowBounds as String] as? NSDictionary,let frame=CGRect(dictionaryRepresentation:b),
              let alpha=row[kCGWindowAlpha as String] as? Double else{throw Refusal("occlusionOrderUnavailable")}
        let overlap=frame.intersection(rect)
        guard alpha<=0 || overlap.isNull || overlap.width<=0 || overlap.height<=0 else{throw Refusal("compactWindowOccluded")}
    }
    let app=AXUIElementCreateApplication(r.pid);_=AXUIElementSetMessagingTimeout(app,0.25)
    let windows=(attr(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter{NPReadAXWindowNumber($0)==r.panel}
    guard windows.count<=1 else{throw Refusal("ambiguousAXWindow")}
    var window=windows.first
    if window==nil {
        // A nonactivating panel is sometimes omitted by AXWindows. An exact hit, owned parent
        // chain and independent CGWindowID prove the same window without activating it.
        for fraction in [0.25,0.5,0.75] where window==nil {
            var hit:AXUIElement?
            guard AXUIElementCopyElementAtPosition(app,Float(rect.midX),Float(rect.minY+rect.height*fraction),&hit) == .success,var node=hit else{continue}
            for _ in 0..<32 {
                var owner:pid_t=0
                guard AXUIElementGetPid(node,&owner) == .success,owner==r.pid else{break}
                if attr(node,kAXRoleAttribute) as? String==kAXWindowRole {
                    if NPReadAXWindowNumber(node)==r.panel {window=node}
                    break
                }
                guard let parent=attr(node,kAXParentAttribute), CFGetTypeID(parent)==AXUIElementGetTypeID() else{break}
                node=parent as! AXUIElement
            }
        }
    }
    guard let window else{throw Refusal("exactHostAXWindowUnavailable")}
    var visited=Set<AXUIElement>(),controls=[String:Int](),fixed=Set<String>()
    func inspect(_ el:AXUIElement,depth:Int)throws {
        guard depth<35,visited.count<400,visited.insert(el).inserted else{throw Refusal("ambiguousWindowSubtree")}
        var pid:pid_t=0
        guard AXUIElementGetPid(el,&pid) == .success,pid==r.pid,let role=attr(el,kAXRoleAttribute) as? String else{throw Refusal("unknownToolOwnerOrRole")}
        let id=attr(el,kAXIdentifierAttribute) as? String ?? ""
        if necessary.contains(id){controls[id,default:0]+=1}
        if id.hasPrefix("current-desktop-window") || id.hasPrefix("native-space-") || id.hasPrefix("split-view-member") ||
           id.hasPrefix("tray-saved-file") || id=="desktop-reserved-region" ||
           ["AXTextArea","AXTextField","AXWebArea","AXTable","AXDocument"].contains(role){throw Refusal("unexpectedContentInToolWindow")}
        if depth>0 {
            for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute] {
                if let v=attr(el,key) as? String,!v.isEmpty {
                    guard labels.contains(v) else{throw Refusal("nonFixtureTextInIsolatedToolWindow")};fixed.insert(v)
                }
            }
        }
        for child in attr(el,kAXChildrenAttribute) as? [AXUIElement] ?? []{try inspect(child,depth:depth+1)}
    }
    try inspect(window,depth:0)
    guard necessary.allSatisfy({controls[$0]==1}),fixed.contains("开始或恢复收音"),fixed.contains("展开截图方式"),fixed.contains("文件拖放区") else{throw Refusal("closedTrayOrIdleVoiceUnconfirmed")}
    let input=[CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map{CGEventSource.counterForEventType(.hidSystemState,eventType:$0)}
    return FixedPanel(rect:rect,hid:input,controls:controls)
}
#endif
func actualPanelInk(_ data:Data,width:Int,height:Int)->(Int,Int)? {
    guard width>0,height>0,data.count==4*width*height else{return nil}
    return data.withUnsafeBytes { raw in
        let bytes=raw.bindMemory(to:UInt8.self)
        var lo=255,hi=0,opaque=0
        for n in stride(from:0,to:data.count,by:4) {
            if bytes[n+3]==255 {
                opaque+=1
                let value=(29*Int(bytes[n])+150*Int(bytes[n+1])+77*Int(bytes[n+2])) >> 8
                lo=min(lo,value);hi=max(hi,value)
            }
        }
        return opaque==width*height && hi-lo>=48 ? (lo,hi):nil
    }
}
#if !COMPACT_TOOL_TEST
@main struct CompactToolCapture {
    static func main() async {
        do {
            let r=try JSONDecoder().decode(Binding.self,from:FileHandle.standardInput.readDataToEndOfFile())
            let before=try hostWindow(r)
            let sc=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            let matching=sc.windows.filter{$0.windowID==r.panel && $0.owningApplication?.processID==r.pid && $0.owningApplication?.bundleIdentifier=="com.holdsnow.nearpane.alpha" && $0.isOnScreen && $0.frame==before.rect}
            guard matching.count==1 else{throw Refusal("exactShareableInstalledWindowUnavailable")}
            let filter=SCContentFilter(desktopIndependentWindow:matching[0])
            guard filter.style == .window,filter.includedWindows.count==1,filter.includedWindows.first?.windowID==r.panel, filter.contentRect.size==before.rect.size else{throw Refusal("independentWindowFilterUnconfirmed")}
            let scale=Int(filter.pointPixelScale);guard (1...4).contains(scale),Float(scale)==filter.pointPixelScale else{throw Refusal("unknownBackingScale")}
            let config=SCStreamConfiguration()
            config.width=Int((before.rect.width*CGFloat(scale)).rounded());config.height=Int((before.rect.height*CGFloat(scale)).rounded())
            config.showsCursor=false;config.includeChildWindows=false;config.capturesAudio=false;config.captureMicrophone=false
            config.ignoreShadowsSingleWindow=true;config.ignoreGlobalClipSingleWindow=true
            // ScreenCaptureKit supplies white for native transparency in an independent window. No display filter is created.
            config.shouldBeOpaque=true;config.colorSpaceName=CGColorSpace.sRGB;config.pixelFormat=kCVPixelFormatType_32BGRA
            guard try hostWindow(r)==before else{throw Refusal("scopeChangedBeforeRead")}
            let start=ProcessInfo.processInfo.systemUptime
            let sample=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:config)
            let end=ProcessInfo.processInfo.systemUptime
            let attachments=(CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first
            let status=(attachments?[.status] as? NSNumber)?.intValue
            guard status==nil || status==SCFrameStatus.complete.rawValue || status==SCFrameStatus.started.rawValue,
                  CMSampleBufferIsValid(sample),CMSampleBufferDataIsReady(sample),let image=CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,CVPixelBufferGetWidth(image)==config.width,CVPixelBufferGetHeight(image)==config.height,
                  CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw Refusal("noActualWindowFrame")}
            defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
            guard let address=CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to:UInt8.self) else{throw Refusal("emptyFrame")}
            var pixels=Data(capacity:config.width*config.height*4)
            for y in 0..<config.height {pixels.append(address.advanced(by:y*CVPixelBufferGetBytesPerRow(image)),count:config.width*4)}
            guard let contrast=actualPanelInk(pixels,width:config.width,height:config.height) else{throw Refusal("blankOrUnresolvedWindowPixels")}
            guard try hostWindow(r)==before else{throw Refusal("scopeChangedDuringRead")}
            let png=try ImageRead(pixels:pixels,width:config.width,height:config.height,area:before.rect,scale:scale,start:start,end:end).png()
            let evidence:Row=["status":"CAPTURED","pid":r.pid,"birth":r.birth,"hash":r.hash,"panel":r.panel,"display":r.display,"space":r.space,"spaceUUID":r.spaceUUID,
                "width":config.width,"height":config.height,"scale":scale,"filter":"desktopIndependentWindow","includedWindowCount":1,
                "nativeTransparencyBacking":"solidWhite","controls":before.controls,"lumaRange":[contrast.0,contrast.1],"sampleUptime":[start,end],
                "sha256":SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),"png":png.base64EncodedString()]
            print(String(decoding:try JSONSerialization.data(withJSONObject:evidence),as:UTF8.self))
        } catch {
            let reason=(error as? Refusal)?.reason ?? "systemReadFailed"
            print("{\"status\":\"BLOCKED\",\"reason\":\"\(reason)\"}")
        }
    }
}
#endif
