// Live observations of a single new window of the installed isolated Host. Keep prospective images in memory.
import AppKit
import ApplicationServices
import Vision

@_silgen_name("_AXUIElementGetWindow")
private func selectionAXWindow(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

struct TranslationSourceWitness {
    let checks:[String:Bool]
    let foreground:String, axForeground:String
    let leftForHost:Bool
    var confirmed:Bool { !checks.isEmpty && checks.values.allSatisfy { $0 } }
}

@MainActor func translationSource(_ fixture:ToolWindow, _ pid:pid_t, _ number:CGWindowID,
                                  _ field:AXUIElement, _ phrase:String, host:pid_t) -> TranslationSourceWitness {
    let state = fixture.selectionState() ?? [:]
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system,0.18)
    let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
    func ownerClass(_ observed:pid_t?) -> String {
        guard let observed,observed>0 else{return "unavailable"}
        if observed==pid {return "fixture"}
        if observed==host {return "installedHost"}
        return observed==getpid() ? "observer":"other"
    }
    var actual:pid_t=0, axPID:pid_t?, axOwner=false, exactElement=false, phraseSelected=false
    if let raw=ToolUI.value(system,kAXFocusedUIElementAttribute), CFGetTypeID(raw)==AXUIElementGetTypeID() {
        let element=raw as! AXUIElement
        if AXUIElementGetPid(element,&actual) == .success {axPID=actual}
        axOwner = axPID==pid
        if axOwner {
            AXUIElementSetMessagingTimeout(element,0.18)
            exactElement = CFEqual(element,field)
            phraseSelected = ToolUI.value(element,kAXSelectedTextAttribute) as? String == phrase
        }
    }
    let original=fixture.client?.processIdentifier==pid && fixture.client?.isTerminated==false
    let leftForHost=original && front==host && state["window"] as? CGWindowID==number &&
        state["front"] as? Bool==false && state["key"] as? Bool==false && state["focused"] as? Bool==false
    return .init(checks:["originalFixture":original,"workspaceFront":front==pid,
                         "stateWindow":state["window"] as? CGWindowID==number,"stateFront":state["front"] as? Bool==true,
                         "stateKey":state["key"] as? Bool==true,"stateSelected":state["focused"] as? Bool==true,
                         "axOwner":axOwner,"sameAXInput":exactElement,"axExactSelection":phraseSelected],
                 foreground:ownerClass(front),axForeground:ownerClass(axPID),leftForHost:leftForHost)
}

struct TranslationStackWitness {
    let reason:String
    let blockingOwner:String?
    let blockingLayer:Int?
    var clear:Bool { reason=="clear" }
    var fields:[String:Any] {
        var result:[String:Any] = ["status":reason]
        if let blockingOwner {result["blockingOwner"]=blockingOwner}
        if let blockingLayer {result["blockingLayer"]=blockingLayer}
        return result
    }
    init(_ reason:String,_ owner:String?=nil,_ layer:Int?=nil) {
        self.reason=reason;self.blockingOwner=owner;self.blockingLayer=layer
    }
}

func translationStackRows(_ rows:[[String:Any]]?, _ host:pid_t, _ fixture:pid_t, _ number:CGWindowID,
                          _ bounds:CGRect, level:Int) -> TranslationStackWitness {
    guard let rows else {return .init("stackUnavailable")}
    let interior=bounds.insetBy(dx:2,dy:2)
    guard !interior.isEmpty else {return .init("invalidInterior")}
    for row in rows {
        guard let id=row[kCGWindowNumber as String] as? UInt32 else{return .init("stackIdentityUnavailable")}
        let alpha=row[kCGWindowAlpha as String] as? Double
        if id != number && alpha==0 {continue}
        guard let data=row[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:data) else {
            return .init("stackBoundsUnavailable")
        }
        let owner=row[kCGWindowOwnerPID as String] as? pid_t, layer=row[kCGWindowLayer as String] as? Int
        if id==number {
            guard owner==host,layer==level,rect==bounds,let alpha,alpha.isFinite,alpha>0 else {
                return .init("targetIdentityGeometryOrOpacityChanged")
            }
            return .init("clear")
        }
        let intersection=rect.intersection(interior)
        if intersection.isNull || intersection.isEmpty {continue}
        guard let alpha, alpha.isFinite,alpha>=0 else{return .init("overlappingWindowOpacityUnavailable")}
        if alpha>0 {return .init("occludedByHigherWindow",owner==host ? "installedHost" : owner==fixture ? "fixture":"other",layer)}
    }
    return .init("targetMissing")
}

@MainActor private func stack(_ host:pid_t,_ fixture:pid_t,_ number:CGWindowID,_ bounds:CGRect)->TranslationStackWitness {
    let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]
    return translationStackRows(list,host,fixture,number,bounds,level:NSWindow.Level.popUpMenu.rawValue)
}

@MainActor private func exactPanelLabels(_ host:pid_t,_ number:CGWindowID,_ rect:CGRect)->[UUID:Set<String>] {
    let app=AXUIElementCreateApplication(host)
    AXUIElementSetMessagingTimeout(app,0.12)
    var roots=ToolUI.value(app,kAXWindowsAttribute) as? [AXUIElement] ?? []
    var hit:AXUIElement?
    if AXUIElementCopyElementAtPosition(app,Float(rect.midX),Float(rect.midY),&hit) == .success, let hit,
       let raw=ToolUI.value(hit,kAXWindowAttribute), CFGetTypeID(raw)==AXUIElementGetTypeID() { roots.append(raw as! AXUIElement) }
    var labels=[UUID:Set<String>](), visited=Set<AXUIElement>()
    for root in roots {
        var id:CGWindowID=0
        guard selectionAXWindow(root,&id) == .success,id==number else {continue}
        var todo=[root]
        while let node=todo.popLast(), visited.count < 64 {
            guard visited.insert(node).inserted else {continue}
            var actual:pid_t=0
            guard AXUIElementGetPid(node,&actual) == .success,actual==host else {continue}
            AXUIElementSetMessagingTimeout(node,0.10)
            let prefix="nearpane-translation-content-"
            if let tag=ToolUI.value(node,kAXIdentifierAttribute) as? String, tag.hasPrefix(prefix),
               let request=UUID(uuidString:String(tag.dropFirst(prefix.count))),let bounds=ToolUI.frame(node),
               !bounds.isEmpty,rect.insetBy(dx:-2,dy:-2).contains(bounds) {
                for label in ToolUI.labels(node) {
                    labels[request,default:[]].insert(TranslationProof.digest(TranslationProof.normalized(label)))
                }
            }
            todo.append(contentsOf:(ToolUI.value(node,kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
    }
    return labels
}

struct TranslationPanelSample {
    let number:CGWindowID, rect:CGRect, begin:Double, end:Double, axEnd:Double?
    let beforeStack:TranslationStackWitness, afterStack:TranslationStackWitness
    let beforeFocus:TranslationSourceWitness, afterFocus:TranslationSourceWitness
    let selection:Bool, pointer:Bool, sameHost:Bool, image:CGImage?, labels:[UUID:Set<String>]
    let captureState:String, captureAttempted:Bool, captureScope:String
    var metadata:[String:Any] {
        ["window":number,"frame":NSStringFromRect(rect),"begin":begin,"end":end,"stackBefore":beforeStack.fields,
         "stackAfter":afterStack.fields,"sourceBefore":beforeFocus.checks,"sourceAfter":afterFocus.checks,
         "atSelection":selection,"atOriginalPointer":pointer,"sameHostGeneration":sameHost,
         "capture":captureState,"captureAttempted":captureAttempted,"captureScope":captureScope,
         "foregroundBefore":beforeFocus.foreground,"foregroundAfter":afterFocus.foreground,
         "axForegroundBefore":beforeFocus.axForeground,"axForegroundAfter":afterFocus.axForeground,
         "requestMarkers":labels.count,"axReadFinished":axEnd.map { $0 as Any } ?? NSNull()]
    }
    func textInImage(_ expected:String)->(matches:Bool,visibleText:Bool) {
        guard let image,!expected.isEmpty else {return (false,false)}
        let query=VNRecognizeTextRequest()
        query.recognitionLevel = .accurate
        query.recognitionLanguages=["zh-Hans","en-US"]
        do {try VNImageRequestHandler(cgImage:image).perform([query])} catch {return (false,false)}
        let lines=(query.results ?? []).filter{!$0.boundingBox.isEmpty}.compactMap{$0.topCandidates(1).first?.string}
        let text=TranslationProof.normalized(lines.joined())
        return (text==TranslationProof.normalized(expected),!text.isEmpty)
    }
}

@MainActor func nearTranslationPointer(_ rect:CGRect,_ pointer:CGPoint)->Bool {
    if rect.insetBy(dx:-12,dy:-12).contains(pointer) {return true}
    guard let primary=NSScreen.screens.first else{return false}
    let screens=NSScreen.screens.filter{$0.frame.contains(CGPoint(x:pointer.x,y:primary.frame.maxY-pointer.y))}
    guard screens.count==1,let frame=screens.first?.visibleFrame else{return false}
    let visible=CGRect(x:frame.minX,y:primary.frame.maxY-frame.maxY,width:frame.width,height:frame.height)
    return TranslationProof.clampedPointerMatch(rect,point:pointer,visible:visible)
}

@MainActor func sampleTranslationPanel(host:pid_t,fixture:pid_t,number:CGWindowID,rect:CGRect,selection:Bool,
                                      pointer:CGPoint?,focus:()->TranslationSourceWitness,sameHost:()->Bool) async -> TranslationPanelSample {
    let begin=ProcessInfo.processInfo.systemUptime, original=sameHost()
    let firstFocus=focus(), first=stack(host,fixture,number,rect)
    func atPointer()->Bool {
        guard let pointer,let now=CGEvent(source:nil)?.location else {return false}
        return abs(now.x-pointer.x)<=1 && abs(now.y-pointer.y)<=1 && nearTranslationPointer(rect,now)
    }
    let initialPointer=atPointer()
    var image:CGImage?,labels=[UUID:Set<String>]()
    var publicNotice:TranslationProof.StockNotice?
    if original && first.clear && firstFocus.leftForHost {
        publicNotice=TranslationProof.stockNotice(in:exactPanelLabels(host,number,rect))
    }
    let scope=firstFocus.confirmed ? "sourceDocument" : publicNotice != nil ? "hostStockNotice":"none"
    let attempted=original && first.clear && scope != "none"
    if attempted {image=try? await ToolUI.ownedImage(number,pid:host)}
    let imageReturned=image != nil
    let last=stack(host,fixture,number,rect), lastFocus=focus(), stable=original && sameHost()
    let pointerStable=initialPointer && atPointer(), imageEnd=ProcessInfo.processInfo.systemUptime
    var axEnd:Double?
    let afterFocusOK=firstFocus.confirmed ? lastFocus.confirmed : lastFocus.leftForHost
    var retained=last.clear && afterFocusOK && stable
    if image != nil && retained {
        let scoped=exactPanelLabels(host,number,rect)
        let read=focus()
        let axStable=stack(host,fixture,number,rect).clear && sameHost() &&
            (firstFocus.confirmed ? read.confirmed:read.leftForHost)
        if !scoped.isEmpty && axStable {labels=scoped;axEnd=ProcessInfo.processInfo.systemUptime}
        if let publicNotice {
            // Content-only diagnostics require the same scoped, stock-text AX marker on both sides.
            // They never authorize saving a PNG or a passing source-focus verdict.
            retained=axStable && TranslationProof.stockNotice(in:scoped)==publicNotice
        }
    }
    if !retained {image=nil;labels=[:]}
    let status=TranslationProof.captureState(attempted:attempted,returned:imageReturned,retained:retained)
    return .init(number:number,rect:rect,begin:begin,end:imageEnd,axEnd:axEnd,
                 beforeStack:first,afterStack:last,beforeFocus:firstFocus,afterFocus:lastFocus,selection:selection,
                 pointer:pointerStable,sameHost:stable,image:image,labels:labels,captureState:status,
                 captureAttempted:attempted,captureScope:scope)
}
