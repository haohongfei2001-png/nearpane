// Appended to the existing independent observer; only fixture identities, card geometry and counts leave this process.
func pairedPreviewProof(_ args: [String]) -> Object {
    var out: Object = ["ready":false,"stageManager":stage as Any? ?? NSNull(),"observerAX":AXIsProcessTrusted(),
                       "observerScreen":CGPreflightScreenCaptureAccess()]
    out["hardware"]=[.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map{CGEventSource.counterForEventType(.hidSystemState,eventType:$0)}
    func stop(_ reason:String) -> Object { out["reason"]=reason; return out }
    guard args.count == 3 || args.count == 10, let pid = Int32(args[1]), let host, host.processIdentifier == pid,
          let hostBirth = birthMicroseconds(pid), runningCodeHash(pid) == args[2] else { return stop("installedHostIdentityUnavailable") }
    out["hostPID"]=pid; out["hostBirth"]=hostBirth; out["hostHash"]=args[2]
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { return stop("observerPermissionUnavailable") }
    guard let scopes=inventory(requireComplete:true),scopes.count==1,let display=scopes[0]["scope"] as? String,
          let space=scopes[0]["current"] as? UInt64,let records=scopes[0]["records"] as? [Object],
          records.contains(where:{$0["id"] as? UInt64==space && $0["type"] as? Int==0}),NSScreen.screens.count==1 else {
        return stop("requiresSingleObservedOrdinarySpace")
    }
    out["display"]=display;out["space"]=space
    let index=Sidebar(host,rows:rows)
    func frame(_ el:AXUIElement)->CGRect? {
        guard let p=value(el,kAXPositionAttribute),let s=value(el,kAXSizeAttribute),CFGetTypeID(p)==AXValueGetTypeID(),
              CFGetTypeID(s)==AXValueGetTypeID() else {return nil}
        var a=CGPoint.zero,b=CGSize.zero
        return AXValueGetValue(p as! AXValue,.cgPoint,&a) && AXValueGetValue(s as! AXValue,.cgSize,&b) ? CGRect(origin:a,size:b):nil
    }
    func bounds(_ row:Object)->CGRect? {(row[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))}
    guard index.areas==1,let region=index.regions.first,let regionFrame=frame(region),regionFrame.width>25,regionFrame.height>20 else {
        return stop(stage==true ? "sidebarUnavailableWithStageManagerOn":"sidebarUnavailable")
    }
    let panels=rows.filter { $0[kCGWindowOwnerPID as String] as? pid_t==pid && $0[kCGWindowIsOnscreen as String] as? Bool==true &&
        $0[kCGWindowLayer as String] as? Int==Int(CGWindowLevelForKey(.floatingWindow)) && bounds($0)?.contains(regionFrame.insetBy(dx:1,dy:1))==true }
    guard panels.count==1,let panel=panels[0][kCGWindowNumber as String] as? UInt32 else {
        return stop(stage==true ? "sidebarUnavailableWithStageManagerOn":"visiblePanelUnavailable")
    }
    out["panel"]=panel
    let cards=index.controls.filter{$0.key.hasPrefix("current-desktop-window:") || $0.key.hasPrefix("native-space-window:")}
    out["hostCardCount"]=cards.count
    if args.count==3 {
        let census=PreviewCensus.report(space,host:pid,fixture:0,expected:[],visible:false)
        out["windowCensus"]=census;out["ordinaryCount"]=census["rawOrdinary"]
        out["ready"]=census["admitted"] as? Bool==true && cards.isEmpty
        if out["ready"] as? Bool != true {out["reason"]="activeSpaceContainsOtherWindows"};return out
    }
    guard let fixture=Int32(args[3]),let birth=UInt64(args[4]),birthMicroseconds(fixture)==birth,
          runningCodeHash(fixture)==args[5],let a=UInt32(args[7]),let b=UInt32(args[8]),a>0,b>0,a != b,
          let required=UInt64(args[9]),required==space else {return stop("fixtureOrDesktopGenerationChanged")}
    var executable=[CChar](repeating:0,count:4096)
    guard proc_pidpath(fixture,&executable,UInt32(executable.count))>0,String(cString:executable)==args[6],
          args[6].hasPrefix("/private/tmp/nearpane-d01."),args[6].hasSuffix("/Field Notes.app/Contents/MacOS/FieldNotes") else {return stop("unexpectedFixtureExecutable")}
    let nums=[a,b],ids=nums.map{"current-desktop-window:\(fixture):\($0)"}
    out["fixturePID"]=fixture;out["fixtureBirth"]=birth;out["fixtureHash"]=args[5];out["numbers"]=nums
    out["present"]=ids.map{cards[$0]?.count==1}
    let windowCensus=PreviewCensus.report(space,host:pid,fixture:fixture,expected:nums,visible:true)
    let reg=NSRunningApplication(processIdentifier:fixture)
    let expectedApp=URL(fileURLWithPath:args[6]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundleMatches=reg?.bundleURL?.resolvingSymlinksInPath().path==expectedApp.resolvingSymlinksInPath().path
    let regular=reg?.activationPolicy == .regular && reg?.bundleIdentifier=="net.example.spaces-document" && bundleMatches
    out["launchServices"]=["registered":reg != nil,"regular":reg?.activationPolicy == .regular,"bundleMatches":bundleMatches,
                            "signedBundleIdentifierMatches":reg?.bundleIdentifier=="net.example.spaces-document"]
    out["windowCensus"]=windowCensus;out["ordinaryCount"]=windowCensus["rawOrdinary"]
    out["sourceProven"]=windowCensus["expectedProven"] as? Bool==true && regular
    guard regular else{return stop("fixtureLaunchServicesRegistrationUnconfirmed")}
    guard windowCensus["expectedProven"] as? Bool==true else {return stop("activeSpaceContainsUnexpectedMembers")}
    guard Set(cards.keys)==Set(ids),ids.allSatisfy({cards[$0]?.count==1}) else {return stop("missingOrUnexpectedSidebarCard")}
    var sources=[[Double]](),pictures=[[Double]](),kinds=[String]()
    for (i,n) in nums.enumerated() {
        let records=rows.filter{$0[kCGWindowNumber as String] as? UInt32==n && $0[kCGWindowOwnerPID as String] as? Int32==fixture &&
            $0[kCGWindowLayer as String] as? Int==0 && $0[kCGWindowIsOnscreen as String] as? Bool==true}
        guard records.count==1,let source=bounds(records[0]),source.width>=96,source.height>=90,
              NPReadWindowSpaces(n) as? [UInt64]==[space],let card=cards[ids[i]]?.first,let cardFrame=frame(card),
              let label=value(card,kAXValueAttribute) as? String,let kind=label.components(separatedBy:"，").first,
              let proof=fixturePictureCrop(card:card,bounds:cardFrame,text:label,host:pid,number:n,birth:birth,scope:display,current:space,paired:true),
              proof["number"] as? UInt32==panel,let picture=proof["crop"] as? [Double] else {return stop("boundPictureGeometryUnavailable")}
        sources.append([floor(source.midX)-2,floor(source.midY)-2,4,4]);pictures.append(picture);kinds.append(kind)
    }
    let cardRects=pictures.map { CGRect(x:$0[0],y:$0[1],width:4,height:4) },strip=cardRects[0].union(cardRects[1])
    guard !cardRects[0].intersects(cardRects[1]),strip.width<=8,strip.height<=400,regionFrame.contains(strip) else{return stop("pairedCardStripOutsideControlledRoster")}
    #if PAIRED_OVERVIEW
    out["overview"] = pairedOverviewScope(index,region:region,regionFrame:regionFrame,panel:panel,display:display,
                                         space:space,ids:ids,windows:nums,fixture:fixture,hostPID:pid,pictures:pictures)
    #endif
    out["sources"]=sources;out["pictures"]=pictures;out["kinds"]=kinds;out["ready"]=true;return out
}
print(String(decoding:try JSONSerialization.data(withJSONObject:pairedPreviewProof(CommandLine.arguments),options:.sortedKeys),as:UTF8.self))
