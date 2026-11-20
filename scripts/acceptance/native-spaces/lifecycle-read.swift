// Compiled with the ordinary independent observe.swift window/Space readers.
let args = CommandLine.arguments
func emit(_ data: Object) {
    print(String(decoding:try! JSONSerialization.data(withJSONObject:data),as:UTF8.self))
}
guard args.count >= 5, let pid = Int32(args[2]), let first = UInt32(args[3]), let second = UInt32(args[4]),
      first != second, let fixture = NSRunningApplication(processIdentifier:pid),
      fixture.bundleIdentifier == "org.nearpane.acceptance.LifecycleWindow", let host,
      host.bundleURL?.path == "/Applications/Nearpane.app", let allScopes = spaces,
      allScopes.count == 1, let display = allScopes[0]["scope"] as? String,
      let current = allScopes[0]["current"] as? UInt64,
      let records = allScopes[0]["records"] as? [Object] else { exit(2) }
let numbers = [first,second]
guard numbers.allSatisfy({ n in rows.contains { ($0[kCGWindowNumber as String] as? UInt32) == n &&
    ($0[kCGWindowOwnerPID as String] as? pid_t) == pid } }) else { exit(3) }
let memberships = numbers.map { NPReadWindowSpaces($0) as? [UInt64] ?? [] }
let fixtureAX = AXUIElementCreateApplication(pid)
var result:Object = ["current":current,"scopes":records,"memberships":memberships,
                     "frontmostFixture":front?.processIdentifier == pid, "sidebarRows":(report["sidebar"] as? Object)?["rows"] as Any? ?? NSNull()]
switch args[1] {
case "read": break
case "row":
    guard args.count==6, let target=UInt64(args[5]), !Set(memberships.flatMap { $0 }).isDisjoint(with:[current]),
          memberships.contains([target]), current != target else { exit(2) }
    let ident="native-space-row:" + display + ":" + String(target)
    let hits=Sidebar(host,rows:rows).controls[ident] ?? []
    if hits.count==1, value(hits[0],kAXRoleAttribute) as? String == kAXButtonRole,
       value(hits[0],kAXEnabledAttribute) as? Bool == true {
        result["issued"]=true; result["axError"]=AXUIElementPerformAction(hits[0],kAXPressAction as CFString).rawValue
    } else {result["issued"]=false}
case "menu","tile":
    let (options, names) = lifecycleLeftMenu(fixtureAX)
    result["fullscreenMenuPaths"]=names
    if args[1]=="tile" {
        guard options.count==1, front?.processIdentifier==pid, focusedNumber(pid)==first else {result["issued"]=false;break}
        result["issued"]=true;result["axError"]=AXUIElementPerformAction(options[0].0,kAXPressAction as CFString).rawValue
    }
case "pair":
    guard front?.processIdentifier == pid || front?.bundleIdentifier=="com.apple.dock",
          let dock=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first else {exit(3)}
    var exact=[AXUIElement]()
    scanLifecycleAX(AXUIElementCreateApplication(dock.processIdentifier)) { node,_ in
        let fixtureName = [kAXTitleAttribute,kAXDescriptionAttribute].compactMap {value(node,$0) as? String}.contains("Nearpane Test Document B")
        var actions: CFArray?
        if fixtureName && AXUIElementCopyActionNames(node,&actions) == .success &&
            (actions as? [String])?.contains(kAXPressAction)==true {exact.append(node)}
    }
    if exact.count==1 {
        result["issued"]=true;result["axError"]=AXUIElementPerformAction(exact[0],kAXPressAction as CFString).rawValue
    } else {result["issued"]=false}
default: exit(2)
}
emit(result)
