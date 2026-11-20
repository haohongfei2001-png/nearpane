import AppKit
import CryptoKit
import Security

// All AX text reads follow enrollment of the two exact test window IDs and file URLs.
struct P2Request: Decodable {
    let mode:String, hostPID:Int32, hostHash:String, display:String, space:UInt64
    let hostBirth:UInt64?, hid:[UInt32]?, app:String?, folder:String?, session:String?, pid:Int32?, birth:UInt64?, hash:String?
    let pointerKind:String?
    let numbers:[UInt32]?, target:UInt32?, digests:[String]?, allowedFront:Int32?, allowedFrontBirth:UInt64?, spaceUUID:String?
}
private func p2Path(_ path:String)->String? {
    guard let raw=realpath(path,nil) else { return nil }; defer{free(raw)}; return String(cString:raw)
}
private func p2Owner(_ node:AXUIElement,_ pid:pid_t)->Bool { var owner:pid_t=0; return AXUIElementGetPid(node,&owner) == .success && owner == pid }
private func p2AX(_ root:AXUIElement,_ attr:String)->AXUIElement? {
    guard let raw=value(root,attr),CFGetTypeID(raw) == AXUIElementGetTypeID() else {return nil}
    return (raw as! AXUIElement)
}
private func p2Signed(_ pid:pid_t, id:String, team:String)->Bool {
    var code:SecCode?, requirement:SecRequirement?
    let req="anchor apple generic and identifier \""+id+"\" and certificate leaf[subject.OU] = \""+team+"\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    return SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess &&
        SecRequirementCreateWithString(req as CFString,[],&requirement)==errSecSuccess && code != nil && requirement != nil &&
        SecCodeCheckValidity(code!,[],requirement)==errSecSuccess
}
private func p2Digest(_ text:String)->String { SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined() }

func p2DocumentReport(_ request:P2Request) -> Object {
    let hardware=p2Physical()
    var result:Object=["status":"BLOCKED","hid":hardware,"clock":ProcessInfo.processInfo.systemUptime]
    if let pid=request.pid {
        let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
        result["frontIsFixture"]=front==pid
        result["frontMatchesOriginal"]=request.allowedFront.map{$0==front} ?? false
    }
    func stop(_ why:String)->Object { result["reason"]=why; return result }
    func changed()->Bool { (request.hid.map({$0 != p2Physical()}) ?? false) || NSEvent.pressedMouseButtons != 0 }
    func superseded()->Object { ["status":"BLOCKED","reason":"userSuperseded","hid":p2Physical(),"issued":false] }
    if request.mode=="exit" {
        guard let pid=request.pid,let birth=request.birth,let nums=request.numbers,pid>1,birth>0,
              nums.count==2,Set(nums).count==2,!nums.contains(0) else{return stop("invalidExitIdentity")}
        let current=birthMicroseconds(pid)
        let absent=current == nil && kill(pid,0) == -1 && errno == ESRCH
        let previousGone=absent || (current != nil && current != birth)
        let owned=rows.contains { row in row[kCGWindowOwnerPID as String] as? pid_t == pid && (row[kCGWindowNumber as String] as? UInt32).map(nums.contains)==true }
        return ["status":previousGone && list != nil && !owned ? "EXITED":"UNCONFIRMED","generationGone":previousGone,
                "windowsGone":list != nil && !owned,"frontIsFixture":NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,"hid":hardware]
    }
    if changed(){return superseded()}
    guard let host, host.processIdentifier==request.hostPID, runningCodeHash(request.hostPID)==request.hostHash,
          let hBirth=birthMicroseconds(request.hostPID), request.hostBirth.map({$0==hBirth}) ?? true,
          let scope=inventory(requireComplete:true)?.first(where:{$0["scope"] as? String==request.display}),
          scope["current"] as? UInt64==request.space,(scope["records"] as? [Object])?.contains(where:{
              $0["id"] as? UInt64==request.space && $0["type"] as? Int==0 })==true else{return stop("installedHostOrLeasedSpaceChanged")}
    result["hostBirth"]=hBirth
    if changed(){return superseded()}
    let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
    if let original=request.allowedFront, foreground==original,let born=birthMicroseconds(original) {
        result["protectedFrontBirth"]=born
    }
    if request.mode=="baseline" {result["status"]="READY";return result}
    if request.mode=="launch-admission" {
        guard let original=request.allowedFront,original>1,let expected=request.allowedFrontBirth,expected>0,
              foreground==original,birthMicroseconds(original)==expected,
              let uuid=request.spaceUUID,(scope["records"] as? [Object])?.contains(where:{
                  $0["id"] as? UInt64==request.space && $0["type"] as? Int==0 &&
                  ($0["uuid"] as? String)?.lowercased()==uuid.lowercased()
              })==true, request.hid?.count==hardware.count, !changed()
        else{return changed() ? superseded() : stop("protectedForegroundOrOrdinaryLeaseChanged")}
        result["status"]="LAUNCH_ADMITTED";result["frontMatchesOriginal"]=true;result["spaceUUID"]=uuid
        return result
    }
    guard let filename=request.app,let folder=request.folder,let token=request.session,let pid=request.pid,let born=request.birth,let code=request.hash,
          let numbers=request.numbers, numbers.count==2,Set(numbers).count==2,!numbers.contains(0),pid>1,born>0,
          UUID(uuidString:token) != nil,let physical=p2Path(filename),let sandbox=p2Path(folder) else{return stop("incompleteEnrollment")}
    let kit=URL(fileURLWithPath:physical).deletingLastPathComponent()
    let file=URL(fileURLWithPath:physical)
    guard kit.deletingLastPathComponent().path=="/private/tmp" || p2Path(kit.deletingLastPathComponent().path)=="/private/tmp" else{return stop("unsupportedFixtureKit")}
    guard kit.lastPathComponent.hasPrefix("nearpane-d01."),file.lastPathComponent=="Field Notes.app",
          sandbox=="/private/tmp/"+kit.lastPathComponent+"/"+token else{return stop("wrongFixtureOrSession")}
    let bundle="net.example.spaces-document", team="ZB9D4T66QB"
    var kernelPath = [CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&kernelPath,UInt32(kernelPath.count))>0,
          p2Path(String(cString:kernelPath))==physical+"/Contents/MacOS/FieldNotes" else{return stop("kernelExecutableIdentityChanged")}
    result["registrationStage"]="kernelExecutable"
    guard let live=NSRunningApplication(processIdentifier:pid), !live.isTerminated,live.activationPolicy == .regular,
          live.bundleIdentifier==bundle else{return stop("LSRegularAppIdentityUnavailable")}
    result["registrationStage"]="regular"
    guard let url=live.bundleURL,p2Path(url.path)==physical,
          let executable=live.executableURL,p2Path(executable.path)==physical+"/Contents/MacOS/FieldNotes",
          NSRunningApplication.runningApplications(withBundleIdentifier:bundle).filter({$0.processIdentifier==pid && $0.bundleURL.flatMap({p2Path($0.path)})==physical}).count==1
          else{return stop("LSBundleOrRegisteredExecutableUnavailable")}
    result["registrationStage"]="registeredBundleAndExecutable"
    guard birthMicroseconds(pid)==born, runningCodeHash(pid)==code, p2Signed(pid,id:bundle,team:team) else{return stop("liveGenerationOrDeveloperIDMismatch")}
    result["registration"]=["pid":pid,"birth":born,"cdHash":code,"team":team,"bundle":bundle,"bundleURL":physical,
                            "executable":physical+"/Contents/MacOS/FieldNotes","kernelExecutableConfirmed":true,"regular":true,"launch":live.launchDate?.timeIntervalSince1970 as Any? ?? NSNull()] as Object
    let root=AXUIElementCreateApplication(pid),system=AXUIElementCreateSystemWide()
    _=AXUIElementSetMessagingTimeout(root,0.35);_=AXUIElementSetMessagingTimeout(system,0.35)
    guard AXIsProcessTrusted() else{return stop("observerAXUnavailable")}
    // AppKit can expose auxiliary windows in AXWindows. Only the two previously
    // enrolled CG window numbers may be used for AX document or editor reads.
    let catalog=AXWindowList.read(root,limit:32)
    result["reportedWindows"]=catalog.reportedCount as Any? ?? NSNull()
    result["copiedWindows"]=catalog.actualCount as Any? ?? NSNull()
    guard let windows=catalog.windows else { return stop("fixtureAXWindowInventoryUnavailable") }
    result["enrolledAXMatches"]=numbers.map { number in
        Set(windows.filter { p2Owner($0,pid) && NPReadAXWindowNumber($0)==number }).count
    }
    let ownedCG=rows.filter{ $0[kCGWindowOwnerPID as String] as? pid_t==pid && $0[kCGWindowLayer as String] as? Int==0 }
    let layerZero=ownedCG.compactMap{$0[kCGWindowNumber as String] as? UInt32}
    let memberships=numbers.map { NPReadWindowSpaces($0) as? [UInt64] }
    result["ownedLayerZero"]=layerZero
    result["enrolledMemberships"]=memberships.map { $0 as Any? ?? NSNull() }
    guard list != nil,numbers.allSatisfy({ n in layerZero.filter({$0==n}).count==1 }),
          memberships.allSatisfy({$0==[request.space]}) else{return stop("CGWindowOrSpaceMembershipChanged")}
    var ordered=[AXUIElement](),editors=[AXUIElement](),hashes=[String]()
    for (i,n) in numbers.enumerated() {
        let slot=i==0 ? "A":"B", expected=sandbox+"/"+slot+".txt"
        let matches=Set(windows.filter{p2Owner($0,pid) && NPReadAXWindowNumber($0)==n})
        result["slot"]=slot
        guard matches.count==1,let window=matches.first else{return stop("enrolledWindowCGNumberNotUnique")}
        let roleOK=value(window,kAXRoleAttribute) as? String==kAXWindowRole
        let idOK=value(window,kAXIdentifierAttribute) as? String=="p2-document-window-"+slot
        let raw=value(window,kAXDocumentAttribute)
        let url=(raw as? URL) ?? (raw as? String).flatMap { URL(string:$0) }
        let urlOK=url.map { u in
            u.isFileURL && ((u.host ?? "").isEmpty || u.host=="localhost") && u.query==nil && u.fragment==nil &&
                (u.path==expected || u.path==String(expected.dropFirst("/private".count)))
        } ?? false
        result["roleMatches"]=roleOK;result["identifierMatches"]=idOK;result["urlMatches"]=urlOK
        guard roleOK,idOK,urlOK else{return stop("enrolledDocumentAXWindowOrURLUnavailable")}
        var queue=[window],seen=Set<AXUIElement>(),matchesEditor=[AXUIElement]()
        while let e=queue.popLast() {
            guard seen.count<48,p2Owner(e,pid) else{return stop("editorHierarchyChanged")}
            if !seen.insert(e).inserted{continue}
            if value(e,kAXRoleAttribute) as? String==kAXTextAreaRole { matchesEditor.append(e);continue }
            let kids=value(e,kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard kids.count<=24 else{return stop("editorHierarchyOverBound")};queue+=kids
        }
        result["editorCount"]=matchesEditor.count
        guard matchesEditor.count==1,let editor=matchesEditor.first,
              value(editor,kAXIdentifierAttribute) as? String=="p2-document-editor-"+slot,
              let ew=p2AX(editor,kAXWindowAttribute),CFEqual(ew,window),
              let text=value(editor,kAXValueAttribute) as? String,text.utf8.count<=4096 else{return stop("enrolledDocumentEditorOrBoundedTextUnavailable")}
        ordered.append(window);editors.append(editor);hashes.append(p2Digest(text))
    }
    func focus()->(UInt32?,UInt32?,Bool) {
        guard let app=p2AX(system,kAXFocusedApplicationAttribute),p2Owner(app,pid),
              NSWorkspace.shared.frontmostApplication?.processIdentifier==pid, let focused=p2AX(app,kAXFocusedWindowAttribute),
              let direct=p2AX(root,kAXFocusedWindowAttribute),CFEqual(focused,direct),let i=ordered.firstIndex(where:{CFEqual($0,focused)}) else{return(nil,nil,false)}
        let main=p2AX(root,kAXMainWindowAttribute).flatMap{m in ordered.firstIndex{CFEqual(m,$0)}}.map{numbers[$0]}
        let targetEditor=editors[i]
        let systemEditor=p2AX(system,kAXFocusedUIElementAttribute), appEditor=p2AX(root,kAXFocusedUIElementAttribute)
        return (numbers[i],main,systemEditor.map{CFEqual($0,targetEditor)}==true && appEditor.map{CFEqual($0,targetEditor)}==true)
    }
    let f=focus()
    result["numbers"]=numbers;result["axSHA256"]=hashes;result["focused"]=f.0 as Any? ?? NSNull();result["main"]=f.1 as Any? ?? NSNull()
    result["editorFocused"]=f.2;result["fileSlots"]=["A","B"]
    let currentFront=NSWorkspace.shared.frontmostApplication?.processIdentifier
    result["frontIsFixture"]=currentFront==pid
    result["frontMatchesOriginal"]=request.allowedFront.map{$0==currentFront} ?? false
    #if P2_PAIR_POINTER
    if request.mode == "pair-pointer" {
        guard request.hid == hardware, request.digests == hashes, let target = request.target,
              numbers.contains(target), let uuid = request.spaceUUID, let kind = request.pointerKind,
              p2Signed(request.hostPID, id:bundleID, team:team), !changed() else { return stop("pairPointerAdmissionChanged") }
        return pairPointer(kind: kind, target: target, host: host, request: request, uuid: uuid,
                           numbers: numbers, windows: ordered, focus: focus)
    }
    #endif
    if request.mode=="read" {
        result["screenRead"]=CGPreflightScreenCaptureAccess()
        let index=Sidebar(host,rows:rows)
        result["knownIssueMessages"]=index.knownIssues.sorted()
        result["cards"]=numbers.map { n -> Bool in
            let id="current-desktop-window:\(pid):\(n)", nodes=index.controls[id] ?? []
            return nodes.count==1 && p2Owner(nodes[0],request.hostPID) && value(nodes[0],kAXEnabledAttribute) as? Bool==true
        }
        if changed(){return superseded()}
        guard birthMicroseconds(pid)==born,birthMicroseconds(request.hostPID)==hBirth else{return stop("generationChangedAtReadback")}
        result["status"]="READ";return result
    }
    guard ["press","marker"].contains(request.mode),let target=request.target,numbers.contains(target),hashes==request.digests,
          request.hid?.count==hardware.count else{return stop("unadmittedActionOrDocumentDigests")}
    let args=["observe",request.mode,String(request.hostPID),request.hostHash,String(pid),String(target),physical,code,request.display,String(request.space),String(born)]
    var action=fixtureResult(args,ordinaryKeys:request.mode=="marker",gate:{
        if changed(){return superseded()}
        guard birthMicroseconds(pid)==born,birthMicroseconds(request.hostPID)==hBirth,
              inventory()?.first(where:{$0["scope"] as? String==request.display})?["current"] as? UInt64==request.space,
              numbers.allSatisfy({NPReadWindowSpaces($0) as? [UInt64]==[request.space]}) else{return ["issued":false,"reason":"boundGenerationsOrSpaceChanged"]}
        if request.mode=="press" {
            let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let front, front == pid || front == request.allowedFront else{return ["issued":false,"reason":"foregroundChangedBeforeSelection"]}
        }
        if request.mode=="marker" {
            let final=focus();guard final.0==target,final.1==target,final.2 else{return ["issued":false,"reason":"exactSystemEditorChangedBeforeMarker"]}
        }
        return changed() ? superseded() : nil
    })
    action["hidAfter"]=p2Physical(); if changed(){action["userSuperseded"]=true}
    return action
}
