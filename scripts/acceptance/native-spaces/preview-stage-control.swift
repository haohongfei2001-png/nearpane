// Temporary Stage Manager setup for this acceptance only. No preference writes or global input.
import AppKit
import ApplicationServices
import Security

private typealias Facts = [String:Any]
private let settings = "/System/Applications/System Settings.app"
private let executable = settings + "/Contents/MacOS/System Settings"
private let settingsID = "com.apple.systempreferences"
private let extensionPath = "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex/Contents/MacOS/DesktopSettings"
private let switchID = "stage-manager-on"
private struct Stop: Error { let reason:String; init(_ reason:String) { self.reason=reason } }
private func check(_ value:Bool,_ reason:String) throws { if !value { throw Stop(reason) } }
private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func emit(_ facts:Facts) {
    guard let data=try? JSONSerialization.data(withJSONObject:facts,options:.sortedKeys) else {return}
    FileHandle.standardOutput.write(data+Data([10]))
    try? FileHandle.standardOutput.synchronize()
}
private func loginState() throws -> Bool {
    var console=stat()
    guard let user=getpwuid(getuid()),let home=user.pointee.pw_dir,
          ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]==nil,
          NSHomeDirectory()==String(cString:home),stat("/dev/console",&console)==0,console.st_uid==getuid(),
          let session=CGSessionCopyCurrentDictionary() as? Facts,
          session[kCGSessionOnConsoleKey as String] as? Bool==true,
          session[kCGSessionLoginDoneKey as String] as? Bool==true,
          session[kCGSessionUserIDKey as String] as? NSNumber==NSNumber(value:getuid()),
          session["CGSSessionScreenIsLocked"] as? Bool != true else {throw Stop("actualUnlockedConsoleLoginUnverified")}
    guard let value=CFPreferencesCopyAppValue("GloballyEnabled" as CFString,"com.apple.WindowManager" as CFString),
          CFGetTypeID(value)==CFBooleanGetTypeID(),let state=value as? Bool else {throw Stop("actualLoginHasNoBooleanStageManagerValue")}
    return state
}
private func kernelPath(_ pid:pid_t) -> String? {
    var path=[CChar](repeating:0,count:4096)
    return proc_pidpath(pid,&path,UInt32(path.count))>0 ? String(cString:path):nil
}
private func birth(_ pid:pid_t) -> UInt64? {
    var info=proc_bsdinfo();let size=Int32(MemoryLayout.size(ofValue:info))
    guard pid>1,proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size,info.pbi_pid==UInt32(pid),
          info.pbi_uid==getuid(),info.pbi_start_tvsec>0 else {return nil}
    return info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec
}
private func settingsPIDs() throws -> [pid_t] {
    let estimate=proc_listallpids(nil,0)
    try check(estimate>0 && estimate<100_000,"kernelProcessCensusUnavailable")
    var pids=[pid_t](repeating:0,count:Int(estimate)+256)
    let n=proc_listallpids(&pids,Int32(pids.count*MemoryLayout<pid_t>.stride))
    try check(n>0 && n<pids.count,"kernelProcessCensusWasTruncated")
    return pids.prefix(Int(n)).filter { birth($0) != nil && kernelPath($0)==executable }
}
private func signedHash(_ pid:pid_t,_ identifier:String, apple:Bool) throws -> String {
    let condition=(apple ? "anchor apple and " : "")+"identifier \""+identifier+"\""
    var req:SecRequirement?, code:SecCode?, disk:SecStaticCode?, info:CFDictionary?
    guard SecRequirementCreateWithString(condition as CFString,[],&req)==errSecSuccess,let req,
          SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess,let code,
          SecCodeCheckValidity(code,[],req)==errSecSuccess,SecCodeCopyStaticCode(code,[],&disk)==errSecSuccess,let disk,
          SecCodeCopySigningInformation(disk,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
          let hash=(info as? Facts)?[kSecCodeInfoUnique as String] as? Data else {throw Stop("liveCodeIdentityUnavailable")}
    return hash.map {String(format:"%02x",$0)}.joined()
}
private struct Request: Decodable {
    let targetState:Bool, expectedState:Bool, display:String, space:UInt64, spaceUUID:String
    let hostPID:pid_t,hostBirth:UInt64,hostHash:String,hid:[UInt32]
    func quiet(_ counters:[UInt32])->Request {
        Request(targetState:targetState,expectedState:expectedState,display:display,space:space,spaceUUID:spaceUUID,
                hostPID:hostPID,hostBirth:hostBirth,hostHash:hostHash,hid:counters)
    }
}
private func hardware()->[UInt32] {
    [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map {CGEventSource.counterForEventType(.hidSystemState,eventType:$0)}
}
private func inputDelta(_ a:[UInt32],_ b:[UInt32])->[String:UInt32] {
    let names=["leftDown","rightDown","otherDown","keyDown","scroll"]
    return Dictionary(uniqueKeysWithValues:zip(names,zip(a,b)).map{($0.0,$0.1.1 &- $0.1.0)})
}
private func eventCounts()->Facts {
    let events:[(String,CGEventType)]=[("leftDown",.leftMouseDown),("rightDown",.rightMouseDown),("otherDown",.otherMouseDown),
        ("keyDown",.keyDown),("scroll",.scrollWheel),("pointerMoved",.mouseMoved),("leftDragged",.leftMouseDragged)]
    func counts(_ source:CGEventSourceStateID)->[String:UInt32] {
        Dictionary(uniqueKeysWithValues:events.map{($0.0,CGEventSource.counterForEventType(source,eventType:$0.1))})
    }
    return ["hid":counts(.hidSystemState),"session":counts(.combinedSessionState),"uptime":now()]
}
private func scope(_ r:Request,allow pid:pid_t?=nil,forInput:Bool=true,knownWindow:UInt32?=nil) throws -> [UInt32] {
    _ = try loginState()
    if forInput {
        let actual=hardware()
        if actual != r.hid || NSEvent.pressedMouseButtons != 0 {
            emit(["event":"input-change-before-action","delta":inputDelta(r.hid,actual),"buttonsDown":NSEvent.pressedMouseButtons,"uptime":now()])
            throw Stop("physicalInputChanged")
        }
    }
    try check(AXIsProcessTrusted() && CGPreflightScreenCaptureAccess(),"observerPermissionsUnavailable")
    try check(birth(r.hostPID)==r.hostBirth && kernelPath(r.hostPID)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost","installedHostGenerationChanged")
    try check(try signedHash(r.hostPID,"com.holdsnow.nearpane.alpha",apple:false)==r.hostHash,"installedHostSignatureChanged")
    guard NPReadOnlySpacesOpen()==1,let all=NPReadInventory() as? [Facts],all.count==1,
          all[0]["Display Identifier"] as? String==r.display,let current=all[0]["Current Space"] as? Facts,
          current["id64"] as? UInt64==r.space,
          let records=all[0]["Spaces"] as? [Facts],records.contains(where:{$0["id64"] as? UInt64==r.space && $0["type"] as? Int==0 && ($0["uuid"] as? String)?.uppercased()==r.spaceUUID.uppercased()})
    else {throw Stop("controlledOrdinarySpaceChanged")}
    let census=(NPContractMemberReport([NSNumber(value:r.space)] as CFArray,r.hostPID) as? [String:Facts])?[String(r.space)]
    if let census,census["unresolved"] as? Int==0,census["otherMembers"] as? Int==0,
       let windows=census["ordinary"] as? [[String:NSNumber]],windows.count<=1,
       windows.allSatisfy({pid != nil && $0["pid"]?.int32Value==pid && $0["number"] != nil}) {
        let actual=windows.compactMap{$0["number"]?.uint32Value}
        if knownWindow==nil || actual==knownWindow.map({[$0]}) {return actual}
    }
    // The system draws transient compositor surfaces while updating this pane. The
    // fallback only admits a previously identified single Apple Settings window with
    // positive forward/reverse membership and no other visible ordinary app.
    guard let pid,let n=knownWindow,NPReadWindowSpaces(n) as? [UInt64]==[r.space],
          (NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32])?.contains(n)==true,
          let visible=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [Facts] else {
        throw Stop("controlledDesktopEmptyOrSingleOwnedSettingsWindowUnverified")
    }
    var hits=0,compositor=0
    for row in visible {
        guard let owner=row[kCGWindowOwnerPID as String] as? pid_t,let id=row[kCGWindowNumber as String] as? UInt32,
              let level=row[kCGWindowLayer as String] as? Int else {throw Stop("visibleLayerIdentityUnavailable")}
        if id==n {try check(owner==pid && level==0,"registeredSettingsLayerChanged");hits+=1;continue}
        if level != 0 || owner==r.hostPID {continue}
        let path=kernelPath(owner)
        guard let entry=[("/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager","com.apple.WindowManager"),
                         ("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer","com.apple.WindowServer")].first(where:{$0.0==path}) else {
            throw Stop("otherVisibleOrdinaryApplicationDuringRegisteredSettingsAction")
        }
        _=try signedHash(owner,entry.1,apple:true);compositor+=1
    }
    try check(hits==1,"registeredWindowNotPhysicallyVisible")
    emit(["event":"registered-window-census","number":n,"signedCompositors":compositor,"registeredWindows":hits,"uptime":now()])
    return [n]
}
private func attr(_ item:AXUIElement,_ name:String) -> CFTypeRef? {
    var value:CFTypeRef?
    return AXUIElementCopyAttributeValue(item,name as CFString,&value) == .success ? value:nil
}
private func owner(_ item:AXUIElement) -> pid_t? {
    var pid:pid_t=0; return AXUIElementGetPid(item,&pid) == .success ? pid:nil
}
private func spin(_ seconds:Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
private struct OwnedSettings {
    let app:NSRunningApplication, pid:pid_t, generation:UInt64, hash:String
    func verify() throws {
        try check(birth(pid)==generation && kernelPath(pid)==executable && app.processIdentifier==pid,"ownedSettingsGenerationChanged")
        try check(try signedHash(pid,settingsID,apple:true)==hash,"appleSettingsSignatureChanged")
    }
    func quit(_ r:Request) throws {
        try verify()
        let current=hardware()
        if current != r.hid {
            // Re-arm only normal closure of our exact system pane; this is never used to reissue a toggle.
            let (first,w,_)=try control(r,forInput:false)
            spin(0.35)
            let (second,w2,_)=try control(r,forInput:false)
            try check(w==w2 && CFEqual(first,second) && hardware()==current && NSEvent.pressedMouseButtons==0,"newInputOrOwnedSystemPaneChangedBeforeClose")
            emit(["event":"quiet-owned-close","window":w,"deltaSinceSetup":inputDelta(r.hid,current),"uptime":now()])
        }
        let ax=AXUIElementCreateApplication(pid)
        let windows=attr(ax,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let known=windows.count==1 ? NPReadAXWindowNumber(windows[0]):nil
        _=try scope(r.quiet(current),allow:pid,knownWindow:known)
        try check(app.terminate(),"ownedSettingsNormalQuitRefused")
        let deadline=now()+4
        while birth(pid)==generation && now()<deadline {spin(0.08)}
        try check(birth(pid) != generation && (try settingsPIDs()).isEmpty,"ownedSettingsNormalQuitUnconfirmed")
        emit(["event":"owned-settings-closed","pid":pid,"uptime":now()])
    }
    func control(_ r:Request,forInput:Bool=true) throws -> (AXUIElement,UInt32,Bool) {
        try verify()
        let ax=AXUIElementCreateApplication(pid)
        _=AXUIElementSetMessagingTimeout(ax,0.30)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,
              let windows=attr(ax,kAXWindowsAttribute) as? [AXUIElement],windows.count==1,
              let w=windows.first,owner(w)==pid,attr(w,kAXModalAttribute) as? Bool != true else {throw Stop("ownedSettingsWindowNotFrontmostOrNotExclusivelyLeased")}
        let number=NPReadAXWindowNumber(w)
        let nums=try scope(r,allow:pid,forInput:forInput,knownWindow:number)
        guard number>0,nums==[number],NPReadWindowSpaces(number) as? [UInt64]==[r.space] else {throw Stop("ownedSettingsWindowMembershipUnavailable")}
        if forInput {
            guard let app=attr(AXUIElementCreateSystemWide(),kAXFocusedApplicationAttribute),CFGetTypeID(app)==AXUIElementGetTypeID(),
                  owner(app as! AXUIElement)==pid,let focused=attr(ax,kAXFocusedWindowAttribute),
                  CFGetTypeID(focused)==AXUIElementGetTypeID(),NPReadAXWindowNumber(focused as! AXUIElement)==number else {throw Stop("registeredApplePaneDoesNotOwnSystemFocus")}
        }
        var queue=[w],seen=Set<AXUIElement>(),matches=[AXUIElement]()
        let deadline=now()+2
        while let item=queue.popLast() {
            if !seen.insert(item).inserted {continue}
            try check(seen.count<=1600 && now()<deadline,"systemPaneAXTreeExceededBound")
            if attr(item,kAXIdentifierAttribute) as? String==switchID {matches.append(item)}
            // Titles, values and browsable text are never requested while finding the control.
            let role=attr(item,kAXRoleAttribute) as? String
            try check(role != kAXSheetRole,"systemPaneContainsConfirmationSheet")
            if ["AXTextArea","AXTextField","AXStaticText","AXWebArea","AXImage"].contains(role ?? "") {continue}
            queue.append(contentsOf:attr(item,kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        guard matches.count==1,let item=matches.first,let pidOfItem=owner(item),
              let role=attr(item,kAXRoleAttribute) as? String,["AXCheckBox","AXSwitch","AXToggle"].contains(role),
              attr(item,kAXEnabledAttribute) as? Bool==true,let state=attr(item,kAXValueAttribute) as? NSNumber,
              [0,1].contains(state.intValue),state.doubleValue==Double(state.intValue) else {throw Stop("uniqueEnabledStageManagerOnSwitchUnavailable")}
        if pidOfItem != pid {
            try check(kernelPath(pidOfItem)==extensionPath && birth(pidOfItem) != nil,"unknownSystemPaneSwitchOwner")
            _=try signedHash(pidOfItem,"com.apple.Desktop-Settings.extension",apple:true)
        }
        var actions:CFArray?
        try check(AXUIElementCopyActionNames(item,&actions) == .success && (actions as? [String])?.contains(kAXPressAction)==true,"systemSwitchHasNoPressAction")
        return (item,number,state.boolValue)
    }
}
private func freshLoginState() throws -> Bool {
    let child=Process(), output=Pipe()
    child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
    child.arguments=["state"];child.standardOutput=output
    try child.run();let data=output.fileHandleForReading.readDataToEndOfFile();child.waitUntilExit()
    guard child.terminationStatus==0,let obj=try JSONSerialization.jsonObject(with:data) as? Facts,
          obj["uid"] as? UInt32==getuid(),let value=obj["state"] as? Bool else {throw Stop("independentLoginReadUnavailable")}
    return value
}
private func corroborate(_ r:Request,_ app:OwnedSettings,expect:Bool,timeout:Double) throws -> (AXUIElement,UInt32) {
    let end=now()+timeout;var samples=0,last="noCompleteSystemPaneRead",previous:AXUIElement?,priorWindow:UInt32?
    while now()<end {
        do {
            let (element,window,toggle)=try app.control(r,forInput:false)
            let pref=try freshLoginState()
            emit(["event":"switch-read","window":window,"ui":toggle,"login":pref,"inputDelta":inputDelta(r.hid,hardware()),"eventCounts":eventCounts(),"uptime":now()])
            if toggle==expect && pref==expect {
                if let previous,CFEqual(previous,element),priorWindow==window,samples==1 {return(element,window)}
                samples=1;previous=element;priorWindow=window
            } else {samples=0;last="loginAndSystemSwitchHaveNotConverged"}
        } catch let e as Stop {samples=0;last=e.reason}
        spin(0.17)
    }
    throw Stop(last)
}
private func preparePress(_ r:Request,_ app:OwnedSettings,_ saved:AXUIElement,_ number:UInt32,expect:Bool) throws -> AXUIElement {
    let deadline=now()+1.8
    var last="enrolledSwitchNotReady"
    repeat {
        // Read-only retries may bridge WindowServer/AX reconstruction. Once a
        // new action-carrying input is observed no toggle can be dispatched.
        try check(r.hid==hardware() && NSEvent.pressedMouseButtons==0,"newInputBeforeSystemSwitch")
        do {
            let (item,w,value)=try app.control(r)
            try check(w==number && CFEqual(item,saved) && value==expect,"enrolledSwitchChangedBeforePress")
            try check(try freshLoginState()==expect,"systemLoginChangedBeforePress")
            try check(r.hid==hardware() && NSEvent.pressedMouseButtons==0,"newInputBeforeSystemSwitch")
            return item
        } catch let refusal as Stop {last=refusal.reason}
        spin(0.15)
    } while now()<deadline
    throw Stop(last)
}
private func transaction(_ r:Request) throws {
    try check(r.expectedState != r.targetState && UUID(uuidString:r.spaceUUID) != nil,"invalidRequestedTransition")
    _=try scope(r)
    try check(try freshLoginState()==r.expectedState,"unexpectedStageBeforeSetup")
    try check(try settingsPIDs().isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier:settingsID).isEmpty,"existingSettingsInstanceProtected")
    guard let url=URL(string:"x-apple.systempreferences:com.apple.Desktop-Settings.extension?stageManager") else {throw Stop("invalidSystemPaneURI")}
    let config=NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance=true;config.activates=true;config.addsToRecentItems=false;config.promptsUserIfNeeded=false
    config.arguments=["-ApplePersistenceIgnoreState","YES"]
    let earliest=UInt64(Date().timeIntervalSince1970*1_000_000)
    var launched:NSRunningApplication?, answered=false
    emit(["event":"opening-owned-settings","uptime":now()])
    NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:settings),configuration:config){app,_ in launched=app;answered=true}
    let end=now()+9
    while !answered && now()<end {spin(0.06)}
    // A missing callback cannot transfer ownership of an unrelated instance.
    guard let app=launched,let gen=birth(app.processIdentifier),gen>=earliest,
          kernelPath(app.processIdentifier)==executable,
          let hash=try? signedHash(app.processIdentifier,settingsID,apple:true),
          try settingsPIDs()==[app.processIdentifier] else {throw Stop("newAppleSettingsInstanceNotProven")}
    let owned=OwnedSettings(app:app,pid:app.processIdentifier,generation:gen,hash:hash)
    emit(["event":"owned-settings","pid":owned.pid,"birth":gen,"cdHash":hash,"uptime":now()])
    var error:Error?
    do {
        let (element,number)=try corroborate(r,owned,expect:r.expectedState,timeout:5)
        let fresh=try preparePress(r,owned,element,number,expect:r.expectedState)
        emit(["event":"press-intent","id":switchID,"target":r.targetState,"window":number,"eventCounts":eventCounts(),"uptime":now()])
        let result=AXUIElementPerformAction(fresh,kAXPressAction as CFString)
        emit(["event":"press-reply","ax":result.rawValue,"eventCounts":eventCounts(),"uptime":now()])
        _=try corroborate(r,owned,expect:r.targetState,timeout:5)
        try check(result == .success,"switchReplyAmbiguousDespiteReadback")
    } catch let cause {error=cause}
    do {
        try owned.quit(r)
    } catch let cleanup {
        emit(["event":"settings-cleanup-incomplete","reason":(cleanup as? Stop)?.reason ?? "normalQuitUnknown"])
        if error==nil {error=cleanup}
    }
    if let error {throw error}
}
private struct Recovery:Decodable {let request:Request, pid:pid_t, birth:UInt64, cdHash:String}
private struct Registered:Decodable {let request:Request,pid:pid_t,birth:UInt64,cdHash:String,window:UInt32}
private struct Inactive:Decodable {let request:Request,pid:pid_t,birth:UInt64,cdHash:String,window:UInt32,original:UInt64,originalUUID:String}
private func closeBackground(_ x:Inactive,inspect:Bool=false) throws {
    let r=x.request
    guard NPReadOnlySpacesOpen()==1,r.space != x.original,try freshLoginState(),try settingsPIDs()==[x.pid],let app=NSRunningApplication(processIdentifier:x.pid) else {throw Stop("restoredLoginAndOnlyRegisteredSettingsRequired")}
    let owned=OwnedSettings(app:app,pid:x.pid,generation:x.birth,hash:x.cdHash)
    let ax=AXUIElementCreateApplication(x.pid)
    var front:pid_t?
    for i in 0..<2 {
        if i>0 {spin(0.35)}
        try owned.verify()
        guard hardware()==r.hid,NSEvent.pressedMouseButtons==0,let current=NSWorkspace.shared.frontmostApplication?.processIdentifier,
              i==0 || current==front,let all=NPReadInventory() as? [Facts],all.count==1,all[0]["Display Identifier"] as? String==r.display,
              (all[0]["Current Space"] as? Facts)?["id64"] as? UInt64==x.original,
              let s=all[0]["Spaces"] as? [Facts],s.contains(where:{$0["id64"] as? UInt64==x.original && ($0["uuid"] as? String)?.uppercased()==x.originalUUID.uppercased()}),
              s.contains(where:{$0["id64"] as? UInt64==r.space && $0["type"] as? Int==0 && ($0["uuid"] as? String)?.uppercased()==r.spaceUUID.uppercased()}),
              let report=NPContractMemberReport([NSNumber(value:r.space)] as CFArray,r.hostPID) as? [String:Facts],
              let row=report[String(r.space)],row["unresolved"] as? Int==0,row["otherMembers"] as? Int==0,
              let w=row["ordinary"] as? [[String:NSNumber]],w.count==1,w[0]["pid"]?.int32Value==x.pid,w[0]["number"]?.uint32Value==x.window,
              birth(r.hostPID)==r.hostBirth,kernelPath(r.hostPID)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" else {throw Stop("inactiveRegisteredOwnedWindowOrForegroundUnverified")}
        let docs=attr(ax,kAXWindowsAttribute) as? [AXUIElement]
        guard let docs,docs.allSatisfy({owner($0)==x.pid && NPReadAXWindowNumber($0)==x.window}),docs.count<=1,
              NPReadWindowSpaces(x.window) as? [UInt64]==[r.space],
              (NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32])?.contains(x.window)==true,
              let rows=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [Facts]
        else {throw Stop("registeredInactivePublicWindowOrAXListUnavailable")}
        let own=rows.filter{$0[kCGWindowOwnerPID as String] as? pid_t==x.pid && $0[kCGWindowLayer as String] as? Int==0}
        var actual=0,unassignedBars=0
        for item in own {
            guard let num=item[kCGWindowNumber as String] as? UInt32,item[kCGWindowIsOnscreen as String] as? Bool != true,
                  let box=item[kCGWindowBounds as String] as? NSDictionary,let geometry=CGRect(dictionaryRepresentation:box) else {throw Stop("settingsHasVisibleUnregisteredUserWindow")}
            if num==x.window {actual+=1;continue}
            guard let membership=NPReadWindowSpaces(num) as? [UInt64],membership.isEmpty,
                  geometry.height>0,geometry.height<=48,geometry.width>=geometry.height*8 else {throw Stop("anotherAssignedSettingsWindowIsProtected")}
            unassignedBars+=1
        }
        try check(actual==1,"originalOwnedPublicWindowMissing")
        let system=AXUIElementCreateSystemWide(),focused=attr(system,kAXFocusedApplicationAttribute)
        let isFront=focused.map{CFGetTypeID($0)==AXUIElementGetTypeID() && owner($0 as! AXUIElement)==x.pid} ?? false
        let focusedWindow=attr(ax,kAXFocusedWindowAttribute)
        try check(!isFront || focusedWindow==nil,"registeredSettingsReceivedRealFocusedWindow")
        try check(try signedHash(r.hostPID,"com.holdsnow.nearpane.alpha",apple:false)==r.hostHash,"liveHostChanged")
        emit(["event":"inactive-window-read","pid":x.pid,"window":x.window,"current":x.original,"lease":r.space,
              "axWindowCount":docs.count,"unassignedOffscreenBars":unassignedBars,"systemFocusOnSettings":isFront,"uptime":now()])
        front=current
    }
    if inspect {return}
    try check(app.terminate(),"registeredBackgroundSettingsNormalTerminationRefused")
    let stop=now()+5
    while birth(x.pid)==x.birth && now()<stop{spin(0.08)}
    try check(birth(x.pid) != x.birth && (try settingsPIDs()).isEmpty && (try freshLoginState()),"registeredBackgroundSettingsExitUnconfirmed")
    emit(["event":"owned-settings-closed","pid":x.pid,"uptime":now()])
}

do {
    guard CommandLine.arguments.count==2 else {throw Stop("invalidMode")}
    if CommandLine.arguments[1]=="state" || CommandLine.arguments[1]=="preflight" {
        let value=try loginState()
        var result:Facts=["state":value,"uid":getuid(),"ax":AXIsProcessTrusted(),"screen":CGPreflightScreenCaptureAccess(),"uptime":now()]
        if CommandLine.arguments[1]=="preflight" {result["existingSettingsInstance"] = try !settingsPIDs().isEmpty || !NSRunningApplication.runningApplications(withBundleIdentifier:settingsID).isEmpty}
        emit(result)
    } else if CommandLine.arguments[1]=="switch" {
        let data=FileHandle.standardInput.readDataToEndOfFile()
        try transaction(JSONDecoder().decode(Request.self,from:data))
        emit(["event":"complete","uptime":now()])
    } else if CommandLine.arguments[1]=="close-owned" {
        let recovery=try JSONDecoder().decode(Recovery.self,from:FileHandle.standardInput.readDataToEndOfFile())
        if try settingsPIDs().isEmpty && birth(recovery.pid) != recovery.birth {
            _=try scope(recovery.request)
            emit(["event":"owned-settings-already-gone","pid":recovery.pid])
        } else {
            guard try settingsPIDs()==[recovery.pid],let app=NSRunningApplication(processIdentifier:recovery.pid) else {throw Stop("recoveryFoundDifferentSettingsGeneration")}
            try OwnedSettings(app:app,pid:recovery.pid,generation:recovery.birth,hash:recovery.cdHash).quit(recovery.request)
        }
        emit(["event":"complete","uptime":now()])
    } else if ["close-inactive","inspect-inactive"].contains(CommandLine.arguments[1]) {
        try closeBackground(JSONDecoder().decode(Inactive.self,from:FileHandle.standardInput.readDataToEndOfFile()),inspect:CommandLine.arguments[1]=="inspect-inactive")
        emit(["event":"complete","uptime":now()])
    } else if CommandLine.arguments[1]=="restore-registered" {
        let x=try JSONDecoder().decode(Registered.self,from:FileHandle.standardInput.readDataToEndOfFile())
        let r=x.request
        guard r.targetState && !r.expectedState,try settingsPIDs()==[x.pid],
              let app=NSRunningApplication(processIdentifier:x.pid) else {throw Stop("originalOwnedSettingsUnavailable")}
        let owned=OwnedSettings(app:app,pid:x.pid,generation:x.birth,hash:x.cdHash)
        try owned.verify();try check(try scope(r,allow:x.pid,knownWindow:x.window)==[x.window],"exactRegisteredWindowNotTheOnlyMember")
        let ax=AXUIElementCreateApplication(x.pid)
        guard let windows=attr(ax,kAXWindowsAttribute) as? [AXUIElement],windows.count==1,owner(windows[0])==x.pid,
              NPReadAXWindowNumber(windows[0])==x.window,NPReadWindowSpaces(x.window) as? [UInt64]==[r.space] else {throw Stop("registeredAppleWindowChanged")}
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != x.pid {
            try check(app.activate(options:[]),"ownedSettingsActivationRefused")
            spin(0.35)
        }
        let initial=try freshLoginState()
        let (element,number)=try corroborate(r,owned,expect:initial,timeout:5)
        try check(number==x.window,"registeredWindowChangedDuringRestore")
        if !initial {
            let fresh=try preparePress(r,owned,element,number,expect:false)
            emit(["event":"restore-intent","id":switchID,"window":number,"target":true,"eventCounts":eventCounts(),"uptime":now()])
            let result=AXUIElementPerformAction(fresh,kAXPressAction as CFString)
            emit(["event":"restore-reply","ax":result.rawValue,"uptime":now()])
            _=try corroborate(r,owned,expect:true,timeout:5);try check(result == .success,"recoveryReplyAmbiguous")
        }
        try owned.quit(r);try check(try freshLoginState(),"registeredRecoveryFinalLoginMismatch")
        emit(["event":"complete","uptime":now()])
    } else {throw Stop("invalidMode")}
} catch {
    emit(["event":"blocked","reason":(error as? Stop)?.reason ?? "systemUITransactionUnavailable","uptime":now()]);exit(2)
}
