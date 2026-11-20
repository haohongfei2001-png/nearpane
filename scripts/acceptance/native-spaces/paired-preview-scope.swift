// Read only the two enrolled controls. Bound the numerical evidence and never serialize AX strings from documents.
func pairedRect(_ node:AXUIElement)->CGRect? {
    guard let position=value(node,kAXPositionAttribute),let size=value(node,kAXSizeAttribute),
          CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else{return nil}
    var point=CGPoint.zero,extent=CGSize.zero
    guard AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(size as! AXValue,.cgSize,&extent),
          [point.x,point.y,extent.width,extent.height].allSatisfy(\.isFinite),extent.width>0,extent.height>0 else{return nil}
    return CGRect(origin:point,size:extent)
}
func pairedAX(_ node:AXUIElement)->Object {
    let raw=value(node,kAXValueAttribute)
    let text=(raw as? String) ?? (raw as? NSAttributedString)?.string
    let known=["窗口画面","窗口轮廓","上次画面","所选快照"]
    var result:Object=["kind":known.first(where:{text?.hasPrefix($0)==true}) ?? "unreported",
                       "valueType":raw==nil ? "absent" : text != nil ? "text" : raw is NSNumber ? "number":"other"]
    if let text {
        let regex=try? NSRegularExpression(pattern:#"预览\s*(\d+)\s*[×x]\s*(\d+)\s*pt"#)
        let ns=text as NSString
        if let match=regex?.firstMatch(in:text,range:NSRange(location:0,length:ns.length)),
           let w=Double(ns.substring(with:match.range(at:1))),let h=Double(ns.substring(with:match.range(at:2))),w>0,h>0 {
            result["declaredPreviewPoints"]=[w,h]
        }
        result["sizePending"]=text=="窗口尺寸待核对"
    }
    return result
}
func pairedCard(_ card:AXUIElement,host:pid_t,panel:UInt32,region:CGRect,panelFrame:CGRect,id:String)->Object {
    func role(_ el:AXUIElement)->String {
        let r=value(el,kAXRoleAttribute) as? String ?? "unknown"
        return ["AXWindow","AXButton","AXGroup","AXImage","AXStaticText","AXScrollArea","AXCell","AXLayoutItem"].contains(r) ? r:"other"
    }
    func owned(_ el:AXUIElement)->Bool {var p:pid_t=0;return AXUIElementGetPid(el,&p) == .success && p==host}
    var out:Object=["role":role(card),"axValue":pairedAX(card),"panelBound":false,"geometryReady":false]
    func stop(_ why:String)->Object { out["reason"]=why;return out }
    guard owned(card),value(card,kAXIdentifierAttribute) as? String==id else{return stop("cardIdentityChanged")}
    let descendants=(value(card,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(12).filter(owned)
    out["children"]=descendants.map{el -> Object in
        var data:Object=["role":role(el),"axValue":pairedAX(el)]
        if let r=pairedRect(el){data["frame"]=windowReceiptRect(r)};return data
    }
    let buttons=descendants.filter{role($0)=="AXButton"}
    let semantic=role(card)=="AXButton" ? card : buttons.count==1 ? buttons.first : nil
    let rect=pairedRect(card) ?? semantic.flatMap(pairedRect)
    if let rect {out["frame"]=windowReceiptRect(rect)}
    if (out["axValue"] as? Object)?["kind"] as? String=="unreported",let semantic {
        let detail=pairedAX(semantic)
        if detail["kind"] as? String != "unreported"{out["axValue"]=detail}
    }
    func element(_ raw:CFTypeRef?)->AXUIElement? {
        guard let raw,CFGetTypeID(raw)==AXUIElementGetTypeID() else{return nil};return (raw as! AXUIElement)
    }
    var ancestor:AXUIElement?=card,seen=Set<AXUIElement>(),panelBound=false
    for _ in 0..<40 {
        guard let a=ancestor,owned(a),seen.insert(a).inserted else{break}
        if role(a)=="AXWindow" && NPReadAXWindowNumber(a)==panel {panelBound=true;break}
        if let parentWindow=element(value(a,kAXWindowAttribute)),owned(parentWindow),NPReadAXWindowNumber(parentWindow)==panel {
            panelBound=true;break
        }
        ancestor=element(value(a,kAXParentAttribute))
    }
    out["panelBound"]=panelBound
    guard panelBound else{return stop("enrolledAXCardWindowDoesNotMatchSignedPanel")}
    guard let rect,rect.width>=12,rect.height>=28 else{return stop("enrolledAXCardFrameUnavailableOrClipped")}
    let panelRegion=rect.intersection(region).intersection(panelFrame)
    guard !panelRegion.isNull else{return stop("enrolledAXCardFrameUnavailableOrClipped")}
    let ownImage=descendants.filter{role($0)=="AXImage"}.compactMap(pairedRect).filter{
        rect.contains($0) && $0.width>=24 && $0.height>=20
    }
    // The production VStack has one picture and an 18-point caption below it. The measured
    // ROI comes from the real AX card and an actual source-colored panel frame proves its content.
    let content=ownImage.count==1 ? ownImage[0] : CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height-18)
    let interior=content.insetBy(dx:2,dy:2).intersection(panelRegion)
    guard interior.width>=8,interior.height>=8 else{return stop("noInteriorOfBoundCardVisibleAboveCaption")}
    let patch=CGRect(x:floor(interior.midX)-2,y:floor(interior.midY)-2,width:4,height:4)
    guard content.contains(patch),region.contains(patch),panelFrame.contains(patch),interior.contains(patch) else{return stop("cardInteriorOutsideVisiblePanel")}
    out["pictureFrame"]=windowReceiptRect(content);out["patch"]=windowReceiptRect(patch);out["geometryReady"]=true
    out["geometrySource"]=ownImage.count==1 ? "AXImageChild":"boundCardAboveFixedCaption"
    return out
}

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
    out["exactCardIDs"]=true
    guard let panelFrame=bounds(panels[0]) else{return stop("boundCGPanelGeometryUnavailable")}
    var evidence=[Object](),sources=[[Double]](),pictures=[[Double]](),kinds=[String]()
    for (i,n) in nums.enumerated() {
        guard let card=cards[ids[i]]?.first else{return stop("boundCardIdentityLost")}
        var row=pairedCard(card,host:pid,panel:panel,region:regionFrame,panelFrame:panelFrame,id:ids[i])
        let kind=(row["axValue"] as? Object)?["kind"] as? String ?? "unreported"
        kinds.append(kind)
        let record=PreviewCensus.windowRows(n)?.filter {
            $0[kCGWindowNumber as String] as? UInt32==n && $0[kCGWindowOwnerPID as String] as? pid_t==fixture &&
            $0[kCGWindowLayer as String] as? Int==0 && $0[kCGWindowIsOnscreen as String] as? Bool==true
        }
        if record?.count==1,let source=record?.first.flatMap(bounds),source.width>=96,source.height>=90,NPReadWindowSpaces(n) as? [UInt64]==[space] {
            let sample:[Double]=[floor(source.midX)-2,floor(source.midY)-2,4,4]
            row["sourcePatch"]=sample;row["sourceFrame"]=windowReceiptRect(source);sources.append(sample)
        }
        if let patch=row["patch"] as? [Double] {pictures.append(patch)}
        row["number"]=n;evidence.append(row)
    }
    out["cardIdentityProven"]=evidence.allSatisfy{$0["panelBound"] as? Bool==true};out["cardGeometry"]=evidence;out["sources"]=sources;out["kinds"]=kinds;out["pictures"]=pictures
    guard sources.count==2 else{return stop("twoExactSourceCGFramesUnavailable")}
    guard pictures.count==2 else{return stop(evidence.first(where:{$0["geometryReady"] as? Bool != true})?["reason"] as? String ?? "boundCardInteriorUnavailable")}
    out["pictureInteriorsProven"]=true
    let cardRects=pictures.map { CGRect(x:$0[0],y:$0[1],width:4,height:4) },strip=cardRects[0].union(cardRects[1])
    #if PAIRED_OVERVIEW
    out["overview"] = pairedOverviewScope(index,region:region,regionFrame:regionFrame,panel:panel,display:display,
                                         space:space,ids:ids,windows:nums,fixture:fixture,hostPID:pid,pictures:pictures,geometry:evidence)
    #endif
    guard !cardRects[0].intersects(cardRects[1]),strip.width<=8,strip.height<=400,regionFrame.contains(strip) else{return stop("pairedCardStripOutsideControlledRoster")}
    out["sources"]=sources;out["pictures"]=pictures;out["kinds"]=kinds;out["ready"]=true;return out
}
print(String(decoding:try JSONSerialization.data(withJSONObject:pairedPreviewProof(CommandLine.arguments),options:.sortedKeys),as:UTF8.self))
