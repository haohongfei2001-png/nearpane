// Used only by the optional, one-frame shareable evidence capture.
func pairedOverviewScope(_ index: Sidebar, region: AXUIElement, regionFrame: CGRect, panel: UInt32,
                         display: String, space: UInt64, ids: [String], windows: [UInt32],
                         fixture: pid_t, hostPID: pid_t, pictures: [[Double]]) -> Object {
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
    for id in ids {
        guard let card = index.controls[id]?.first, value(card,kAXRoleAttribute) as? String == "AXButton",
              let rect=frame(card), regionFrame.contains(rect), rect.width >= 25, rect.height >= 25,
              let text=value(card,kAXValueAttribute) as? String, text.hasPrefix("窗口画面，预览 "),
              let delimiter=text.range(of:" pt") else { return stop("liveCardFrameUnavailable") }
        let labels = Set([kAXTitleAttribute,kAXDescriptionAttribute].compactMap { value(card,$0) as? String }.filter { !$0.isEmpty })
        guard labels.count == 1, labels.isSubset(of:fixed) else { return stop("fixedFixtureCaptionUnconfirmed") }
        captions.formUnion(labels)
        let size=text[text.index(text.startIndex,offsetBy:"窗口画面，预览 ".count)..<delimiter.lowerBound].components(separatedBy:" × ")
        guard size.count == 2, let w=Double(size[0]),let h=Double(size[1]),w>=12,h>=12,
              w<=rect.width+1,h<=rect.height-10 else { return stop("cardPictureBoundsUnavailable") }
        cardFrames.append(rect);previews.append(CGRect(x:rect.midX-w/2,y:rect.minY,width:w,height:h))
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
