// P0 acceptance driver. Its read-only state primitives are compiled before this file.
struct Window: Codable, Equatable { let pid: pid_t; let birth: UInt64; let number: UInt32; let executable, identifier, hash: String; let ownerFile: String? }
struct Pair: Codable { let topology: Topology; let sourceWindow, targetWindow: Window; let target: UInt64; let hostPID: pid_t; let hostBirth: UInt64; let hostHash: String; let hid: [UInt32] }
struct Arrow: Codable { let before: Topology; let topology: Topology; let sourceWindow: Window; let target: UInt64; let hid: [UInt32] }
func ownGeneration(_ w:Window) throws -> UUID {
    guard let raw=w.ownerFile,raw.hasPrefix("/private/tmp/nearpane-p0-owned-"),let resolved=realpath(raw,nil) else {throw Refusal("owned generation stream unavailable")}
    defer {free(resolved)}
    let url=URL(fileURLWithPath:raw),group=url.deletingLastPathComponent().lastPathComponent
    try need(String(cString:resolved)==raw && url.lastPathComponent=="p0-generations.json" && UUID(uuidString:group) != nil,"unsafe owner generation source")
    let fd=Darwin.open(raw,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw Refusal("owner generation stream could not be opened")}
    let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
    var info=stat();try need(fstat(fd,&info)==0 && info.st_uid==getuid() && info.st_nlink==1 && info.st_mode&0o077==0 && info.st_size>0 && info.st_size<8192,"invalid owner generation file")
    let data=handle.readDataToEndOfFile()
    guard let state=try JSONSerialization.jsonObject(with:data) as? Map,state["session"] as? String==group,
          state["pid"] as? pid_t==w.pid,state["birth"] as? UInt64==w.birth,let at=state["uptime"] as? Double,
          (0...2.5).contains(ProcessInfo.processInfo.systemUptime-at),let rows=state["windows"] as? [Map],
          rows.count==1,let own=rows.first,own["number"] as? UInt32==w.number,own["visible"] as? Bool==true,
          own["minimized"] as? Bool==false,own["fullscreen"] as? Bool==false,let id=own["generation"] as? String,
          let generation=UUID(uuidString:id) else {throw Refusal("live owned normal document or heartbeat not confirmed")}
    return generation
}
struct RetainedWindow {let owner:Window;let generation:UUID;let element:AXUIElement;let record:Space;let display:UUID}
var retainedWindows=[UInt32:RetainedWindow]()
func windowProof(_ w: Window) throws -> Map {
    let allowed = ["org.nearpane.acceptance.LifecycleWindow","net.example.spaces-route-witness","net.example.spaces-document"]
    try need(allowed.contains(w.identifier) && w.executable.hasPrefix("/private/tmp/nearpane-d01.") && path(w.pid) == w.executable && birth(w.pid) == w.birth,"owned fixture executable or kernel process birth changed")
    let code = signature(w.pid)
    try need(code?.0 == w.identifier && code?.1 == w.hash,"fixture running code signature changed")
    let app = AXUIElementCreateApplication(w.pid); _ = AXUIElementSetMessagingTimeout(app,0.4)
    var value:CFTypeRef?
    let listStatus=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&value)
    let list=listStatus == .success ? value as? [AXUIElement] : nil
    let matching = (list ?? []).filter { owner($0) == w.pid && NPReadAXWindowNumber($0) == w.number }
    let reverse = NPReadWindowSpaces(w.number) as? [UInt64] ?? []
    let forward = reverse.count == 1 ? (NPReadCatalogSpaceWindowNumbers(reverse[0]) as? [UInt32])?.contains(w.number) : nil
    let el = matching.count == 1 ? matching[0] : nil
    let role = el.flatMap { prop($0,kAXRoleAttribute) as? String }, subrole = el.flatMap { prop($0,kAXSubroleAttribute) as? String }
    let direct=role==kAXWindowRole && subrole==kAXStandardWindowSubrole
    var evidence=direct ? "current AX list" : "unconfirmed", generation:String?
    if let held=retainedWindows[w.number] {
        let current=try topology(), g=try ownGeneration(w), windowOwner=exactWindowOwner(w.number)
        try need(w==held.owner && current.display==held.display && current.records.contains(held.record) && held.generation==g &&
                 windowOwner?.0==w.pid && windowOwner?.1==0 && forward==true && reverse==[held.record.id],"owner generation, signed process, WindowServer owner, or one of the membership directions changed")
        generation=g.uuidString
        let heldNumber=NPReadAXWindowNumber(held.element),heldRole=prop(held.element,kAXSubroleAttribute) as? String
        try need(owner(held.element)==w.pid && (heldNumber==0 || heldNumber==w.number) && (heldRole==nil || heldRole==kAXStandardWindowSubrole) &&
                 prop(held.element,kAXMinimizedAttribute) as? Bool != true && prop(held.element,"AXFullScreen") as? Bool != true,"retained AX reference contradicts original ordinary document")
        let remote=current.current != held.record.id
        try need((list != nil || (remote && listStatus == .noValue)) && matching.count<=1 && (matching.isEmpty || direct),
                 "live AX list contradicted the retained standard window or could not be read (AX status \(listStatus.rawValue), matches \(matching.count))")
        if matching.isEmpty && current.current != held.record.id {evidence="foreground AX enrollment + same live owner generation"}
    }
    return ["number":w.number,"pid":w.pid,"birth":w.birth,"reverse":reverse,"forward":forward as Any? ?? NSNull(),
            "standard":evidence != "unconfirmed","roleEvidence":evidence,"ownedWindowGeneration":generation as Any? ?? NSNull(),
            "axStandardNow":direct,"focused":axFocus(w.pid) as Any? ?? NSNull(),"axListRead":list != nil,"axWindowListStatus":listStatus.rawValue,
            "axMatches":matching.count,"axRole":role as Any? ?? NSNull(),"axSubrole":subrole as Any? ?? NSNull(),
            "axFullscreen":el.flatMap { prop($0,"AXFullScreen") as? Bool } as Any? ?? NSNull(),
            "axMinimized":el.flatMap { prop($0,kAXMinimizedAttribute) as? Bool } as Any? ?? NSNull()]
}
func bound(_ w: Window, _ space: UInt64) throws -> Map {
    let proof = try windowProof(w)
    try need(proof["standard"] as? Bool == true && proof["reverse"] as? [UInt64] == [space] && proof["forward"] as? Bool == true,"owned window lacks unique standard AX identity or forward/reverse Space evidence")
    return proof
}
func visibleCard(_ card: AXUIElement, host: pid_t) -> Bool {
    guard let pos = prop(card,kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
          let dim = prop(card,kAXSizeAttribute), CFGetTypeID(dim) == AXValueGetTypeID() else { return false }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(pos as! AXValue,.cgPoint,&point), AXValueGetValue(dim as! AXValue,.cgSize,&size),
          size.width > 2, size.height > 2 else { return false }
    let system = AXUIElementCreateSystemWide(), display = CGDisplayBounds(CGMainDisplayID())
    for fraction in [0.5,0.2,0.8] {
        let sample = CGPoint(x:point.x+size.width*0.5,y:point.y+size.height*fraction)
        var hit: AXUIElement?
        guard display.contains(sample), AXUIElementCopyElementAtPosition(system,Float(sample.x),Float(sample.y),&hit) == .success else { continue }
        var node = hit
        for _ in 0..<16 {
            guard let element = node, owner(element) == host else { break }
            if CFEqual(element,card) { return true }
            guard let parent = prop(element,kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = (parent as! AXUIElement)
        }
    }
    return false
}
func panelMatches(_ pid:pid_t,_ id:String)->([AXUIElement],Map) {
    let root = AXUIElementCreateApplication(pid); _ = AXUIElementSetMessagingTimeout(root,0.4)
    var todo = array(root,kAXWindowsAttribute) + [root]
    // Panels omitted by AXWindows can still be addressed by the owner-specific AX hit test.
    let rect = CGDisplayBounds(CGMainDisplayID())
    for fraction in [0.03,0.11,0.89,0.97] {
        var n: AXUIElement?
        if AXUIElementCopyElementAtPosition(root, Float(rect.minX+fraction*rect.width), Float(rect.minY+0.67*rect.height), &n) == .success {
            var node = n
            for _ in 0..<22 {
                guard let e = node, owner(e) == pid else { break }; todo.append(e)
                guard let p = prop(e,kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else {break}; node = (p as! AXUIElement)
            }
        }
    }
    var visited = Set<AXUIElement>(), matches = [AXUIElement](), current=0, background=0
    while let n = todo.popLast(), visited.count < 6000 {
        guard owner(n) == pid, visited.insert(n).inserted else {continue}
        let i = prop(n,kAXIdentifierAttribute) as? String ?? ""
        if i.hasPrefix("current-desktop-window:") {current += 1}
        if i.hasPrefix("native-space-window:") {background += 1}
        if i == id {matches.append(n); continue}
        if i.hasPrefix("current-desktop-window:") || i.hasPrefix("native-space-window:") {continue}
        let role = prop(n,kAXRoleAttribute) as? String ?? ""
        if !["AXTextField","AXTextArea","AXWebArea","AXStaticText","AXImage"].contains(role) { todo += array(n,kAXChildrenAttribute) }
    }
    return (matches,["matches":matches.count,"currentControls":current,"backgroundControls":background,"visited":visited.count,"scanComplete":todo.isEmpty])
}
func panelTarget(_ pid:pid_t,_ id:String)throws->AXUIElement {
    let (matches,census)=panelMatches(pid,id)
    guard matches.count == 1,census["scanComplete"] as? Bool==true else {throw Refusal("official background card census \(census)")}
    let card = matches[0]; var actions: CFArray?
    try need(prop(card,kAXRoleAttribute) as? String == kAXButtonRole && prop(card,kAXEnabledAttribute) as? Bool == true && AXUIElementCopyActionNames(card,&actions) == .success && (actions as? [String])?.contains(kAXPressAction) == true,"official background card disabled or lacks AXPress")
    try need(visibleCard(card,host:pid),"official background card is clipped, covered or absent from the visible sidebar")
    return card
}
func signedHost(_ pid:pid_t,_ born:UInt64,_ hash:String)throws {
    try need(AXIsProcessTrusted() && path(pid) == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" && birth(pid) == born,"signed installed Host path, AX or process generation changed")
    let s=signature(pid)
    try need(s?.0=="com.holdsnow.nearpane.alpha" && s?.1==hash,"installed running Host signature mismatch")
}
func guardPair(_ p:Pair) throws {
    try signedHost(p.hostPID,p.hostBirth,p.hostHash)
    try need(try topology() == p.topology && hardware() == p.hid,"Space topology, pointer display or human input changed")
    let ids = p.topology.records.map(\.id)
    guard let a = ids.firstIndex(of:p.topology.current), let b = ids.firstIndex(of:p.target), abs(a-b) == 1 else {throw Refusal("source and target are not exactly adjacent")}
    _ = try bound(p.sourceWindow,p.topology.current); _ = try bound(p.targetWindow,p.target)
    try need(NSWorkspace.shared.frontmostApplication?.processIdentifier == p.sourceWindow.pid && axFocus(p.sourceWindow.pid) == p.sourceWindow.number,"owned source window is not precisely foreground and focused")
}
func holdOriginal() throws {
    let original=try topology(),input=hardware()
    guard AXIsProcessTrusted(),let initial=actualFocus(),let number=initial.number,let window=initial.element else {
        throw Refusal("no exact original system-wide AX foreground window to retain")
    }
    let pid=initial.pid,root=AXUIElementCreateApplication(pid),originalApp=NSRunningApplication(processIdentifier:pid)
    _=AXUIElementSetMessagingTimeout(root,0.28)
    guard let born=birth(pid),let signed=signature(pid),owner(window)==pid,exactWindowOwner(number)?.0==pid,
          (NPReadCatalogSpaceWindowNumbers(original.current) as? [UInt32])?.contains(number)==true,
          (NPReadWindowSpaces(number) as? [UInt64])?.contains(original.current)==true else {
        throw Refusal("original signed focus lacks positively matched WindowServer owner and two-way membership")
    }
    emit(["held":true,"source":"system-wide AXFocusedApplication","pid":pid,"number":number,"birth":born,"topology":try object(original),"hid":input])
    let command=readLine()?.split(separator:" ") ?? []
    guard command.first=="restore" else {return}
    guard command.count==4,let expectedPID=pid_t(command[2]),expectedPID>1,let expectedNumber=UInt32(command[3]) else {
        throw Refusal("missing latest independently witnessed foreground for restoration")
    }
    let from=UInt64(command[1])
    if let from {
        try need(original.records.contains{$0.id==from && $0.type==0} && (NPReadWindowSpaces(number) as? [UInt64])==[original.current],
                 "the retained original window is not exclusively assigned to its original Space")
    }
    // This process held its AX reference while blocked on stdin. Always ask the window server and
    // system-wide AX for the current focus after the wait; a per-process remembered focus is insufficient.
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.08))
    func verify(_ remoteAllowed:Bool) throws {
        let live=signature(pid),now=try topology()
        try need(now.display==original.display && now.records==original.records && (now.current==original.current || (remoteAllowed && now.current==from)),
                 "original physical display, current Space or complete UUID order changed")
        try need(hardware()==input,"human input changed during restoration")
        try need(birth(pid)==born && live?.0==signed.0 && live?.1==signed.1 && owner(window)==pid,"original signed process, birth or retained AX owner changed")
        let n=NPReadAXWindowNumber(window),reverse=NPReadWindowSpaces(number) as? [UInt64],forward=NPReadCatalogSpaceWindowNumbers(original.current) as? [UInt32]
        try need((n==0 || n==number) && exactWindowOwner(number)?.0==pid && forward?.contains(number)==true && reverse?.contains(original.current)==true,
                 "the original window's retained number, WindowServer owner or two-way membership changed")
        let listed=array(root,kAXWindowsAttribute).contains{CFEqual($0,window)}
        let focused=prop(root,kAXFocusedWindowAttribute).map {CFGetTypeID($0)==AXUIElementGetTypeID() && CFEqual($0,window)} ?? false
        let remote=remoteAllowed && now.current != original.current && now.current==from && reverse==[original.current]
        try need(listed || focused || remote,"the original AX window reference is no longer present or exclusively associated with its original remote Space")
    }
    func exact(_ focus:ActualFocus?)->Bool {
        guard focus?.pid==pid,focus?.number==number,let element=focus?.element else {return false}
        return owner(element)==pid && (CFEqual(element,window) || NPReadAXWindowNumber(window)==number)
    }
    var observations=[Map](),actions=[String](),attempted=false
    func observe()->ActualFocus? {
        let reading=actualFocus()
        observations.append(["uptime":ProcessInfo.processInfo.systemUptime,"systemFocus":reading?.fields as Any? ?? NSNull()])
        return reading
    }
    func answer(_ restored:Bool,_ reason:String?=nil) {
        var receipt:Map=["restored":restored,"issued":attempted,"actions":actions,"observations":observations]
        if let reason {receipt["reason"]=reason};emit(receipt)
    }
    do {
        try verify(true)
        let first=observe(),startSpace=try topology()
        if !exact(first) || startSpace != original {
            guard let first,first.pid==expectedPID, (first.number ?? 0)==expectedNumber else {
                answer(false,"foreground changed after the independent pre-restoration read");return
            }
            if first.pid != pid || startSpace != original {
                try verify(true)
                guard let app=originalApp,app.processIdentifier==pid,!app.isTerminated else {answer(false,"original running application handle was unavailable");return}
                attempted=true
                actions.append(app.activate(options:[]) ? "activation accepted" : "activation declined")
                let deadline=Date(timeIntervalSinceNow:1.8)
                while Date()<deadline {
                    try verify(true)
                    let foreground=observe()
                    if let changed=foreground?.pid,changed != pid && changed != expectedPID {
                        answer(false,"another foreground owner appeared during the original-window activation");return
                    }
                    if (try topology())==original && foreground?.pid==pid {break}
                    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.09))
                }
            }
            try verify(false)
            let beforeRaise=observe()
            guard let beforeRaise,beforeRaise.pid==pid || beforeRaise.pid==expectedPID else {
                answer(false,"the system-wide foreground changed before the retained window could be raised");return
            }
            if !exact(beforeRaise) {
                attempted=true
                actions.append("retained AXRaise = "+String(AXUIElementPerformAction(window,kAXRaiseAction as CFString).rawValue))
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.14));try verify(false)
                if let current=observe(),current.pid==pid,!exact(current) {
                    var settable=DarwinBoolean(false)
                    if AXUIElementIsAttributeSettable(root,kAXFocusedWindowAttribute as CFString,&settable) == .success && settable.boolValue {
                        actions.append("exact AXFocusedWindow = "+String(AXUIElementSetAttributeValue(root,kAXFocusedWindowAttribute as CFString,window).rawValue))
                    }
                }
            }
        }
        var consecutive=0
        let deadline=Date(timeIntervalSinceNow:1.4)
        repeat {
            try verify(false)
            consecutive=exact(observe()) ? consecutive+1:0
            if consecutive>=2 {answer(true);return}
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.11))
        } while Date()<deadline
        answer(false,"the original window did not hold system-wide focus for two independent reads")
    } catch {answer(false,(error as? Refusal)?.reason ?? String(describing:error))}
}
let arguments = Array(CommandLine.arguments.dropFirst())
var issued = false
func actOnCard(_ p:Pair,press:Bool)throws->Map {
        try guardPair(p)
        let id = "native-space-window:\(p.topology.display.uuidString):\(p.target):\(p.targetWindow.pid):\(p.targetWindow.number)"
        let card = try panelTarget(p.hostPID,id)
        try guardPair(p)
        try need(prop(card,kAXIdentifierAttribute) as? String == id && prop(card,kAXEnabledAttribute) as? Bool == true && owner(card) == p.hostPID && visibleCard(card,host:p.hostPID),"target card changed before action")
        var out:Map = ["control":id,"ready":true,"visibleHitVerified":true,"issued":false,"uptime":ProcessInfo.processInfo.systemUptime]
        if press {
            issued = true; out["issued"] = true; out["axError"] = AXUIElementPerformAction(card,kAXPressAction as CFString).rawValue; out["returnedUptime"] = ProcessInfo.processInfo.systemUptime
        }
    return out
}
func keepOwnedWindows() {
    while let line=readLine() {
        issued=false
        do {
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.012))
            let data=Data(line.utf8);guard data.count<100_000,let msg=try JSONSerialization.jsonObject(with:data) as? Map,let mode=msg["mode"] as? String else {throw Refusal("invalid window witness request")}
            let body=try JSONSerialization.data(withJSONObject:msg["body"] as Any)
            if mode=="enroll" {
                let w=try JSONDecoder().decode(Window.self,from:body),t=try topology()
                guard let r=t.records.first(where:{$0.id==t.current && $0.type==0}),let expected=msg["space"] as? UInt64,expected==r.id,
                      retainedWindows[w.number]==nil,retainedWindows.count<2 else {throw Refusal("unexpected foreground document enrollment")}
                let proof=try bound(w,r.id),g=try ownGeneration(w),cg=exactWindowOwner(w.number)
                let app=AXUIElementCreateApplication(w.pid), windows=array(app,kAXWindowsAttribute).filter {owner($0)==w.pid && NPReadAXWindowNumber($0)==w.number}
                guard windows.count==1,proof["axStandardNow"] as? Bool==true,cg?.0==w.pid,cg?.1==0,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier==w.pid,axFocus(w.pid)==w.number,
                      prop(windows[0],kAXMinimizedAttribute) as? Bool==false,prop(windows[0],"AXFullScreen") as? Bool != true else {throw Refusal("unique foreground standard window, focus and owner not confirmed together")}
                retainedWindows[w.number]=RetainedWindow(owner:w,generation:g,element:windows[0],record:r,display:t.display)
                emit(["enrolled":true,"space":r.id,"spaceUUID":r.uuid.uuidString,"ownerGeneration":g.uuidString,"initialAX":proof])
            } else if mode=="current-card" {
                let w=try JSONDecoder().decode(Window.self,from:body)
                guard let held=retainedWindows[w.number],held.owner==w,let pid=msg["hostPID"] as? pid_t,let born=msg["hostBirth"] as? UInt64,
                      let hash=msg["hostHash"] as? String,let initialHID=msg["hid"] as? [UInt32] else {throw Refusal("missing original current document enrollment or installed Host identity")}
                try signedHost(pid,born,hash)
                let current=try topology()
                try need(current.display==held.display && current.current==held.record.id && current.records.contains(held.record) && hardware()==initialHID &&
                         NSWorkspace.shared.frontmostApplication?.processIdentifier==w.pid && axFocus(w.pid)==w.number,"foreground, exact focus, Space, display or input changed while waiting for Host roster")
                _=try bound(w,held.record.id)
                let id="current-desktop-window:\(w.pid):\(w.number)",(cards,counts)=panelMatches(pid,id)
                var receipt=counts;receipt["id"]=id;receipt["uptime"]=ProcessInfo.processInfo.systemUptime;receipt["space"]=held.record.id
                if cards.count==1 {
                    let c=cards[0];var actions:CFArray?
                    receipt["role"]=prop(c,kAXRoleAttribute) as? String
                    receipt["enabled"]=prop(c,kAXEnabledAttribute) as? Bool
                    receipt["pressAction"]=AXUIElementCopyActionNames(c,&actions) == .success && (actions as? [String])?.contains(kAXPressAction)==true
                    receipt["visibleHitVerified"]=visibleCard(c,host:pid)
                }
                receipt["present"]=cards.count==1 && receipt["scanComplete"] as? Bool==true && receipt["role"] as? String==kAXButtonRole
                emit(receipt)
            } else if mode=="windows" {
                let windows=try JSONDecoder().decode([Window].self,from:body),proof=try windows.map(windowProof)
                let pid=getpid()
                guard let born=birth(pid),let exe=path(pid),let signed=signature(pid) else {throw Refusal("retained reader could not attest its own process")}
                emit(["windows":proof,"state":try snapshot(false),
                      "reader":["pid":pid,"birth":born,"executable":exe,"identifier":signed.0,"hash":signed.1]])
            } else if mode=="inspect" || mode=="press" {
                let pair=try JSONDecoder().decode(Pair.self,from:body)
                try need(retainedWindows[pair.sourceWindow.number] != nil && retainedWindows[pair.targetWindow.number] != nil,"both actual owned ordinary documents must be enrolled")
                emit(try actOnCard(pair,press:mode=="press"))
            } else {throw Refusal("unsupported witness command")}
        } catch {emit(["ready":false,"issued":issued,"error":(error as? Refusal)?.reason ?? String(describing:error)])}
    }
}
func postSetupArrow(_ key:CGKeyCode, topology expected:Topology, source window:Window, target:UInt64, hid:[UInt32],
                    finalCheck:() throws -> Void = {}) throws {
    try need(NPP0SystemArrowEnabled(Int32(key))==1 && CGPreflightPostEventAccess(),"Apple adjacent Space shortcut disabled, remapped or event posting unavailable")
    _ = try bound(window,expected.current)
    guard let source=CGEventSource(stateID:.privateState),
          let down=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:true),
          let up=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:false) else {throw Refusal("system shortcut event construction failed")}
    let flags:CGEventFlags=[.maskControl,.maskSecondaryFn,.maskNumericPad]
    down.flags=flags;up.flags=flags
    try finalCheck()
    try need(hardware()==hid && (try topology())==expected &&
             NSWorkspace.shared.frontmostApplication?.processIdentifier==window.pid && axFocus(window.pid)==window.number,
             "owned source, input or topology changed before native setup shortcut")
    issued=true;down.post(tap:.cgSessionEventTap);up.post(tap:.cgSessionEventTap)
    emit(["issued":true,"setupOnly":true,"keyCode":Int(key),"source":expected.current,"target":target,"uptime":ProcessInfo.processInfo.systemUptime])
}
func main() throws {
    guard let verb = arguments.first else {throw Refusal("missing mode")}
    #if P0_BORROWED_DIAGNOSTIC
    guard ["leased-census","leased-setup-arrow","leased-artifact-check"].contains(verb) else {
        throw Refusal("booked fixture binary only provides borrowed-lease operations")
    }
    #endif
    switch verb {
    case "watch":
        // The read-only watcher may span the visual recorder's bounded finalization.
        let end = ProcessInfo.processInfo.systemUptime + 40
        while ProcessInfo.processInfo.systemUptime < end {
            do {emit(try snapshot(true))} catch {emit(["error":String(describing:error),"uptime":ProcessInfo.processInfo.systemUptime])}
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.06))
        }
    case "keeper":keepOwnedWindows()
    case "state": emit(try snapshot(true))
    case "hold-original": try holdOriginal()
    case "process":
        guard arguments.count == 2, let pid = pid_t(arguments[1]), let exe = path(pid), let start = birth(pid), let sign = signature(pid) else {throw Refusal("process unavailable")}
        emit(["pid":pid,"executable":exe,"birth":start,"identifier":sign.0,"hash":sign.1])
    case "windows":
        let owned = try JSONDecoder().decode([Window].self,from:FileHandle.standardInput.readDataToEndOfFile()); _ = try topology()
        emit(["windows":try owned.map(windowProof)])
    case "system-arrow-enabled":
        emit(["left":NPP0SystemArrowEnabled(123)==1,"right":NPP0SystemArrowEnabled(124)==1])
    #if P0_BORROWED_DIAGNOSTIC
    case "leased-census","leased-setup-arrow","leased-artifact-check":
        try bookedOperation(verb)
    #endif
    case "setup-arrow":
        let r = try JSONDecoder().decode(Arrow.self,from:FileHandle.standardInput.readDataToEndOfFile())
        let live = try topology(), original = r.before.records, ids=live.records.map(\.id)
        guard live == r.topology, r.before.display == live.display, r.before.current == live.current,
              live.records.filter({ $0.id != r.target }) == original, !original.contains(where: { $0.id == r.target }),
              let to=ids.firstIndex(of:r.target), let from=ids.firstIndex(of:live.current), abs(from-to)==1,
              live.records[to].type==0,live.records[from].type==0,!original.contains(where:{ $0.uuid==live.records[to].uuid }) else {
            throw Refusal("setup shortcut may land only on the single new adjacent ordinary Space")
        }
        let key: CGKeyCode = to>from ? 124 : 123
        try postSetupArrow(key,topology:live,source:r.sourceWindow,target:r.target,hid:r.hid)
    case "absence":
        let ids = arguments.dropFirst().compactMap(UInt32.init)
        try need(ids.count == arguments.count-1 && !ids.isEmpty,"invalid absent-window probe"); emit(["absence":ids.map { NPReadWindowNumberPresence($0) == 0 }])
    case "inspect", "press":
        let p = try JSONDecoder().decode(Pair.self,from:FileHandle.standardInput.readDataToEndOfFile())
        emit(try actOnCard(p,press:verb=="press"))
    default: throw Refusal("unknown mode")
    }
}
do {try main()} catch {emit(["issued":issued,"ready":false,"error":(error as? Refusal)?.reason ?? String(describing:error)]) ; exit(2)}
