// Appended to the independent read-only observer. Exports only fixed product labels and aggregate counts.
func surfaceEvidence() -> Object {
    let args=CommandLine.arguments
    if (9...11).contains(args.count) && args[1]=="members" {
        guard let kit=PreviewCensus.kit(args[0]), let h=Int32(args[2]),let host,host.processIdentifier==h,runningCodeHash(h)==args[3],
              let p=Int32(args[4]),let b=UInt64(args[5]),birthMicroseconds(p)==b,runningCodeHash(p)==args[6],
              let a=UInt32(args[7]),let z=UInt32(args[8]),a != z,a>0,z>0,
              let scopes=inventory(requireComplete:true),scopes.count==1,let current=scopes[0]["current"] as? UInt64
        else {return ["available":false]}
        var buffer=[CChar](repeating:0,count:4096)
        guard proc_pidpath(p,&buffer,UInt32(buffer.count))>0,
              String(cString:buffer)==kit.appendingPathComponent("Field Notes.app/Contents/MacOS/FieldNotes").path,
              kit.deletingLastPathComponent().path=="/private/tmp",kit.lastPathComponent.hasPrefix("nearpane-d01.") else {return ["available":false]}
        let nums=[a,z];var reverse=[[UInt64]]()
        for n in nums {
            guard let row=PreviewCensus.windowRows(n),row.count==1,
                  row[0][kCGWindowNumber as String] as? UInt32==n,row[0][kCGWindowOwnerPID as String] as? Int32==p,
                  row[0][kCGWindowLayer as String] as? Int==0,let membership=NPReadWindowSpaces(n) as? [UInt64],!membership.isEmpty
            else {return ["available":false]}
            reverse.append(membership.sorted())
        }
        guard birthMicroseconds(p)==b else {return ["available":false]}
        let reg=NSRunningApplication(processIdentifier:p)
        let bundle=kit.appendingPathComponent("Field Notes.app")
        let registered=reg?.activationPolicy == .regular && reg?.bundleIdentifier=="net.example.spaces-document" &&
                       reg?.bundleURL?.resolvingSymlinksInPath().path==bundle.resolvingSymlinksInPath().path
        var result:Object=["available":true,"current":current,"numbers":nums,"fixturePID":p,"fixtureBirth":b,
                           "fixtureRegularRegistered":registered,"hostBirth":birthMicroseconds(h) as Any? ?? NSNull(),
                           "reverse":reverse,"hardware":[.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map{CGEventSource.counterForEventType(.hidSystemState,eventType:$0)},
                           "uptime":ProcessInfo.processInfo.systemUptime]
        if args.count>=10,let source=UInt64(args[9]){
            result["sourceCensus"]=PreviewCensus.report(source,host:h,fixture:p,expected:nums,visible:current==source)
        }
        if args.count==11,let target=UInt64(args[10]){
            result["targetCensus"]=PreviewCensus.report(target,host:h,fixture:p,expected:[],visible:false)
        }
        return result
    }
    guard args.count==3,let pid=Int32(args[1]),let host,host.processIdentifier==pid,AXIsProcessTrusted(),
          let hash=runningCodeHash(pid),hash==args[2],let birth=birthMicroseconds(pid),
          let scopes=inventory(requireComplete:true),scopes.count==1,let s=scopes.first,let sid=s["current"] as? UInt64,
          let d=s["scope"] as? String else {return ["available":false]}
    let ix=Sidebar(host,rows:rows)
    let panelSet=Set(rows.filter{$0[kCGWindowOwnerPID as String] as? Int32==pid && $0[kCGWindowIsOnscreen as String] as? Bool==true &&
                             $0[kCGWindowLayer as String] as? Int==Int(CGWindowLevelForKey(.floatingWindow))}.compactMap{$0[kCGWindowNumber as String] as? UInt32})
    let ids=["voice-capture-toggle","tray-content","tray-camera-entry","tray-file-drop","desktop-reserved-region"]
    let allowed=["开始或恢复收音","暂停收音","截图与文件托盘","展开截图方式","文件拖放区","本屏窗口总览"]
    var counts=Dictionary(uniqueKeysWithValues:ids.map{($0,0)}),labels=Set<String>(),panels=Set<UInt32>()
    for el in ix.visited {
        guard let id=value(el,kAXIdentifierAttribute) as? String,ids.contains(id) else {continue}
        var node=el
        for _ in 0..<36 {
            if value(node,kAXRoleAttribute) as? String==kAXWindowRole {
                let n=NPReadAXWindowNumber(node)
                if panelSet.contains(n) {
                    counts[id,default:0]+=1;panels.insert(n)
                    for k in [kAXTitleAttribute,kAXDescriptionAttribute] {
                        if let literal=value(el,k) as? String,allowed.contains(literal){labels.insert(literal)}
                    }
                }
                break
            }
            guard let parent=value(node,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID() else {break}
            node=parent as! AXUIElement
        }
    }
    let cards=ix.controls.filter{$0.key.hasPrefix("current-desktop-window:") || $0.key.hasPrefix("native-space-window:")}
    return ["available":true,"hostPID":pid,"hostBirth":birth,"hostHash":hash,"space":sid,"display":d,"panels":panels.sorted(),
            "stageManager":stage as Any? ?? NSNull(),"controls":counts,"fixedLabels":labels.sorted(),"windowCards":cards.count,
            "duplicatedCards":cards.values.filter{$0.count != 1}.count,"bareSpaceRows":ix.controls.keys.filter{$0.hasPrefix("native-space-row:")}.count,
            "legacyCards":ix.legacyCards,"placeholderLabels":ix.placeholderLabels.sorted(),"uptime":ProcessInfo.processInfo.systemUptime]
}
print(String(decoding:try JSONSerialization.data(withJSONObject:surfaceEvidence(),options:.sortedKeys),as:UTF8.self))
