// Compiled after observe.swift's independent system readers and the existing fullscreen menu reader.
struct SplitEnrollment: Decodable {
    let hostPID: Int32, hostBirth: UInt64, hostHash: String
    let fixturePID: Int32, fixtureBirth: UInt64, fixtureHash: String, fixturePath: String
    let numbers: [UInt32], session: UUID, display: String, lease: UInt64
    let protected: [String: String], hardware: [UInt32]?
    let observedStage: Bool?, protectedTypes: [String:Int]?, enrolledHostWindows: [UInt32]?
}
func splitInput() -> [UInt32] {
    [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged,
     .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map {
        CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
    }
}
func splitFrame(_ node: AXUIElement) -> CGRect? {
    guard let position = value(node,kAXPositionAttribute), let size = value(node,kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(position as! AXValue,.cgPoint,&p), AXValueGetValue(size as! AXValue,.cgSize,&s),
          p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
    return .init(origin:p,size:s)
}
func numericRect(_ f: CGRect) -> [Double] { [f.minX,f.minY,f.width,f.height] }
func keyPoint(_ node: AXUIElement) -> AXUIElement? {
    guard let p=value(node,kAXParentAttribute), CFGetTypeID(p)==AXUIElementGetTypeID() else {return nil}
    return (p as! AXUIElement)
}
func hasAncestor(_ child: AXUIElement, _ target: AXUIElement, owner: pid_t) -> Bool {
    var node: AXUIElement? = child
    for _ in 0..<24 {
        guard let n=node else {return false}
        var pid: pid_t=0
        guard AXUIElementGetPid(n,&pid) == .success, pid==owner else {return false}
        if CFEqual(n,target) {return true}
        node=keyPoint(n)
    }
    return false
}
func supportedPress(_ el: AXUIElement) -> Bool {
    var names: CFArray?
    return AXUIElementCopyActionNames(el,&names) == .success && (names as? [String])?.contains(kAXPressAction)==true
}
func fullscreenShell(_ display:String,current:UInt64) -> Object {
    var result:Object=[:]
    if let h=dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",RTLD_LAZY) {
        defer {dlclose(h)}
        typealias Connection = @convention(c) () -> Int32
        typealias Animating = @convention(c) (Int32,CFString) -> Bool
        typealias Current = @convention(c) (Int32,CFString) -> UInt64
        if let c=dlsym(h,"CGSMainConnectionID"),let a=dlsym(h,"CGSManagedDisplayIsAnimating"),let s=dlsym(h,"CGSManagedDisplayGetCurrentSpace") {
            let cid=unsafeBitCast(c,to:Connection.self)()
            if cid>0 {
                result["animating"]=unsafeBitCast(a,to:Animating.self)(cid,display as CFString)
                result["sameCurrent"]=unsafeBitCast(s,to:Current.self)(cid,display as CFString)==current
            }
        }
    }
    var exposed=0,queried=0
    for (agent,id) in [(OverviewAgent.dock,"Dock"),(.manager,"WindowManager")] {
        guard let who=try? OverviewProcess.current(agent) else {continue}
        let root=AXUIElementCreateApplication(who.pid)
        _=AXUIElementSetMessagingTimeout(root,0.25)
        let list=value(root,kAXChildrenAttribute) as? [AXUIElement]
        if let list {
            queried+=1
            exposed+=list.filter { who.owns($0) && ["mc","mc.display"].contains(value($0,kAXIdentifierAttribute) as? String ?? "") }.count
        }
        result["signed"+id]=true;result[agent == .dock ? "dockBirth":"managerBirth"]=who.birth
    }
    result["rootListsRead"]=queried
    if queried>0 {result["exposedRoots"]=exposed}
    return result
}
func scopedSplit(_ verb: String, _ r: SplitEnrollment) -> Object {
    var result: Object = ["uptime":ProcessInfo.processInfo.systemUptime, "verb":verb,"issued":false]
    func stop(_ reason:String)->Object { result["reason"]=reason;return result }
    let hardware=splitInput()
    result["hardware"]=hardware
    let session=CGSessionCopyCurrentDictionary() as? Object
    guard AXIsProcessTrusted() else{return stop("observerAccessibilityUnavailable")}
    if let enrolled=r.observedStage {
        guard verb=="fullscreen-read",stage==enrolled else{return stop("enrolledStageStateChanged")}
    } else if stage != false {return stop("liveStageManagerOffUnconfirmed")}
    guard session?[kCGSessionOnConsoleKey as String] as? Bool==true,session?["CGSSessionScreenIsLocked"] as? Bool != true,
          session?[kCGSessionUserIDKey as String] as? NSNumber==NSNumber(value:getuid()) else{return stop("actualUnlockedConsoleUnavailable")}
    let installed="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
    guard splitProcessPath(r.hostPID)==installed else{return stop("installedHostKernelPathChanged")}
    guard birthMicroseconds(r.hostPID)==r.hostBirth else{return stop("installedHostBirthChanged")}
    guard splitSignedPID(r.hostPID,identifier:"com.holdsnow.nearpane.alpha"),runningCodeHash(r.hostPID)==r.hostHash else{return stop("installedHostSignatureChanged")}
    guard let host=NSRunningApplication(processIdentifier:r.hostPID) else{return stop("installedHostAXHandleUnavailable")}
    // Foundation standardizes /private/tmp to /tmp on this SDK. Pin the live kernel
    // executable, its code and its process birth to the adjacent, private fixture kit.
    guard let observer=splitProcessPath(getpid()),let fixturePath=splitFixturePath(r.fixturePath,observerExecutable:observer) else{return stop("enrolledFixturePathOutsideReaderKit")}
    guard splitProcessPath(r.fixturePID)==fixturePath else{return stop("fixtureKernelExecutableChanged")}
    guard birthMicroseconds(r.fixturePID)==r.fixtureBirth else{return stop("fixtureProcessBirthChanged")}
    guard splitSignedPID(r.fixturePID,identifier:"net.example.spaces-split-documents") else{return stop("fixtureSigningIdentifierChanged")}
    guard runningCodeHash(r.fixturePID)==r.fixtureHash else{return stop("fixtureCDHashChanged")}
    guard r.numbers.count==2,Set(r.numbers).count==2,r.numbers.allSatisfy({$0>0}) else{return stop("twoDistinctEnrolledWindowNumbersRequired")}
    guard let table=inventory(requireComplete:true),table.count==1,table[0]["scope"] as? String==r.display,
          let current=table[0]["current"] as? UInt64,let records=table[0]["records"] as? [Object] else{return stop("leasedDisplayInventoryChanged")}
    guard let record=records.first(where:{$0["id"] as? UInt64==current}),let kind=record["type"] as? Int,
          let currentUUID=record["uuid"] as? String else{return stop("currentSystemSpaceIdentityUnavailable")}
    guard NSScreen.screens.count==1,let screen=NSScreen.screens.first,
          let displayNumber=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
          displays().first?["uuid"] as? String==r.display else{return stop("physicalDisplayNoLongerMatchesLease")}
    result["kernelCodeIdentitiesVerified"]=true
    let screenFrame=CGDisplayBounds(displayNumber), currentMembers=NPReadCatalogSpaceWindowNumbers(current) as? [UInt32]
    let recordPairs=records.compactMap { rec -> (String,String)? in
        guard let id=rec["id"] as? UInt64,let uuid=rec["uuid"] as? String else {return nil}
        return (String(id),uuid.uppercased())
    }
    guard Set(recordPairs.map(\.0)).count==records.count,
          r.protected.allSatisfy({ pair in recordPairs.contains(where:{$0.0==pair.key && $0.1==pair.value.uppercased()}) }),
          records.contains(where:{$0["id"] as? UInt64==r.lease && $0["type"] as? Int==0})
    else {return stop("leaseOrPreservedDesktopIdentitiesChanged")}
    if let enrolledTypes=r.protectedTypes {
        guard Set(enrolledTypes.keys)==Set(r.protected.keys),records.allSatisfy({ rec in
            guard let id=rec["id"] as? UInt64 else {return false}
            return enrolledTypes[String(id)].map{$0 == rec["type"] as? Int} ?? true
        }) else {return stop("protectedSpaceTypeChanged")}
    }
    let extras=records.filter { rec in (rec["id"] as? UInt64).map {r.protected[String($0)]==nil} ?? true }
    let extra=extras.first?["id"] as? UInt64
    guard extras.count<=1, extras.isEmpty || extras[0]["type"] as? Int==4 else {return stop("unexpectedNativeTopologyChange")}
    let members=r.numbers.map { NPReadWindowSpaces($0) as? [UInt64] ?? [] }
    let ownerRows=r.numbers.map { n in rows.filter { $0[kCGWindowNumber as String] as? UInt32==n &&
        $0[kCGWindowOwnerPID as String] as? Int32==r.fixturePID && $0[kCGWindowLayer as String] as? Int==0 } }
    guard members.allSatisfy({$0.count==1}), ownerRows.allSatisfy({$0.count==1}), let forward=currentMembers else {return stop("exactWindowIdentityOrMembershipUnavailable")}
    let frames=ownerRows.compactMap { ($0[0][kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)) }
    let drawn=ownerRows.map { $0[0][kCGWindowIsOnscreen as String] as? Bool==true }
    let fixtureRoot=AXUIElementCreateApplication(r.fixturePID)
    _ = AXUIElementSetMessagingTimeout(fixtureRoot,0.15)
    let fixtureAX=value(fixtureRoot,kAXWindowsAttribute) as? [AXUIElement]
    let windows=fixtureAX ?? []
    let expectedLease=zip(r.numbers,members).compactMap {number,spaces in spaces==[r.lease] ? number:nil}
    func leaseCensus()->Object {
        // The ordinary census cannot run on the fullscreen Space. Its expected
        // roster shrinks from A+B to B to empty as the system moves the documents.
        PreviewCensus.report(r.lease,host:r.hostPID,fixture:r.fixturePID,expected:expectedLease,visible:false,strictExtras:true)
    }
    let census=leaseCensus()
    func exactly(_ expected:[UInt32]) -> Bool {
        census["admitted"] as? Bool==true && Set(expectedLease)==Set(expected)
    }
    result["onlyTwoInLease"]=exactly(r.numbers)
    result["leaseWindowCensus"]=census
    result["leaseOrdinaryCount"]=census["rawOrdinary"]
    result["enrolledOrdinaryCount"]=(census["expectedEvidence"] as? [Object])?.filter{$0["accepted"] as? Bool==true}.count
    result["unresolvedLeaseMembership"]=census["unresolved"];result["otherLeaseMembers"]=census["otherLayers"]

    func visibleMembers(_ list:[Object],on sid:UInt64,forward:Set<UInt32>,fixtureAX:[AXUIElement]?) -> (foreign:Int,unknown:Int,classes:[String:Int]) {
        var foreign=0,unknown=0,classes=[String:Int]()
        for row in list {
            guard row[kCGWindowLayer as String] as? Int==0,row[kCGWindowIsOnscreen as String] as? Bool==true else{continue}
            guard let alpha=row[kCGWindowAlpha as String] as? Double else{unknown+=1;continue}
            if alpha<=0 {continue}
            guard let n=row[kCGWindowNumber as String] as? UInt32,let p=row[kCGWindowOwnerPID as String] as? pid_t else{unknown+=1;continue}
            if p==r.fixturePID && r.numbers.contains(n) {continue}
            guard let reverse=NPReadWindowSpaces(n) as? [UInt64],!reverse.isEmpty,forward.contains(n)==reverse.contains(sid) else{unknown+=1;continue}
            if !forward.contains(n) {continue}
            // Pin this particular CG number to the same owner, geometry and bidirectional
            // membership. Anonymous counts from a previous Space cannot clear a different row.
            guard let rows=PreviewCensus.windowRows(n),rows.count==1,let cg=rows.first,
                  cg[kCGWindowNumber as String] as? UInt32==n,cg[kCGWindowOwnerPID as String] as? pid_t==p,
                  cg[kCGWindowLayer as String] as? Int==0,cg[kCGWindowIsOnscreen as String] as? Bool==true,
                  let a=cg[kCGWindowAlpha as String] as? Double,a>0,
                  let b=row[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:b),
                  let again=cg[kCGWindowBounds as String] as? NSDictionary,CGRect(dictionaryRepresentation:again)==rect else{unknown+=1;continue}
            if verb=="fullscreen-read",r.observedStage != nil,p==r.hostPID {
                let enrolled=r.enrolledHostWindows?.contains(n)==true
                let exact=enrolled && reverse==[sid] && r.protected[String(sid)] != nil &&
                    birthMicroseconds(p)==r.hostBirth && splitProcessPath(p)==installed &&
                    splitSignedPID(p,identifier:"com.holdsnow.nearpane.alpha") && runningCodeHash(p)==r.hostHash
                classes[exact ? "installedHost/enrolledLayerZero":"installedHost/unregisteredOrSharedLayerZero",default:0]+=1
                if !exact {foreign+=1}
                continue
            }
            let matches=p==r.fixturePID ? fixtureAX?.filter{NPReadAXWindowNumber($0)==n}:nil
            let el=matches?.count==1 ? PreviewCensus.ownedAX(matches?.first,pid:p):nil
            let evidence=PreviewCensus.extra(pid:p,fixture:r.fixturePID,rect:rect,on:true,drawn:rect.width>1 && rect.height>1,
                singleSpace:reverse==[sid],publicNow:nil,publicAll:nil,axCount:matches?.count,
                role:el.flatMap{value($0,kAXRoleAttribute) as? String},subrole:el.flatMap{value($0,kAXSubroleAttribute) as? String},strict:true)
            classes[evidence.owner+"/"+evidence.category,default:0]+=1
            if !evidence.admitted {foreign+=1}
        }
        return (foreign,unknown,classes)
    }
    let visibility=visibleMembers(rows,on:current,forward:Set(forward),fixtureAX:fixtureAX)
    let foreign=visibility.foreign,unknown=visibility.unknown
    result["foreignVisibleMembers"]=foreign;result["unknownVisibleMembers"]=unknown;result["visibleExtraClasses"]=visibility.classes
    let ax=r.numbers.map { n in windows.filter { NPReadAXWindowNumber($0)==n } }
    let ordinary=ax.map { $0.count==1 && value($0[0],kAXRoleAttribute) as? String==kAXWindowRole &&
        value($0[0],kAXSubroleAttribute) as? String==kAXStandardWindowSubrole &&
        value($0[0],kAXMinimizedAttribute) as? Bool==false && value($0[0],kAXModalAttribute) as? Bool != true }
    let axFrames=ax.map { group -> [Double]? in group.count==1 ? splitFrame(group[0]).map(numericRect):nil }
    result["display"]=r.display;result["displayFrame"]=numericRect(screenFrame)
    result["space"]=current; result["spaceUUID"]=currentUUID;result["type"]=kind;result["newFullscreenIDs"]=extras.compactMap{$0["id"] as? UInt64}
    result["memberships"]=members;result["forward"]=r.numbers.map(forward.contains);result["drawn"]=drawn
    result["cgFrames"]=frames.map(numericRect);result["axStandard"]=ordinary;result["axFrames"]=axFrames.map{$0 as Any? ?? NSNull()}
    func beforeInput() -> Bool {
        guard let latest=inventory(requireComplete:true), latest.count==1, latest[0]["scope"] as? String==r.display,
              latest[0]["current"] as? UInt64==current, let rs=latest[0]["records"] as? [Object],
              (rs as NSArray).isEqual(to: records), birthMicroseconds(r.fixturePID)==r.fixtureBirth,
              birthMicroseconds(r.hostPID)==r.hostBirth else {return false}
        guard leaseCensus()["admitted"] as? Bool==true,
              let freshRows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [Object],
              let actual=NPReadCatalogSpaceWindowNumbers(current) as? [UInt32] else{return false}
        let fresh=visibleMembers(freshRows,on:current,forward:Set(actual),fixtureAX:value(fixtureRoot,kAXWindowsAttribute) as? [AXUIElement])
        guard fresh.foreign==0,fresh.unknown==0 else{return false}
        return splitInput()==hardware && NSEvent.pressedMouseButtons==0 &&
            CFPreferencesCopyAppValue("GloballyEnabled" as CFString,"com.apple.WindowManager" as CFString) as? Bool==false
    }
    let trustedState=CGEventSource.buttonState(.combinedSessionState,button:.left)==false && NSEvent.pressedMouseButtons==0 &&
        r.hardware==hardware && splitInput()==hardware && birthMicroseconds(r.fixturePID)==r.fixtureBirth
    guard ["read","fullscreen-read","tile","picker","pair"].contains(verb) else {return stop("unknownOperation")}
    if verb=="fullscreen-read" {
        result["frontIsFixture"]=NSWorkspace.shared.frontmostApplication?.processIdentifier==r.fixturePID
        result["focusedFixtureNumber"]=focusedNumber(r.fixturePID) as Any? ?? NSNull()
        result["axFullscreen"]=ax.map { bucket -> Any in
            guard bucket.count==1,let node=bucket.first,let flag=value(node,"AXFullScreen") as? Bool else{return NSNull()}
            return flag
        }
        result["windowManagement"]=fullscreenShell(r.display,current:current)
        if let extra,let ids=NPReadCatalogSpaceWindowNumbers(extra) as? [UInt32] {result["fullscreenForward"]=r.numbers.map(ids.contains)}
        result["ready"]=true;return result
    }
    if verb=="read" {
        let index=Sidebar(host,rows:rows), groupID="current-split-view:"+r.display+":"+String(current)
        let groups=index.visited.filter {value($0,kAXIdentifierAttribute) as? String==groupID}
        let nodes=r.numbers.map { n in index.visited.filter {value($0,kAXIdentifierAttribute) as? String=="split-view-member:"+String(r.fixturePID)+":"+String(n)} }
        result["hostGroupCount"]=groups.count;result["hostMemberCounts"]=nodes.map(\.count)
        if groups.count==1,let group=groups.first,let f=splitFrame(group) {
            let panels=rows.filter { row in
                guard row[kCGWindowOwnerPID as String] as? Int32==r.hostPID,row[kCGWindowIsOnscreen as String] as? Bool==true,
                      (row[kCGWindowAlpha as String] as? Double ?? 0)>0,
                      let d=row[kCGWindowBounds as String] as? NSDictionary,let panel=CGRect(dictionaryRepresentation:d) else {return false}
                return screenFrame.contains(f) && panel.insetBy(dx:-1,dy:-1).contains(f)
            }
            result["hostPanelPresent"] = panels.count==1
            result["hostGroupFrame"]=numericRect(f)
            result["hostPaneFrames"]=nodes.map { bucket -> Any in
                guard bucket.count==1,let n=bucket.first,hasAncestor(n,group,owner:r.hostPID),let pane=splitFrame(n) else {return NSNull()}
                return numericRect(pane)
            }
        }
        result["ready"]=true;return result
    }
    if verb=="tile" {
        guard current==r.lease,extras.isEmpty,exactly(r.numbers),foreign==0,unknown==0,members==[[current],[current]],
              r.numbers.allSatisfy(forward.contains),ordinary==[true,true],drawn==[true,true],
              front?.processIdentifier==r.fixturePID, focusedNumber(r.fixturePID)==r.numbers[0],trustedState else {return stop("leftMenuAdmissionChanged")}
        let (choices,_)=lifecycleLeftMenu(fixtureRoot)
        result["menuMatches"]=choices.count
        guard choices.count==1, beforeInput(), NSWorkspace.shared.frontmostApplication?.processIdentifier==r.fixturePID,
              focusedNumber(r.fixturePID)==r.numbers[0],r.numbers.allSatisfy({NPReadWindowSpaces($0) as? [UInt64]==[r.lease]})
        else {return stop("uniqueSystemFullscreenLeftMenuUnavailable")}
        result["issued"]=true
        result["axError"]=AXUIElementPerformAction(choices[0].0,kAXPressAction as CFString).rawValue
        return result
    }
    if verb=="picker", current==extra,kind==4,members==[[current],[current]],r.numbers.allSatisfy(forward.contains) {
        result["alreadyTogether"]=true;return result
    }
    let owners: [OverviewProcess]
    do {owners=try OverviewAgent.allCases.compactMap {try OverviewProcess.current($0)}}
    catch {return stop("kernelPickerOwnerGenerationOrSignatureUnavailable")}
    guard let extra, (current==r.lease || current==extra), members==[[extra],[r.lease]], exactly([r.numbers[1]]),
          foreign==0,unknown==0,
          (NPReadCatalogSpaceWindowNumbers(extra) as? [UInt32])?.contains(r.numbers[0])==true,
          (NPReadCatalogSpaceWindowNumbers(r.lease) as? [UInt32])?.contains(r.numbers[1])==true,
          front?.processIdentifier==r.fixturePID || owners.contains(where:{$0.pid==front?.processIdentifier}),
          trustedState else {return stop("secondWindowPickerAdmissionUnavailable")}
    let title="Nearpane Split "+r.session.uuidString.lowercased()+" B"
    let a=ax[0].count==1 ? ax[0].first:nil,b=ax[1].count==1 ? ax[1].first:nil
    func readPicker(markerOnly:Bool=false) -> SplitPickerMatch {
        readSplitPicker(title:title,session:r.session,screen:screenFrame,fixture:r.fixturePID,numbers:r.numbers,
            source:a,target:b,presentNativeHalf:kind==0 && current==r.lease && ordinary==[true,true] && drawn==[true,true],
            owners:owners,markerOnly:markerOnly)
    }
    func stillOwnPicker() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==front?.processIdentifier,
              NPReadWindowSpaces(r.numbers[0]) as? [UInt64]==[extra], NPReadWindowSpaces(r.numbers[1]) as? [UInt64]==[r.lease],
              let left=NPReadCatalogSpaceWindowNumbers(extra) as? [UInt32],let right=NPReadCatalogSpaceWindowNumbers(r.lease) as? [UInt32],
              left.contains(r.numbers[0]), !left.contains(r.numbers[1]), right.contains(r.numbers[1]), !right.contains(r.numbers[0])
        else {return false}
        return beforeInput()
    }
    let match=readPicker()
    result["labelMatches"]=match.labelled
    result["route"]=match.route;result["systemOverviewExposed"]=match.overview;result["pickerEvidence"]=match.evidence
    result["pickerReason"]=match.reason
    let ready=match.press != nil || match.click != nil
    if !ready {return stop(match.reason)}
    guard verb=="pair" else {result["ready"]=true;return result}
    guard stillOwnPicker() else {return stop("pickerChangedBeforeInput")}
    let confirmed=readPicker(markerOnly:match.byMarker)
    result["recheckEvidence"]=confirmed.evidence
    guard confirmed.route==match.route, confirmed.authority==match.authority, confirmed.byMarker==match.byMarker,
          confirmed.authority.map({ (try? $0.verify()) != nil }) ?? true,
          splitInput()==hardware,NSEvent.pressedMouseButtons==0,
          NSWorkspace.shared.frontmostApplication?.processIdentifier==front?.processIdentifier,
          birthMicroseconds(r.fixturePID)==r.fixtureBirth,
          NPReadWindowSpaces(r.numbers[0]) as? [UInt64]==[extra],NPReadWindowSpaces(r.numbers[1]) as? [UInt64]==[r.lease]
    else {return stop("pickerIdentityChangedDuringImmediateRecheck")}
    if let target=match.press, let verified=confirmed.press,CFEqual(verified,target) {
        result["issued"]=true;result["axError"]=AXUIElementPerformAction(verified,kAXPressAction as CFString).rawValue
    } else if let point=match.click {
        guard confirmed.press==nil,confirmed.click==point, CGPreflightPostEventAccess(),
              let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {return stop("pickerHitFailedImmediateRevalidation")}
        let pointer=CGEvent(source:nil)?.location
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
        result["issued"]=true;result["mouseEvents"]=2
        let after=splitInput()
        if let pointer, CGEvent(source:nil)?.location==point,
           after.enumerated().allSatisfy({ $0.element==hardware[$0.offset] || ($0.offset==1 && $0.element==hardware[1] &+ 1) }) {
            CGWarpMouseCursorPosition(pointer)
        }
    } else {return stop("uniqueOwnedSystemPickerEntryUnavailable")}
    return result
}
struct InactiveStageSurface: Decodable {
    let space:UInt64, display:String, number:UInt32, pid:pid_t
}
func readInactiveStageSurface(_ r:InactiveStageSurface)->Object {
    var out:Object=["admitted":false,"pixels":0]
    guard stage==true,AXIsProcessTrusted(),let manager=try? OverviewProcess.current(.manager),manager.pid==r.pid,
          let scope=inventory(requireComplete:true),scope.count==1,scope[0]["scope"] as? String==r.display,
          scope[0]["current"] as? UInt64==r.space,NSScreen.screens.count==1,let actual=displays().first,
          actual["uuid"] as? String==r.display,let monitor=NSScreen.screens.first,
          let physical=monitor.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else{return out}
    let screen=CGDisplayBounds(physical)
    guard let forward=NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32],forward.contains(r.number),
          NPReadWindowSpaces(r.number) as? [UInt64]==[r.space],
          let rows=PreviewCensus.windowRows(r.number),rows.count==1,let row=rows.first,
          row[kCGWindowNumber as String] as? UInt32==r.number,row[kCGWindowOwnerPID as String] as? pid_t==manager.pid,
          row[kCGWindowLayer as String] as? Int==0,row[kCGWindowIsOnscreen as String] as? Bool != true,
          let bounds=row[kCGWindowBounds as String] as? NSDictionary,let f=CGRect(dictionaryRepresentation:bounds),
          screen.contains(f),f.minX>screen.minX+screen.width*0.75,f.width>2,f.height>2,
          f.width<=screen.width*0.15,f.height<=screen.height*0.15,
          let visible=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Object],
          !visible.contains(where:{$0[kCGWindowNumber as String] as? UInt32==r.number}),
          let publicNow=NSWindow.windowNumbers(options:.allApplications),!publicNow.contains(NSNumber(value:r.number))
    else{return out}
    let root=AXUIElementCreateApplication(manager.pid)
    _=AXUIElementSetMessagingTimeout(root,0.25)
    guard let windows=value(root,kAXWindowsAttribute) as? [AXUIElement],windows.allSatisfy({manager.owns($0) && NPReadAXWindowNumber($0) != r.number}),
          (try? manager.verify()) != nil,NPReadWindowSpaces(r.number) as? [UInt64]==[r.space] else{return out}
    out["admitted"]=true;out["category"]="offscreenSignedWindowManagerSurface";out["ownerBirth"]=manager.birth
    out["number"]=r.number;out["bounds"]=numericRect(f);out["publicOnscreen"]=false;out["listedAsOwnDocument"]=false
    return out
}
let input=FileHandle.standardInput.readData(ofLength:16385)
if CommandLine.arguments.dropFirst().elementsEqual(["compare-roster","inactive-stage-surface"]),input.count<=1024 {
    let stamp=try JSONDecoder().decode(InactiveStageSurface.self,from:input)
    print(String(decoding:try JSONSerialization.data(withJSONObject:readInactiveStageSurface(stamp),options:.sortedKeys),as:UTF8.self))
    exit(0)
}
guard CommandLine.arguments.count==3,CommandLine.arguments[1]=="compare-roster",input.count<=16384 else {exit(2)}
let enrollment=try JSONDecoder().decode(SplitEnrollment.self,from:input)
let output=scopedSplit(CommandLine.arguments[2],enrollment)
print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:.sortedKeys),as:UTF8.self))
