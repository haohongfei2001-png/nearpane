// Shared by the existing fullscreen lifecycle run and the scoped Split View contract.
func scanLifecycleAX(_ root: AXUIElement, _ visit: (AXUIElement,[String])->Void) {
    var todo:[(AXUIElement,[String],Int)] = [(root,[],0)]
    var count=0
    while let (node,parents,depth) = todo.popLast(), count < 1500 {
        count += 1
        let title = value(node,kAXTitleAttribute) as? String ?? ""
        let parts = title.isEmpty ? parents : parents + [title]
        visit(node,parts)
        if depth < 9 {
            for child in value(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                todo.append((child,parts,depth+1))
            }
        }
    }
}

func lifecycleLeftMenu(_ fixtureAX: AXUIElement) -> ([(AXUIElement,[String])], [[String]]) {
    guard let bar=value(fixtureAX,kAXMenuBarAttribute), CFGetTypeID(bar)==AXUIElementGetTypeID() else {return ([],[])}
    var options=[(AXUIElement,[String])]()
    var names=[[String]]()
    scanLifecycleAX(bar as! AXUIElement) { node,path in
        guard value(node,kAXRoleAttribute) as? String == kAXMenuItemRole, let label=path.last else{return}
        let relevant=path.contains { $0.localizedCaseInsensitiveContains("full screen") || $0.contains("全屏") }
        if relevant { names.append(path) }
        if relevant && (label.localizedCaseInsensitiveContains("left of screen") || label.localizedCaseInsensitiveContains("left side") || label.contains("屏幕左侧") || label=="左侧" || label=="Left"),
           value(node,kAXEnabledAttribute) as? Bool == true {options.append((node,path))}
    }
    return (options,names)
}
