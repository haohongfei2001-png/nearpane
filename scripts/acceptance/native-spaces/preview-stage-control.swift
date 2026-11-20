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
}
private func scope(_ r:Request,allow pid:pid_t?=nil) throws -> [UInt32] {
    _ = try loginState()
    let hardware=[CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map {CGEventSource.counterForEventType(.hidSystemState,eventType:$0)}
    try check(hardware==r.hid && NSEvent.pressedMouseButtons==0,"physicalInputChanged")
    try check(AXIsProcessTrusted() && CGPreflightScreenCaptureAccess(),"observerPermissionsUnavailable")
    try check(birth(r.hostPID)==r.hostBirth && kernelPath(r.hostPID)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost","installedHostGenerationChanged")
    try check(try signedHash(r.hostPID,"com.holdsnow.nearpane.alpha",apple:false)==r.hostHash,"installedHostSignatureChanged")
    guard NPReadOnlySpacesOpen()==1,let all=NPReadInventory() as? [Facts],all.count==1,
          all[0]["Display Identifier"] as? String==r.display,let current=all[0]["Current Space"] as? Facts,
          current["id64"] as? UInt64==r.space,
          let records=all[0]["Spaces"] as? [Facts],records.contains(where:{$0["id64"] as? UInt64==r.space && $0["type"] as? Int==0 && ($0["uuid"] as? String)?.uppercased()==r.spaceUUID.uppercased()})
    else {throw Stop("controlledOrdinarySpaceChanged")}
    guard let report=NPContractMemberReport([NSNumber(value:r.space)] as CFArray,r.hostPID) as? [String:Facts],
          let census=report[String(r.space)],census["unresolved"] as? Int==0,census["otherMembers"] as? Int==0,
          let windows=census["ordinary"] as? [[String:NSNumber]],windows.count<=1,
          windows.allSatisfy({pid != nil && $0["pid"]?.int32Value==pid && $0["number"] != nil})
    else {throw Stop("controlledDesktopEmptyOrSingleOwnedSettingsWindowUnverified")}
    return windows.compactMap{$0["number"]?.uint32Value}
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
        try verify();_=try scope(r,allow:pid)
        try check(app.terminate(),"ownedSettingsNormalQuitRefused")
        let deadline=now()+4
        while birth(pid)==generation && now()<deadline {spin(0.08)}
        try check(birth(pid) != generation && (try settingsPIDs()).isEmpty,"ownedSettingsNormalQuitUnconfirmed")
        emit(["event":"owned-settings-closed","pid":pid,"uptime":now()])
    }
    func control(_ r:Request) throws -> (AXUIElement,UInt32,Bool) {
        try verify()
        let nums=try scope(r,allow:pid)
        let ax=AXUIElementCreateApplication(pid)
        _=AXUIElementSetMessagingTimeout(ax,0.30)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,
              let windows=attr(ax,kAXWindowsAttribute) as? [AXUIElement],windows.count==1,
              let w=windows.first,owner(w)==pid,attr(w,kAXModalAttribute) as? Bool != true,
              let number=nums.first,number==NPReadAXWindowNumber(w),NPReadWindowSpaces(number) as? [UInt64]==[r.space] else {throw Stop("ownedSettingsWindowNotFrontmostOrNotExclusivelyLeased")}
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
            let (element,window,toggle)=try app.control(r)
            let pref=try freshLoginState()
            emit(["event":"switch-read","window":window,"ui":toggle,"login":pref,"uptime":now()])
            if toggle==expect && pref==expect {
                if let previous,CFEqual(previous,element),priorWindow==window,samples==1 {return(element,window)}
                samples=1;previous=element;priorWindow=window
            } else {samples=0;last="loginAndSystemSwitchHaveNotConverged"}
        } catch let e as Stop {samples=0;last=e.reason}
        spin(0.17)
    }
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
        let (fresh,window,state)=try owned.control(r)
        try check(CFEqual(element,fresh) && number==window && state==r.expectedState && (try freshLoginState())==r.expectedState,"enrolledSwitchChangedBeforePress")
        emit(["event":"press-intent","id":switchID,"target":r.targetState,"window":window,"uptime":now()])
        let result=AXUIElementPerformAction(fresh,kAXPressAction as CFString)
        emit(["event":"press-reply","ax":result.rawValue,"uptime":now()])
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
    } else {throw Stop("invalidMode")}
} catch {
    emit(["event":"blocked","reason":(error as? Stop)?.reason ?? "systemUITransactionUnavailable","uptime":now()]);exit(2)
}
