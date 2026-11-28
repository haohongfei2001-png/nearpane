import AppKit
import ApplicationServices

struct SplitPickerMatch {
    var press: AXUIElement?
    var click: CGPoint?
    var authority: OverviewProcess?
    var byMarker = false
    var labelled = 0
    var route = "none"
    var overview = false
    var reason = "pickerEvidenceUnavailable"
    var evidence = [String:Any]()
}

private func pickerCategory(_ owner: OverviewProcess) -> String {
    switch owner.agent {
    case .dock: return "appleDock"
    case .manager: return "appleWindowManager"
    case .launcher: return "appleMissionControl"
    }
}

private func elementOwner(_ el: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(el,&pid) == .success && pid>1 ? pid:nil
}

private func systemHit(_ p: CGPoint) -> (AXUIElement?, Int32) {
    let system=AXUIElementCreateSystemWide()
    _=AXUIElementSetMessagingTimeout(system,0.17)
    var node: AXUIElement?
    let err=AXUIElementCopyElementAtPosition(system,Float(p.x),Float(p.y),&node)
    return (err == .success ? node:nil,err.rawValue)
}

private func reportedBounds(_ row: Object) -> CGRect? {
    guard let data=row[kCGWindowBounds as String] as? NSDictionary,
          let f=CGRect(dictionaryRepresentation:data), SplitPickerGeometry.valid(f) else {return nil}
    return f
}

private func liveDocumentFrame(_ number: UInt32, fixture: pid_t) -> CGRect? {
    guard let rows=PreviewCensus.windowRows(number), rows.count==1, let row=rows.first,
          row[kCGWindowNumber as String] as? UInt32==number, row[kCGWindowOwnerPID as String] as? pid_t==fixture,
          row[kCGWindowLayer as String] as? Int==0, row[kCGWindowIsOnscreen as String] as? Bool==true,
          let alpha=row[kCGWindowAlpha as String] as? Double,alpha>0 else {return nil}
    return reportedBounds(row)
}

private func frontSurface(at point: CGPoint, fixture: pid_t, number: UInt32, frame: CGRect,
                          owners:[OverviewProcess]) -> String {
    // CG supplies front-to-back screen order. Even a signed overlay blocks this route
    // when it is the top surface. Never consult foreign contents or return their IDs.
    guard let list=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Object] else {return "unavailable"}
    for row in list {
        guard let alpha=row[kCGWindowAlpha as String] as? Double, alpha.isFinite else {return "unresolved"}
        if alpha<=0 {continue}
        guard let raw=row[kCGWindowBounds as String] as? NSDictionary, let rect=CGRect(dictionaryRepresentation:raw),
              rect.origin.x.isFinite,rect.origin.y.isFinite,rect.width.isFinite,rect.height.isFinite else {return "unresolved"}
        guard rect.contains(point) else {continue}
        guard let pid=row[kCGWindowOwnerPID as String] as? pid_t,let id=row[kCGWindowNumber as String] as? UInt32 else {return "unresolved"}
        if pid==fixture {
            return id==number && row[kCGWindowLayer as String] as? Int==0 && rect==frame ? "enrolledDocumentB":"otherFixtureSurface"
        }
        return owners.first(where:{$0.pid==pid}).map(pickerCategory) ?? PreviewCensus.apple(pid) ?? "otherSurface"
    }
    return "noSurface"
}

private func documentMarker(_ document: AXUIElement, pid: pid_t, label: String, identifier: String)
    -> (rect: CGRect?, count: Int, identity: String) {
    var todo=[document], seen=Set<AXUIElement>(), markers=[(CGRect?,String)]()
    while let node=todo.popLast(),seen.count<96 {
        guard elementOwner(node)==pid,seen.insert(node).inserted else {continue}
        if value(node,kAXRoleAttribute) as? String==kAXStaticTextRole {
            let markerID=value(node,kAXIdentifierAttribute) as? String
            let raw=value(node,kAXValueAttribute)
            let text=(raw as? String) ?? (raw as? NSAttributedString)?.string
            let firstLine=text?.components(separatedBy:.newlines).first
            // The previous signed fixture exposes the nonce through its own text value.
            // The new one also exposes it as an AX identifier if the text value is unavailable.
            if markerID==identifier, firstLine==nil || firstLine==label {
                markers.append((splitFrame(node),firstLine==nil ? "nonceIdentifier":"nonceIdentifierAndValue"))
            } else if (markerID==nil || markerID==""),firstLine==label {
                markers.append((splitFrame(node),"fixtureNonceValue"))
            }
        }
        todo.append(contentsOf:value(node,kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    guard todo.isEmpty, markers.count==1 else {return (nil,markers.count,"absentAmbiguousOrTruncated")}
    return (markers[0].0,1,markers[0].1)
}

func readSplitPicker(title: String, session: UUID, screen: CGRect, fixture: pid_t, numbers: [UInt32],
                     source: AXUIElement?, target: AXUIElement?, presentNativeHalf: Bool,
                     owners:[OverviewProcess], markerOnly: Bool = false) -> SplitPickerMatch {
    var match=SplitPickerMatch(), diagnostics=[String:Any]()
    func finish(_ why:String) -> SplitPickerMatch {
        match.reason=why;match.evidence=diagnostics;return match
    }
    diagnostics["kernelOwners"]=owners.map(pickerCategory).sorted()
    guard !owners.isEmpty else {return finish("kernelPickerOwnersUnavailable")}
    var point:CGPoint?, rightEdge:CGFloat?
    if let source,let target, elementOwner(source)==fixture,elementOwner(target)==fixture,
       NPReadAXWindowNumber(source)==numbers[0], NPReadAXWindowNumber(target)==numbers[1],
       value(target,kAXTitleAttribute) as? String==title,
       let tiledAX=splitFrame(source),let logical=splitFrame(target),
       let tiledCG=liveDocumentFrame(numbers[0],fixture:fixture),
       let presented=liveDocumentFrame(numbers[1],fixture:fixture) {
        if presentNativeHalf && SplitPickerGeometry.near(tiledAX,tiledCG) &&
            screen.contains(tiledCG) && abs(tiledCG.minX-screen.minX)<=2 && tiledCG.height>=screen.height*0.90 {
            rightEdge=tiledCG.maxX
        }
        let marker=documentMarker(target,pid:fixture,label:title,identifier:"nearpane-split-marker-"+session.uuidString.lowercased()+"-b")
        diagnostics["markerCount"]=marker.count; diagnostics["markerIdentity"]=marker.identity
        if let rect=marker.rect {
            diagnostics["markerAXFrame"]=numericRect(rect)
            if presentNativeHalf {
                point=SplitPickerGeometry.markerPoint(screen:screen,tiledAX:tiledAX,tiledCG:tiledCG,
                    logical:logical,presented:presented,marker:rect)
            }
        }
        diagnostics["nativeHalfPresentation"]=point != nil
        if let p=point {
            diagnostics["markerScreenPoint"]=[p.x,p.y]
            let front=frontSurface(at:p,fixture:fixture,number:numbers[1],frame:presented,owners:owners)
            let (hit,error)=systemHit(p)
            let owner=hit.flatMap(elementOwner)
            var category="unresolved"
            if let hit,let owner {
                if owner==fixture {category=hasAncestor(hit,target,owner:fixture) ? "enrolledDocumentB":"otherFixtureElement"}
                else {category=owners.first(where:{$0.pid==owner}).map(pickerCategory) ?? PreviewCensus.apple(owner) ?? "otherOwner"}
                if owner==fixture || owners.contains(where:{$0.pid==owner}) {
                    let knownRoles=[kAXWindowRole,kAXButtonRole,kAXStaticTextRole,kAXGroupRole,kAXApplicationRole,kAXImageRole,"AXUnknown"]
                    let role=value(hit,kAXRoleAttribute) as? String ?? ""
                    diagnostics["markerHitRole"]=knownRoles.contains(role) ? role:"otherRole"
                }
            }
            diagnostics["markerFirstSurface"]=front; diagnostics["markerHitOwner"]=category;diagnostics["markerAXHitStatus"]=error
            let enrolled=owners.first(where:{$0.pid==owner})
            let verified=enrolled.map{ (try? $0.verify()) != nil }==true
            if let route=SplitPickerGeometry.presentedRoute(top:front,hit:category,enrolledSystemHit:verified) {
                match.click=p;match.route=route;match.byMarker=true;match.authority=enrolled
            }
        }
    } else {diagnostics["documentGeometryOrIdentityUnavailable"]=true}

    if markerOnly {return finish(match.byMarker ? "verifiedPresentedFixtureMarker":"immediatePresentedMarkerChange")}

    // The system AX service can withhold the candidate list from AXWindows. Seed
    // only verified system ancestors of the measured document marker as well as the
    // owners' AX roots. Candidate text is compared in memory and never recorded.
    var press=Set<AXUIElement>(), hits=[AXUIElement:CGPoint](), labels=Set<AXUIElement>()
    var visitedByOwner=[String:Int](), limited=[String](), pressOwners=[AXUIElement:OverviewProcess]()
    for owner in owners {
        guard (try? owner.verify()) != nil else {continue}
        let root=AXUIElementCreateApplication(owner.pid)
        _=AXUIElementSetMessagingTimeout(root,0.12)
        let roots=(value(root,kAXWindowsAttribute) as? [AXUIElement] ?? [])+[root]
        var todo=roots.map {($0,false)}, seen=Set<AXUIElement>()
        if let point {
            var next=systemHit(point).0
            for _ in 0..<12 {
                guard let node=next,owner.owns(node) else {break}
                todo.append((node,false));next=keyPoint(node)
            }
        }
        let until=ProcessInfo.processInfo.systemUptime+0.38
        while !todo.isEmpty,seen.count<600,ProcessInfo.processInfo.systemUptime<until {
            let (node,insideWindowList)=todo.removeLast()
            guard owner.owns(node),seen.insert(node).inserted else {continue}
            let role=value(node,kAXRoleAttribute) as? String ?? ""
            guard ![kAXTextAreaRole,kAXTextFieldRole,"AXSecureTextField","AXWebArea"].contains(role) else {continue}
            let id=value(node,kAXIdentifierAttribute) as? String
            if id=="mc" || id=="mc.display" {match.overview=true}
            // Menu bar or Dock context-menu entries with a matching title are never
            // picker controls. Only actionable selection roles or thumbnail entries count.
            if [kAXMenuBarRole,kAXMenuRole,kAXMenuItemRole,kAXMenuBarItemRole,"AXDockItem"].contains(role) {continue}
            let semanticRoles=[kAXButtonRole,kAXGroupRole,kAXRadioButtonRole,kAXImageRole,"AXCell","AXRow","AXWindow","AXUnknown"]
            let rect=splitFrame(node)
            let inPickerPane=rightEdge.flatMap { edge in
                rect.map { f in screen.contains(f) && f.minX>=edge-2 && f.width>2 && f.height>2 }
            }==true
            // Never open recent windows, menu items, another display or a Dock icon.
            // Text comparison is confined to the selectable side of the authenticated
            // fullscreen picker, or to the signed Mission Control window-list branch.
            let isWindowsBranch=insideWindowList || id=="mc.windows"
            if (inPickerPane || isWindowsBranch),semanticRoles.contains(role),[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].contains(where:{
                guard let text=value(node,$0) as? String else {return false}
                return SplitPickerGeometry.mentionsDocument(text,title:title)
            }) {
                labels.insert(node)
                if supportedPress(node) {press.insert(node);pressOwners[node]=owner}
                if let rect,screen.contains(rect),rect.width>2,rect.height>2 {
                    let center=CGPoint(x:rect.midX,y:rect.midY)
                    if let hit=systemHit(center).0,hasAncestor(hit,node,owner:owner.pid) {hits[node]=center;pressOwners[node]=owner}
                }
            }
            let children=value(node,kAXChildrenAttribute) as? [AXUIElement] ?? []
            todo.append(contentsOf:children.map{($0,isWindowsBranch)})
        }
        let name=pickerCategory(owner)
        visitedByOwner[name]=seen.count
        if !todo.isEmpty {limited.append(name)}
    }
    diagnostics["scannedOwnerNodes"]=visitedByOwner;diagnostics["budgetLimitedOwners"]=limited.sorted()
    diagnostics["semanticPresses"]=press.count;diagnostics["semanticHits"]=hits.count
    match.labelled=labels.count
    if labels.count>1 {
        match.click=nil;match.byMarker=false;match.authority=nil;match.route="none"
        return finish("multipleSignedPickerEntriesMatchedFixture")
    }
    if let candidate=press.first,let owner=pressOwners[candidate],(limited.isEmpty || hits[candidate] != nil),(try? owner.verify()) != nil {
        match.press=candidate;match.click=nil;match.route="systemAXPress";match.authority=owner;match.byMarker=false
        return finish("uniqueSignedSystemEntry")
    }
    if let (candidate,p)=hits.first,let owner=pressOwners[candidate],(try? owner.verify()) != nil {
        match.click=p;match.route="exactSystemAXHit";match.authority=owner;match.byMarker=false
        return finish("uniqueSignedSystemEntryHit")
    }
    if match.byMarker {return finish("verifiedPresentedFixtureMarker")}
    if diagnostics["documentGeometryOrIdentityUnavailable"] != nil {return finish("pickerDocumentGeometryOrIdentityUnavailable")}
    if diagnostics["markerCount"] as? Int != 1 || diagnostics["markerAXFrame"]==nil {return finish("pickerFixtureNonceMarkerUnavailable")}
    if point==nil {return finish("pickerNativeHalfPresentationUnverified")}
    if diagnostics["markerFirstSurface"] as? String != "enrolledDocumentB" {return finish("pickerFixtureMarkerOccludedOrUnresolved")}
    return finish("pickerFixtureMarkerAXHitUnconfirmed")
}
