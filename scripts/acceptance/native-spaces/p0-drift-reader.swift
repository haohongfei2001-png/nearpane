import CryptoKit

// Dedicated acceptance executable. Emits numeric WindowServer/AX metadata and signing identities only.
func extraInput() -> [UInt32] {
    [CGEventType.mouseMoved,.keyUp,.flagsChanged,.leftMouseUp,.rightMouseUp,.otherMouseUp,.tabletPointer,.tabletProximity].map {
        CGEventSource.counterForEventType(.hidSystemState,eventType:$0)
    }
}

struct ProcessGeneration: Hashable { let pid: pid_t; let born: UInt64 }
struct SigningCache {
    var values: [ProcessGeneration: Map] = [:]
    mutating func read(_ pid: pid_t, fresh:Bool=false) -> Map? {
        guard let born=birth(pid) else {return nil}
        let key=ProcessGeneration(pid:pid,born:born)
        if !fresh,let cached=values[key] {return cached}
        guard let sign=signature(pid),let bundle=NSRunningApplication(processIdentifier:pid)?.bundleIdentifier,
              birth(pid)==born else { return ["pid":pid,"birth":born,"identityKnown":false] }
        let result:Map=["pid":pid,"birth":born,"bundle":bundle,"signingIdentifier":sign.0,"cdhash":sign.1,"identityKnown":true]
        // Bounded, volatile cache; PID reuse never inherits another incarnation's identity.
        if values.count>=100 {values.removeAll()}
        values[key]=result
        return result
    }
    mutating func system(_ bundle:String)->Map? {
        let apps=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).filter{!$0.isTerminated}
        guard apps.count==1,let app=apps.first,let result=read(app.processIdentifier),
              result["identityKnown"] as? Bool==true,result["signingIdentifier"] as? String==bundle,
              app.bundleURL?.path.hasPrefix("/System/Library/")==true else {return nil}
        return result
    }
}

final class NotificationLog: @unchecked Sendable {
    private let lock=NSLock()
    private var rows=[Map](), lost=0, tokens=[NSObjectProtocol]()
    func start() {
        let center=NSWorkspace.shared.notificationCenter
        for (name,label) in [(NSWorkspace.activeSpaceDidChangeNotification,"activeSpaceDidChange"),
                               (NSWorkspace.didActivateApplicationNotification,"didActivateApplication")] {
            tokens.append(center.addObserver(forName:name,object:nil,queue:nil){ [weak self] note in
                guard let self else {return}
                var row:Map=["kind":label,"uptime":ProcessInfo.processInfo.systemUptime]
                if let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    row["pid"]=app.processIdentifier;row["birth"]=birth(app.processIdentifier)
                }
                self.lock.withLock { if self.rows.count<256 {self.rows.append(row)} else {self.lost+=1} }
            })
        }
    }
    func drain()->([Map],Int) {
        lock.withLock { let result=(rows,lost); rows.removeAll(keepingCapacity:true);lost=0;return result }
    }
    deinit {for t in tokens {NSWorkspace.shared.notificationCenter.removeObserver(t)}}
}

struct ScopeRead {
    let known:Set<UInt64>
    var forwards=[UInt64:Set<UInt32>]()
    mutating func read(_ number:UInt32, pid:pid_t)->[UInt64]? {
        guard let owner=exactWindowOwner(number),owner.0==pid,
              let first=NPReadWindowSpaces(number) as? [UInt64],!first.isEmpty,Set(first).count==first.count,
              Set(first).isSubset(of:known) else {return nil}
        for id in first {
            if forwards[id]==nil {
                guard let list=NPReadCatalogSpaceWindowNumbers(id) as? [UInt32] else {return nil}
                forwards[id]=Set(list)
            }
            guard forwards[id]?.contains(number)==true else {return nil}
        }
        guard let second=NPReadWindowSpaces(number) as? [UInt64],Set(second)==Set(first),first.count==second.count,
              exactWindowOwner(number)?.0==pid else {return nil}
        return first.sorted()
    }
}
func ownerMembership(_ owner:ProcessGeneration, scopes:inout ScopeRead)->Map {
    let t=ProcessInfo.processInfo.systemUptime
    var result:Map=["at":t,"pid":owner.pid,"birth":owner.born,"complete":false]
    guard birth(owner.pid)==owner.born,
          let rows=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [Map] else{return result}
    let publicIDs=Set(rows.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    var owned=Set(rows.compactMap { row -> UInt32? in
        guard row[kCGWindowOwnerPID as String] as? pid_t==owner.pid,row[kCGWindowLayer as String] as? Int==0 else{return nil}
        return row[kCGWindowNumber as String] as? UInt32
    })
    var nativeIDs=Set<UInt32>(),unknown=0,seen=Set<UInt64>()
    // The public all-windows list can omit a background member. Account for those
    // omissions by exact number before treating an empty association as negative evidence.
    for id in scopes.known {
        if scopes.forwards[id]==nil {
            guard let list=NPReadCatalogSpaceWindowNumbers(id) as? [UInt32] else {unknown+=1;continue}
            scopes.forwards[id]=Set(list)
        }
        nativeIDs.formUnion(scopes.forwards[id] ?? [])
    }
    let missing=nativeIDs.subtracting(publicIDs).sorted()
    for (i,n) in missing.enumerated() {
        guard i<96,ProcessInfo.processInfo.systemUptime-t<0.075 else {unknown+=missing.count-i;break}
        guard let bound=exactWindowOwner(n) else {unknown+=1;continue}
        if bound.0==owner.pid && bound.1==0 {owned.insert(n)}
    }
    let candidates=owned.sorted()
    for (i,n) in candidates.enumerated() {
        guard i<48,ProcessInfo.processInfo.systemUptime-t<0.11 else {unknown+=candidates.count-i;break}
        if let m=scopes.read(n,pid:owner.pid) {seen.formUnion(m)} else {unknown+=1}
    }
    if unknown==0 {
        for id in scopes.known {
            guard ProcessInfo.processInfo.systemUptime-t<0.14,let again=NPReadCatalogSpaceWindowNumbers(id) as? [UInt32],
                  Set(again)==scopes.forwards[id] else {unknown+=1;break}
        }
    }
    guard birth(owner.pid)==owner.born else{return result}
    result["visibleOrBackgroundLayerZeroCount"]=owned.count;result["unresolved"]=unknown
    result["spaces"]=seen.sorted();result["complete"]=unknown==0
    return result
}

func observeDrift(seconds:Double, expectedPID:pid_t, expectedBirth:UInt64, expectedHash:String, managed:Bool)throws {
    let uptime={ProcessInfo.processInfo.systemUptime}
    var cache=SigningCache()
    guard path(expectedPID)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
          let host=cache.read(expectedPID),host["cdhash"] as? String==expectedHash,
          host["birth"] as? UInt64==expectedBirth,host["signingIdentifier"] as? String=="com.holdsnow.nearpane.alpha"
    else {throw Refusal("isolated installed Host identity unavailable")}
    let notifications=NotificationLog();notifications.start()
    let initial=hardware(), extra=extraInput(), start=uptime(), session=UUID().uuidString
    var seq=0
    func publish(_ type:String,_ t:Double,_ payload:Map=[:]){
        var row=payload;row["event"]=type;row["seq"]=seq;row["session"]=session;row["uptime"]=t
        seq+=1;emit(row)
    }
    func flush() {
        let (rows,lost)=notifications.drain()
        for var row in rows {
            let t=row.removeValue(forKey:"uptime") as! Double
            if let pid=row["pid"] as? Int32,let born=row["birth"] as? UInt64,let identity=cache.read(pid),
               identity["birth"] as? UInt64==born {row["process"]=identity}
            publish("workspaceNotification",t,row)
        }
        if lost>0 {publish("notificationLoss",uptime(),["count":lost])}
    }
    publish("started",start,["host":host,"hid":initial,"additionalHID":extra,"diagnosticSeconds":seconds])
    var census: Map?, censusTop:Topology?, last:ProcessGeneration?, reason="duration"
    while uptime()<start+seconds {
        if managed {
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&fd, 1, 0) > 0 { reason = "driverClosed"; break }
        }
        let began=uptime(), hid=hardware(), additional=extraInput()
        if initial != hid || extra != additional {
            publish("userSuperseded",began,["hid":hid,"additionalHID":additional]);reason="userSuperseded";break
        }
        guard birth(expectedPID)==expectedBirth else {reason="hostGenerationChanged";break}
        do {
            let top=try topology()
            let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
            let foreground=front.flatMap{cache.read($0,fresh:true)}, focus=AXIsProcessTrusted() ? actualFocus():nil
            var scope=ScopeRead(known:Set(top.records.map(\.id)))
            var focusData:Map?
            if let focus {
                var data=focus.fields
                let process=focus.pid==front ? foreground:cache.read(focus.pid,fresh:true)
                if let born=focus.processBirth,let process,process["birth"] as? UInt64==born {data["process"]=process}
                if let n=focus.number {data["spaces"]=scope.read(n,pid:focus.pid)}
                focusData=data
            }
            if let p=front,let born=foreground?["birth"] as? UInt64 {
                let owner=ProcessGeneration(pid:p,born:born)
                if owner != last || censusTop != top || began-(census?["at"] as? Double ?? 0)>=1 {
                    census=ownerMembership(owner,scopes:&scope);last=owner;censusTop=top
                }
            } else {census=nil;last=nil;censusTop=nil}
            let dock=cache.system("com.apple.dock"), manager=cache.system("com.apple.WindowManager")
            let again=try topology(), finalFront=NSWorkspace.shared.frontmostApplication?.processIdentifier
            let finalFocus=focus==nil ? nil:actualFocus()
            let born=foreground?["birth"] as? UInt64
            let agrees=front != nil && front==finalFront && born != nil && born==front.flatMap(birth)
            let focusStable=agrees && focus?.pid==front && focus?.processBirth==born && focus?.number != nil &&
                finalFocus?.pid==focus?.pid && finalFocus?.processBirth==born && finalFocus?.number==focus?.number
            let shape=top.records.map {String($0.id)+"/"+String($0.type)+"/"+$0.uuid.uuidString}.joined(separator:"|")
            let roster=SHA256.hash(data:Data(shape.utf8)).map {String(format:"%02x",$0)}.joined()
            let end=uptime(), finalHID=hardware(), finalExtra=extraInput()
            publish("sample",end,["began":began,"spaceStable":top==again,"display":top.display.uuidString,
                "current":top.current,"topologyHash":roster,"spaceUUID":top.records.first(where:{$0.id==top.current})!.uuid.uuidString,
                "workspaceFrontPID":front as Any? ?? NSNull(),"foreground":foreground as Any? ?? NSNull(),"foregroundStable":agrees,
                "focus":focusData as Any? ?? NSNull(),"focusStable":focusStable,
                "ownerWindows":census as Any? ?? NSNull(),"dock":dock as Any? ?? NSNull(),"windowManager":manager as Any? ?? NSNull(),
                "hid":finalHID,"additionalHID":finalExtra,"observerAX":AXIsProcessTrusted()])
            if finalHID != initial || finalExtra != extra {
                publish("userSuperseded",end,["hid":finalHID,"additionalHID":finalExtra]);reason="userSuperseded";break
            }
        } catch {publish("readUnavailable",uptime(),["began":began,"reason":"numericSystemReadUnavailable"])}
        flush()
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.075))
    }
    flush()
    publish("ended",uptime(),["reason":reason])
}

do {
    let a=Array(CommandLine.arguments.dropFirst())
    if a.count==2,a[0]=="host-generation",let pid=Int32(a[1]),let born=birth(pid),
       path(pid)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
       let s=signature(pid),s.0=="com.holdsnow.nearpane.alpha" {
        emit(["pid":pid,"birth":born,"cdhash":s.1,"signingIdentifier":s.0]);exit(0)
    }
    guard a.count==4 || (a.count==5 && a[4]=="managed"), let seconds=Double(a[0]), seconds.isFinite, (12...3600).contains(seconds),
          let pid=Int32(a[1]), let born=UInt64(a[2]), born>0, a[3].count==40 else {throw Refusal("invalid diagnostic request")}
    try observeDrift(seconds:seconds,expectedPID:pid,expectedBirth:born,expectedHash:a[3],managed:a.count==5)
} catch {emit(["event":"refused","uptime":ProcessInfo.processInfo.systemUptime,"reason":"monitorAdmissionUnavailable"]);exit(2)}
