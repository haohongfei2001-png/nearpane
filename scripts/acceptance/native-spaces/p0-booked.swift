import CryptoKit

private struct BookedSpace:Decodable {let space:UInt64,uuid:UUID,receipt:String,digest:String}
private struct BookedDocument:Decodable {let space:UInt64,window:Window}
private struct BookedStageSurface:Decodable {let space:UInt64,number:UInt32,pid:pid_t,ownerBirth:UInt64,bounds:[Double]}
private struct BookedPair:Decodable {
    let topology:Topology,target:UInt64,hostPID:pid_t,hostBirth:UInt64,hostHash:String,hid:[UInt32],boot:String
    let leases:[BookedSpace],documents:[BookedDocument],stageSurfaces:[BookedStageSurface]
}

private func permittedOther(_ member:Map,_ sid:UInt64,_ host:pid_t)->Bool {
    guard member["forward"] as? [UInt64]==[sid],member["reverse"] as? [UInt64]==[sid],
          let pid=member["pid"] as? pid_t,pid>1,let code=member["code"] as? Map,let layer=member["layer"] as? Int else {return false}
    if pid==host {
        return member["installedHost"] as? Bool==true && (layer==0 || layer==3) && code["identifier"] as? String=="com.holdsnow.nearpane.alpha"
    }
    guard member["installedHost"] as? Bool==false && code["apple"] as? Bool==true else {return false}
    return (layer == -1 && code["identifier"] as? String=="com.apple.dock") ||
           (layer==24 && code["identifier"] as? String=="com.apple.WindowServer" && member["onscreen"] as? Bool==false && member["visibleQuery"] as? Bool==false)
}

private func checkReceipt(_ lease:BookedSpace,_ pair:BookedPair) throws {
    let file=URL(fileURLWithPath:lease.receipt),dir=file.deletingLastPathComponent()
    guard file.lastPathComponent=="created.json",dir.lastPathComponent=="provision",
          UUID(uuidString:dir.deletingLastPathComponent().lastPathComponent) != nil,
          dir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent=="secondary-route-followup",
          let real=realpath(lease.receipt,nil) else {throw Refusal("unrecognized native Space creation receipt")}
    defer {free(real)}
    var info=stat(),removed=stat()
    let fd=Darwin.open(lease.receipt,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
    guard fd >= 0 else {throw Refusal("leased creation receipt unavailable")}
    let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
    try need(String(cString:real)==lease.receipt && fstat(fd,&info)==0 && info.st_mode&S_IFMT==S_IFREG &&
             info.st_uid==getuid() && info.st_mode&0o077==0 && info.st_nlink==1 && (1...131072).contains(info.st_size) &&
             lstat(dir.appendingPathComponent("removed.json").path,&removed) != 0 && errno==ENOENT,"unsafe or removed native lease")
    let data=handle.readDataToEndOfFile()
    guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==lease.digest,
          let row=try JSONSerialization.jsonObject(with:data) as? Map,let intent=row["intent"] as? Map,
          row["target"] as? String==String(lease.space),intent["boot"] as? String==pair.boot,
          UUID(uuidString:intent["display"] as? String ?? "")==pair.topology.display,
          let after=row["after"] as? Map,let uuids=after["spaceUUIDs"] as? [String:String],
          UUID(uuidString:uuids[String(lease.space)] ?? "")==lease.uuid else {throw Refusal("creation digest, boot, display or enrolled Space UUID changed")}
}

private func approvedStageSurface(_ s:BookedStageSurface,screen:CGRect,visible:Set<UInt32>,published:Set<UInt32>) throws {
    let id="com.apple.WindowManager",exe="/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
    var code:SecCode?,req:SecRequirement?,raw=UnsafeRawPointer(bitPattern:UInt(s.number))
    guard path(s.pid)==exe,birth(s.pid)==s.ownerBirth,
          SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:s.pid] as CFDictionary,[],&code)==errSecSuccess,let code,
          SecRequirementCreateWithString(("anchor apple and identifier \""+id+"\"") as CFString,[],&req)==errSecSuccess,let req,
          SecCodeCheckValidity(code,[],req)==errSecSuccess,let ids=CFArrayCreate(nil,&raw,1,nil),
          let rows=CGWindowListCreateDescriptionFromArray(ids) as? [Map],rows.count==1,let row=rows.first,
          row[kCGWindowNumber as String] as? UInt32==s.number,row[kCGWindowOwnerPID as String] as? pid_t==s.pid,
          row[kCGWindowLayer as String] as? Int==0,let b=row[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:b),
          p2StageBoundsMatch(rect,on:screen,enrolled:s.bounds),NPReadWindowSpaces(s.number) as? [UInt64]==[s.space],
          (NPReadCatalogSpaceWindowNumbers(s.space) as? [UInt32])?.contains(s.number)==true else {throw Refusal("enrolled WindowManager identity, geometry or membership changed")}
    let app=AXUIElementCreateApplication(s.pid);_=AXUIElementSetMessagingTimeout(app,0.25)
    guard let windows=prop(app,kAXWindowsAttribute) as? [AXUIElement],windows.count<=128,
          windows.allSatisfy({owner($0)==s.pid && prop($0,kAXRoleAttribute) as? String==kAXWindowRole && NPReadAXWindowNumber($0)>0}),
          p2StageHidden(metadata:row[kCGWindowIsOnscreen as String],cg:visible.contains(s.number),appKit:published.contains(s.number),
                        ax:windows.contains(where:{NPReadAXWindowNumber($0)==s.number})),birth(s.pid)==s.ownerBirth
    else {throw Refusal("enrolled Stage surface now participates in a public document or display")}
}

private func bookedCensus(_ r:BookedPair) throws -> Map {
    let live=try topology(),ids=live.records.map(\.id),pairIDs=Set(r.leases.map(\.space))
    var boot=[CChar](repeating:0,count:128),size=boot.count
    let stage=CFPreferencesCopyAppValue("GloballyEnabled" as CFString,"com.apple.WindowManager" as CFString)
    guard sysctlbyname("kern.bootsessionuuid",&boot,&size,nil,0)==0,String(cString:boot)==r.boot,
          ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]==nil,let home=getpwuid(getuid())?.pointee.pw_dir,NSHomeDirectory()==String(cString:home),
          let stage,CFGetTypeID(stage)==CFBooleanGetTypeID(),stage as? Bool==false,live==r.topology,r.hid.count==8,hardware()==r.hid,
          NSScreen.screens.count==1,r.leases.count==2,pairIDs==Set([live.current,r.target]),
          let i=ids.firstIndex(of:live.current),let j=ids.firstIndex(of:r.target),abs(i-j)==1,
          r.leases.allSatisfy({a in live.records.contains{v in v.id==a.space && v.uuid==a.uuid && v.type==0}}),
          r.documents.count<=2,r.documents.allSatisfy({pairIDs.contains($0.space)}),
          Set(r.documents.map(\.space)).count==r.documents.count,Set(r.documents.map{$0.window.pid}).count==r.documents.count,
          r.stageSurfaces.count<=8,Set(r.stageSurfaces.map(\.number)).count==r.stageSurfaces.count,
          r.stageSurfaces.allSatisfy({pairIDs.contains($0.space)}) else {throw Refusal("Stage, boot, screen, physical input or adjacent ordinary lease identity changed")}
    try signedHost(r.hostPID,r.hostBirth,r.hostHash)
    for lease in r.leases {try checkReceipt(lease,r)}
    guard let scope=NPContractMemberReport(Array(pairIDs) as CFArray,r.hostPID) as? Map,
          let visible=NPContractOnscreenWindowNumbers() as? [UInt32],let published=NSWindow.windowNumbers(options:.allApplications)
    else {throw Refusal("independent no-pixel window census unavailable")}
    let on=Set(visible),publicIDs=Set(published.map(\.uint32Value))
    var counts=Map()
    for lease in r.leases {
        let sid=lease.space,doc=r.documents.first{$0.space==sid}?.window
        guard let row=scope[String(sid)] as? Map,row["unresolved"] as? Int==0,let ordinary=row["ordinary"] as? [Map],
              let other=row["otherDetails"] as? [Map],other.count==row["otherMembers"] as? Int else {throw Refusal("unknown window membership on booked endpoint")}
        if let w=doc {
            _=try ownGeneration(w)
            let signed=signature(w.pid)
            try need(["net.example.spaces-document","net.example.spaces-route-witness"].contains(w.identifier) &&
                     w.executable.hasPrefix("/private/tmp/nearpane-d01.") && path(w.pid)==w.executable && birth(w.pid)==w.birth &&
                     signed?.0==w.identifier && signed?.1==w.hash && exactWindowOwner(w.number)?.0==w.pid &&
                     NPReadWindowSpaces(w.number) as? [UInt64]==[sid] && (NPReadCatalogSpaceWindowNumbers(sid) as? [UInt32])?.contains(w.number)==true &&
                     ordinary.filter({$0["number"] as? UInt32==w.number && $0["pid"] as? pid_t==w.pid}).count==1,"owned fixture generation or exact membership changed")
        }
        var present=Set<UInt32>()
        let surfaces=r.stageSurfaces.filter{$0.space==sid}
        for member in ordinary {
            if let d=doc,member["number"] as? UInt32==d.number && member["pid"] as? pid_t==d.pid {continue}
            guard let s=surfaces.first(where:{$0.number==member["number"] as? UInt32 && $0.pid==member["pid"] as? pid_t}),
                  present.insert(s.number).inserted else {throw Refusal("unregistered ordinary window on booked endpoint")}
            try approvedStageSurface(s,screen:CGDisplayBounds(CGMainDisplayID()),visible:on,published:publicIDs)
        }
        for s in surfaces where !present.contains(s.number) {
            try need(NPReadWindowNumberPresence(s.number)==0 && !on.contains(s.number) && !publicIDs.contains(s.number),"old Stage window disappeared from scoped results only")
        }
        try need(other.allSatisfy{permittedOther($0,sid,r.hostPID)},"unqualified extra window on booked endpoint")
        counts[String(sid)]=["fixture":doc == nil ? 0:1,"inactiveStage":present.sorted(),"systemOrHost":other.count,"unresolved":0] as Map
    }
    try signedHost(r.hostPID,r.hostBirth,r.hostHash)
    try need((try topology())==live && hardware()==r.hid,"Space or HID changed during booked census")
    return ["status":"READ","counts":counts,"current":live.current,"display":live.display.uuidString,"pixels":0,"uptime":ProcessInfo.processInfo.systemUptime]
}

func bookedOperation(_ verb:String) throws {
    let input=FileHandle.standardInput.readData(ofLength:32769)
    try need(input.count<=32768,"oversized lease request")
    let pair=try JSONDecoder().decode(BookedPair.self,from:input)
    if verb=="leased-artifact-check" {
        for lease in pair.leases {try checkReceipt(lease,pair)}
        guard let request=try JSONSerialization.jsonObject(with:input) as? Map,let rows=request["otherDetails"] as? [Map] else {
            throw Refusal("offline artifact rows absent")
        }
        emit(["receiptCount":pair.leases.count,"classifiedOther":rows.map{permittedOther($0,pair.target,pair.hostPID)},"issued":false,"pixels":0])
        return
    }
    let first=try bookedCensus(pair)
    if verb=="leased-census" {emit(first);return}
    guard pair.documents.count==1,let source=pair.documents.first,source.space==pair.topology.current,
          let from=pair.topology.records.firstIndex(where:{$0.id==source.space}),
          let to=pair.topology.records.firstIndex(where:{$0.id==pair.target}) else {throw Refusal("setup shortcut requires one enrolled foreground fixture and an empty leased neighbor")}
    try postSetupArrow(to>from ? 124:123,topology:pair.topology,source:source.window,target:pair.target,hid:pair.hid) {
        _=try bookedCensus(pair)
        let focused=actualFocus()
        try need(focused?.pid==source.window.pid && focused?.number==source.window.number,"system-wide AX source focus changed before setup")
    }
}
