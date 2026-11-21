import AppKit
import Foundation

// Fixed public messages from OrdinaryRefusal and its existing helper. No arbitrary
// AX text, titles, bundle URLs or system error descriptions enter readback receipts.
let pairRefusals = [
    "正在核对窗口，请等当前操作结束。":"busy",
    "显示器、工作区域或排除规则已变化，请重新预演。":"scope",
    "所选窗口或预演已过期，请重新选择。":"stale",
    "窗口观测连续性已中断。已保留恢复记录，请核对当前位置。":"lost",
    "尚未授权此窗口，或当前管理已暂停。":"noGrant",
    "窗口已被其他管理会话占用，或仍有未解决的恢复记录。":"ownership",
    "无法确认窗口身份、可见性及 AX/CG 几何。":"ambiguous",
    "预计位置超出该窗已证实可用的尺寸或显示范围。":"minimum",
    "无法安全保存或归档恢复记录，已停止布局写入。":"storage",
    "窗口助手超时或已停止，保留恢复记录。":"helperTimeout",
    "窗口助手已结束，保留恢复记录。":"helperEnded"
]

func pairLeaseState(_ r: P2Request) -> String {
    guard let scopes = inventory(requireComplete:true) else { return "UNAVAILABLE" }
    guard scopes.count == 1, let scope = scopes.first, scope["scope"] as? String == r.display,
          scope["current"] as? UInt64 == r.space, let uuid = r.spaceUUID,
          let records = scope["records"] as? [Object],
          records.filter({ $0["id"] as? UInt64 == r.space && $0["type"] as? Int == 0 &&
                           ($0["uuid"] as? String)?.lowercased()==uuid.lowercased() }).count == 1 else { return "CHANGED" }
    return "BOUND"
}

func pairLSCandidate(pid: pid_t, bundle: String, app: String, allowListed: Bool = false) -> (NSRunningApplication?, String, Bool) {
    let direct = NSRunningApplication(processIdentifier:pid)
    let listed = NSRunningApplication.runningApplications(withBundleIdentifier:bundle).filter { $0.processIdentifier==pid }
    guard listed.count <= 1 else {return (nil,"duplicateRegisteredGeneration",false)}
    guard let current = direct ?? (allowListed ? listed.first : nil) else {return (nil,"registeredProcessUnavailable",true)}
    guard !current.isTerminated else {return (nil,"registeredProcessTerminated",false)}
    guard current.activationPolicy == .regular else {return (nil,"registeredPolicyNotRegular",false)}
    guard let id = current.bundleIdentifier else {return (nil,"registeredIdentifierUnavailable",true)}
    guard id == bundle else {return (nil,"differentRegisteredBundle",false)}
    guard let url = current.bundleURL, let exe = current.executableURL else {return (nil,"registeredURLsUnavailable",true)}
    func canonical(_ url:URL)->String? {guard let ptr=realpath(url.path,nil) else{return nil};defer{free(ptr)};return String(cString:ptr)}
    guard canonical(url) == app, canonical(exe) == app+"/Contents/MacOS/FieldNotes"
    else {return (nil,"differentRegisteredExecutable",false)}
    guard listed.count == 1 else {return (nil,"registeredBundleListTemporarilyEmpty",true)}
    return (current,direct == nil ? "regularExactBundleLookupByPIDAndIdentifier" : "regularExactBundleAndExecutable",false)
}

func pairRegistered(pid: pid_t, bundle: String, app: String, guardScope: () -> String?) ->
    (app: NSRunningApplication?, reason: String, receipt: Object) {
    var reads=0
    let (value,reason,receipt)=pairWaitForRegistration({
        defer {reads+=1}
        return pairLSCandidate(pid:pid,bundle:bundle,app:app,allowListed:reads>0)
    },
        guardScope:guardScope,clock:{ProcessInfo.processInfo.systemUptime},wait:{_=CFRunLoopRunInMode(.defaultMode,0.045,false)})
    return (value,reason,receipt)
}

func pairPostRead(_ r: P2Request, host: NSRunningApplication, pid: pid_t,
                  numbers: [UInt32], windows: [AXUIElement]) -> Object {
    let lease = pairLeaseState(r), clock = ProcessInfo.processInfo.systemUptime
    var out:Object = ["status":"BLOCKED","issued":false,"clock":clock,"leaseState":lease]
    func stop(_ reason: String) -> Object {out["reason"]=reason;return out}
    guard lease == "BOUND", let expectedDisplay = r.pointerDisplayUUID, let panelID = r.pointerPanel, panelID>0,
          numbers.count == 2, windows.count == 2 else {return stop("postReadEnrollmentOrLeaseUnavailable")}
    guard NSScreen.screens.count == 1, let screen=NSScreen.screens.first,
          let id=screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
          id.uint32Value == CGMainDisplayID(), let uuid=CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue()
    else {return stop("postReadDisplayUnavailable")}
    let display = CFUUIDCreateString(nil,uuid) as String
    guard display.lowercased() == expectedDisplay.lowercased() else {return stop("postReadDisplayChanged")}
    guard let cgRows=pairRows() else {return stop("postReadCGListUnavailable")}
    let usable=screen.visibleFrame, bounds=CGDisplayBounds(id.uint32Value)
    let visible=CGRect(x:bounds.minX+usable.minX-screen.frame.minX,y:bounds.minY+screen.frame.maxY-usable.maxY,
                       width:usable.width,height:usable.height)
    let index=Sidebar(host,rows:cgRows)
    let cardIDs = numbers.map { "current-desktop-window:\(pid):\($0)" }
    let cardState = cardIDs.map { key -> Object in
        let found=index.controls[key] ?? []
        return ["count":found.count, "uniqueEnabled":found.count==1 && value(found[0],kAXEnabledAttribute) as? Bool == true]
    }
    let panel=pairBounds(cgRows,panelID,host.processIdentifier)
    let state:Object = ["panelVisible":panel != nil,"panelCGID":panelID,"cards":cardState,
                        "otherCurrentCardCount":index.controls.keys.filter{$0.hasPrefix("current-desktop-window:") && !cardIDs.contains($0)}.count,
                        "publishedManagementReasons":index.knownIssues.compactMap{pairRefusals[$0]}.sorted(),
                        "unconfirmedRosterNotice":index.unconfirmedNotice]
    out["sidebar"]=state
    let cg=numbers.map{pairBounds(cgRows,$0,pid)}, ax=windows.map(pairAXRect)
    let memberships=numbers.map{NPReadWindowSpaces($0) as? [UInt64]}
    let catalog=NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32]
    out["systemWindows"]=numbers.indices.map { i in
        ["window":numbers[i],"cg":cg[i].map(windowReceiptRect) as Any? ?? NSNull(),
         "ax":ax[i].map(windowReceiptRect) as Any? ?? NSNull(),"onOriginalSpace":memberships[i]==[r.space],
         "inForwardCatalog":catalog?.contains(numbers[i]) as Any? ?? NSNull()] as Object
    }
    guard let catalog, Set(numbers).isSubset(of:Set(catalog)),memberships.allSatisfy({$0==[r.space]})
    else{return stop("postReadWindowMembershipUnconfirmed")}
    guard let ca=cg[0],let cb=cg[1],let aa=ax[0],let ab=ax[1],pairNear(ca,aa),pairNear(cb,ab)
    else{return stop("postReadWindowCoordinatesUnconfirmed")}
    var geo:Object=["clock":clock,"members":numbers,"cg":[ca,cb].map(windowReceiptRect),"ax":[aa,ab].map(windowReceiptRect),
                    "displayUUID":display,"visible":windowReceiptRect(visible),"leaseState":"BOUND","verifiedOriginalPanelID":panelID]
    if let panel {geo["panel"]=windowReceiptRect(panel);geo["panelID"]=panelID}
    out["geometry"]=geo;out["status"]="READ"
    return out
}
