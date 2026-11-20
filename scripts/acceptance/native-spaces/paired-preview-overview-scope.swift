// Used only by the optional, one-frame shareable evidence capture.
func pairedOverviewScope(_ index: Sidebar, region: AXUIElement, regionFrame: CGRect, panel: UInt32,
                         display: String, space: UInt64, ids: [String], windows: [UInt32],
                         fixture: pid_t, hostPID: pid_t, pictures: [[Double]], geometry:[Object]) -> Object {
    func stop(_ reason: String) -> Object { ["ready": false, "reason": reason] }
    guard ids.count == 2, pictures.count == 2, let owned = ProcessInfo.processInfo.environment["NEARPANE_TEST_HOME"] else {
        return stop("isolatedProfileMissing")
    }
    let home = URL(fileURLWithPath: owned), container = home.deletingLastPathComponent()
    guard home.lastPathComponent == "home", container.lastPathComponent.hasPrefix("nearpane-native-acceptance."),
          container.deletingLastPathComponent().lastPathComponent == "Caches",
          home.resolvingSymlinksInPath().standardizedFileURL == home.standardizedFileURL else { return stop("isolatedHomeUnavailable") }
    for url in [home,container] {
        var s = stat()
        guard lstat(url.path,&s) == 0, s.st_uid == getuid(), s.st_mode & 0o177777 == 0o40700 else { return stop("isolatedHomeOwnership") }
    }
    let lock = home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles/writer.lock")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath:"/usr/sbin/lsof")
    process.arguments = ["-a","-p",String(hostPID),"-t",lock.path]
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return stop("isolatedLockUnavailable") }
    let observed = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          Int32(String(decoding: observed,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) == hostPID else {
        return stop("installedHostDoesNotOwnIsolatedLock")
    }
    func frame(_ node: AXUIElement) -> CGRect? {
        guard let p=value(node,kAXPositionAttribute),let s=value(node,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&origin), AXValueGetValue(s as! AXValue,.cgSize,&size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin:origin,size:size)
    }
    func numbers(_ rect: CGRect) -> [Double] { [rect.minX,rect.minY,rect.width,rect.height] }
    let expected = Set(ids), fixed = Set(["Field Notes · 1","Field Notes · 2"])
    var captions = Set<String>(), cardFrames = [CGRect](), previews = [CGRect]()
    guard geometry.count==ids.count else{return stop("enrolledCardGeometryUnavailable")}
    for (i,id) in ids.enumerated() {
        guard let card=index.controls[id]?.first,geometry[i]["panelBound"] as? Bool==true,geometry[i]["geometryReady"] as? Bool==true,
              let coords=geometry[i]["frame"] as? [Double],coords.count==4,let body=geometry[i]["pictureFrame"] as? [Double],body.count==4
        else{return stop("boundedCardFrameUnavailable")}
        let rect=CGRect(x:coords[0],y:coords[1],width:coords[2],height:coords[3])
        guard regionFrame.contains(rect),rect.width>=25,rect.height>=25 else{return stop("completeCardFrameNotVisible")}
        let labels=Set([kAXTitleAttribute,kAXDescriptionAttribute].compactMap{value(card,$0) as? String}.filter{!$0.isEmpty})
        guard labels.count==1,labels.isSubset(of:fixed) else{return stop("fixedFixtureCaptionUnconfirmed")}
        captions.formUnion(labels);cardFrames.append(rect)
        var picture=CGRect(x:body[0],y:body[1],width:body[2],height:body[3])
        if let info=geometry[i]["axValue"] as? Object,let size=info["declaredPreviewPoints"] as? [Double],size.count==2,
           size[0]>=12,size[1]>=12,size[0]<=rect.width+1,size[1]<=rect.height-10 {
            picture=CGRect(x:rect.midX-size[0]/2,y:rect.minY,width:size[0],height:size[1])
        }
        guard picture.width>=12,picture.height>=12,rect.contains(picture) else{return stop("cardPictureBoundsUnavailable")}
        previews.append(picture)
    }
    let ordered=cardFrames.sorted { $0.minY < $1.minY }
    guard captions == fixed, !ordered[0].intersects(ordered[1]), ordered[1].minY-ordered[0].maxY <= 18,
          abs(ordered[0].minX-ordered[1].minX)<=1, abs(ordered[0].maxX-ordered[1].maxX)<=1 else {
        return stop("twoAdjacentFixedCaptionCardsRequired")
    }
    let box=ordered[0].union(ordered[1])
    // Round towards the inside of the actual two rows. Do not include the surrounding sidebar modules.
    let crop=CGRect(x:ceil(box.minX),y:ceil(box.minY),width:floor(box.maxX)-ceil(box.minX),height:floor(box.maxY)-ceil(box.minY))
    guard crop.width >= 25,crop.width<=450,crop.height<=650,regionFrame.contains(crop) else{return stop("unboundedCardUnion")}
    var seen = Set<AXUIElement>(), found = Set<String>()
    func onlyCards(_ node:AXUIElement, depth:Int) -> Bool {
        guard depth<32,seen.count<350,seen.insert(node).inserted else{return false}
        if let rect=frame(node), !rect.intersects(crop) {return true}
        var owner:pid_t=0
        guard AXUIElementGetPid(node,&owner) == .success,owner==hostPID else{return false}
        if let id=value(node,kAXIdentifierAttribute) as? String,expected.contains(id) {return found.insert(id).inserted}
        guard let role=value(node,kAXRoleAttribute) as? String,
              ["AXGroup","AXScrollArea","AXList","AXLayoutArea","AXSplitGroup","AXUnknown"].contains(role),
              let children=value(node,kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty else { return false }
        return children.allSatisfy { onlyCards($0,depth:depth+1) }
    }
    guard onlyCards(region,depth:0),found==expected else { return stop("otherOrUnresolvedHostContentInCardCrop") }
    func permitsWallpaper(_ pid:pid_t,level:Int) -> Bool {
        let desktop=Int(CGWindowLevelForKey(.desktopWindow))
        let identifier:String, expectedPath:String
        switch level {
        case desktop-2:
            identifier="com.apple.wallpaper.agent";expectedPath="/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
        case desktop-3:
            identifier="com.apple.WindowServer";expectedPath="/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
        default: return false
        }
        var path=[CChar](repeating:0,count:4096),code:SecCode?,requirement:SecRequirement?
        let rule = "anchor apple and identifier \"" + identifier + "\""
        return proc_pidpath(pid,&path,UInt32(path.count))>0 && String(cString:path)==expectedPath &&
            SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess &&
            SecRequirementCreateWithString(rule as CFString,[],&requirement)==errSecSuccess &&
            code.map { guest in requirement.map { SecCodeCheckValidity(guest,[],$0)==errSecSuccess } ?? false } == true
    }
    guard let displayBounds=NSScreen.screens.first.flatMap({ screen -> CGRect? in
        guard let n=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else{return nil}
        return CGDisplayBounds(n)
    }),displayBounds.contains(crop),
          let rows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Object] else{return stop("onscreenWindowOrderUnavailable")}
    var foundPanel=false
    for row in rows {
        guard let bounds=row[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:bounds),
              let alpha=row[kCGWindowAlpha as String] as? Double,let pid=row[kCGWindowOwnerPID as String] as? pid_t,
              let num=row[kCGWindowNumber as String] as? UInt32 else{return stop("unknownOnscreenWindow")}
        guard alpha>0,rect.intersects(crop) else{continue}
        if num==panel && pid==hostPID {guard !foundPanel,rect.contains(crop) else{return stop("ambiguousHostSurface")}; foundPanel=true;continue}
        // A backdrop may contribute to a material even through a single-window filter.
        // Include desktop elements in this check so Finder icon labels cannot slip through.
        guard foundPanel else{return stop("otherSurfaceOccludesHost")}
        if pid==fixture,windows.contains(num){continue}
        guard let level=row[kCGWindowLayer as String] as? Int,alpha>=0.999,rect==displayBounds,
              permitsWallpaper(pid,level:level) else{return stop("unrelatedOnscreenSurfaceAtCrop")}
    }
    guard foundPanel else{return stop("hostPanelMissingFromWindowOrder")}
    let hid: [UInt32] = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
    guard NSEvent.pressedMouseButtons == 0 else{return stop("activeMouseInput")}
    return ["ready":true,"isolatedProfile":true,"cardIDs":ids,"fixedCaptions":captions.sorted(),
            "cards":cardFrames.map(numbers),"previews":previews.map(numbers),"crop":numbers(crop),
            "display":display,"space":space,"hid":hid,"otherControlsInCrop":0,"otherNonDesktopSurfacesInCrop":0]
}
