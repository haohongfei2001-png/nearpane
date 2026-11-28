// The only actionable objects are the installed Host's status item, its named menu opener,
// and a close/cancel on the menu presented by this session. Space rows are metadata only.
struct DirectoryBinding: Decodable {
    let hostPID: pid_t, hostBirth: UInt64, hostHash: String, topology: Topology, hid5: [UInt32]
}

func actionNames(_ node: AXUIElement) -> [String]? {
    var names: CFArray?
    guard AXUIElementCopyActionNames(node, &names) == .success else { return nil }
    return names as? [String]
}

func axString(_ node: AXUIElement, _ key: String) -> String? { prop(node, key) as? String }

func fixedText(_ node: AXUIElement, _ expected: String) -> Bool {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { axString(node, $0) == expected }
}

func osBuild() -> String? {
    var bytes = [CChar](repeating: 0, count: 64)
    var count = bytes.count
    guard sysctlbyname("kern.osversion", &bytes, &count, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}

final class DirectorySession {
    let binding: DirectoryBinding, host: AXUIElement, hid: [UInt32]
    var statusItem: AXUIElement?, statusMenu: AXUIElement?
    var statusAttempted = false, directoryAttempted = false, closeAttempted = false
    let prefix = "native-space-row:"

    init(_ binding: DirectoryBinding) throws {
        self.binding = binding
        host = AXUIElementCreateApplication(binding.hostPID)
        AXUIElementSetMessagingTimeout(host, 0.35)
        hid = hardware()
        try need(AXIsProcessTrusted() && binding.hid5.count == 5 && Array(hid.prefix(5)) == binding.hid5,
                 "observerOrPhysicalInputUnavailable")
        try gate()
    }

    func gate() throws {
        let pid = binding.hostPID
        try need(osBuild() == "26A428" && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil,
                 "quarantineBuildOrActualLoginChanged")
        let pref = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        try need(pref.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true && pref as? Bool == false,
                 "stageOffNotConfirmed")
        try need(path(pid) == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" &&
                 birth(pid) == binding.hostBirth && owner(host) == pid, "installedProcessChanged")
        let signed = signature(pid)
        try need(signed?.0 == "com.holdsnow.nearpane.alpha" && signed?.1 == binding.hostHash, "hostCodeChanged")
        let liveTopology = try topology()
        try need(liveTopology == binding.topology &&
                 liveTopology.records.contains { $0.id == liveTopology.current && $0.type == 0 }, "topologyChanged")
        try need(hardware() == hid, "newHumanInput")
    }

    func tree(_ roots: [AXUIElement], stoppingAt: (AXUIElement) -> Bool = { _ in false }) throws -> [AXUIElement] {
        var stack = Array(roots.reversed()), seen = Set<AXUIElement>(), result = [AXUIElement]()
        while let node = stack.popLast() {
            guard owner(node) == binding.hostPID, seen.insert(node).inserted else { continue }
            try need(seen.count <= 1200, "axTreeLimit")
            result.append(node)
            if !stoppingAt(node), !["AXTextArea", "AXTextField", "AXWebArea", "AXImage"].contains(axString(node, kAXRoleAttribute) ?? "") {
                stack.append(contentsOf: array(node, kAXChildrenAttribute).reversed())
            }
        }
        return result
    }

    func directories() throws -> [AXUIElement] {
        guard let windows = prop(host, kAXWindowsAttribute) as? [AXUIElement] else { throw Refusal("hostAXWindowsUnavailable") }
        let isDirectory: (AXUIElement) -> Bool = { axString($0, kAXIdentifierAttribute) == "native-space-menu" }
        return try tree(windows, stoppingAt: isDirectory).filter(isDirectory)
    }

    func item() throws -> AXUIElement {
        guard let raw = prop(host, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw Refusal("hostStatusBarUnavailable")
        }
        let bar = raw as! AXUIElement
        let items = array(bar, kAXChildrenAttribute)
        try need(owner(bar) == binding.hostPID && items.count == 1 && owner(items[0]) == binding.hostPID &&
                 axString(items[0], kAXRoleAttribute) == "AXMenuBarItem", "statusItemNotUnique")
        _ = AXUIElementSetMessagingTimeout(items[0], 0.35)
        return items[0]
    }

    func menus(_ item: AXUIElement) throws -> [AXUIElement] {
        var raw: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &raw)
        if read == .noValue { return [] }
        guard read == .success, let children = raw as? [AXUIElement] else { throw Refusal("statusChildrenUnavailable") }
        return children.filter { owner($0) == binding.hostPID && axString($0, kAXRoleAttribute) == "AXMenu" }
    }

    func awaitOne(_ find: () throws -> [AXUIElement]) throws -> AXUIElement {
        let limit = ProcessInfo.processInfo.systemUptime + 2.5
        repeat {
            let result = try find()
            try need(result.count <= 1, "ambiguousOwnedControl")
            if let node = result.first { return node }
            Thread.sleep(forTimeInterval: 0.06)
        } while ProcessInfo.processInfo.systemUptime < limit && hardware() == hid
        throw Refusal("ownedControlDidNotAppear")
    }

    func ownedStatusMenu() throws -> AXUIElement {
        let current = try item()
        try need(statusAttempted && statusItem.map { CFEqual(current, $0) } == true, "statusItemChanged")
        let present = try awaitOne { try menus(current) }
        if let statusMenu { try need(CFEqual(statusMenu, present), "statusMenuChanged") }
        return present
    }

    func openStatus() throws -> Map {
        try need(!statusAttempted && !directoryAttempted, "statusAlreadyAttempted")
        let current = try item(), visible = try menus(current), existing = try directories()
        try need(visible.isEmpty && existing.isEmpty, "preexistingMenuOrDirectory")
        guard let actions = actionNames(current), let action = [kAXPressAction, kAXShowMenuAction].first(where: actions.contains)
        else { throw Refusal("statusItemHasNoOpenAction") }
        try gate()
        statusItem = current
        statusAttempted = true
        let ack = AXUIElementPerformAction(current, action as CFString)
        statusMenu = try ownedStatusMenu()
        return ["ack": ack.rawValue, "statusMenuObserved": true]
    }

    func openDirectory() throws -> Map {
        try need(statusAttempted && !directoryAttempted, "directoryAlreadyAttempted")
        let menu = try ownedStatusMenu()
        let matches = array(menu, kAXChildrenAttribute).filter { owner($0) == binding.hostPID &&
            axString($0, kAXRoleAttribute) == "AXMenuItem" && axString($0, kAXIdentifierAttribute) == "native-space-menu-open" }
        try need(matches.count == 1 && fixedText(matches[0], "选择本屏空间…") &&
                 prop(matches[0], kAXEnabledAttribute) as? Bool == true &&
                 actionNames(matches[0])?.contains(kAXPressAction) == true, "namedDirectoryOpenerUnavailable")
        try gate()
        directoryAttempted = true
        let ack = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
        return ["ack": ack.rawValue, "control": "native-space-menu-open"]
    }

    func readDirectory() throws -> Map {
        try need(directoryAttempted, "directoryNotRequested")
        let group = try awaitOne { try directories() }
        let isRow: (AXUIElement) -> Bool = { axString($0,kAXIdentifierAttribute)?.hasPrefix(self.prefix) == true }
        let nodes = try tree([group], stoppingAt: isRow)
        var rows = [Map]()
        var counters = [0: 0, 4: 0], expected = [String: String]()
        for space in binding.topology.records where space.type == 0 || space.type == 4 {
            counters[space.type, default: 0] += 1
            let title = (space.type == 0 ? "桌面 " : "全屏空间 ") + String(counters[space.type]!)
            expected[prefix + binding.topology.display.uuidString + ":" + String(space.id)] =
                space.id == binding.topology.current ? title + "，当前空间" : title
        }
        for node in nodes where isRow(node) {
            let id = axString(node, kAXIdentifierAttribute) ?? ""
            guard let title = expected[id] else { throw Refusal("unexpectedDisplayOrSpaceRow") }
            let role = axString(node, kAXRoleAttribute) ?? ""
            let actions = actionNames(node)
            let enabled = prop(node, kAXEnabledAttribute) as? Bool
            rows.append(["id": id, "role": role, "labelMatches": fixedText(node, title),
                         "actionsRead": actions != nil, "canPress": actions?.contains(kAXPressAction) as Any? ?? NSNull(),
                         "enabled": enabled as Any? ?? NSNull()])
        }
        let quarantine = nodes.contains { axString($0, kAXRoleAttribute) == "AXStaticText" && fixedText($0,"此 macOS 版本尚未启用空间切换。") }
        try gate()
        return ["rows": rows, "quarantineText": quarantine, "uptime": ProcessInfo.processInfo.systemUptime]
    }

    func close() throws -> Map {
        try need(!closeAttempted, "closeAlreadyAttempted")
        let groups = try directories()
        let current = try item(), openMenus = try menus(current)
        if groups.isEmpty && openMenus.isEmpty { return ["method": "alreadyClosed"] }
        try need(statusAttempted && statusItem.map { CFEqual(current, $0) } == true, "noOwnedMenu")
        let node: AXUIElement, action: String
        if directoryAttempted && groups.count == 1 && openMenus.isEmpty {
            let buttons = try tree(groups).filter { axString($0, kAXRoleAttribute) == "AXButton" &&
                fixedText($0, "关闭") && prop($0, kAXEnabledAttribute) as? Bool != false &&
                actionNames($0)?.contains(kAXPressAction) == true }
            if buttons.count == 1 { node = buttons[0]; action = kAXPressAction }
            else if buttons.isEmpty, actionNames(groups[0])?.contains(kAXCancelAction) == true { node = groups[0]; action = kAXCancelAction }
            else { throw Refusal("uniqueCloseControlUnavailable") }
        } else if groups.isEmpty && openMenus.count == 1 &&
                    statusMenu.map({ CFEqual(openMenus[0], $0) }) == true &&
                    actionNames(openMenus[0])?.contains(kAXCancelAction) == true {
            node = openMenus[0]; action = kAXCancelAction
        } else { throw Refusal("ambiguousOpenPresentations") }
        try gate()
        closeAttempted = true
        let ack = AXUIElementPerformAction(node, action as CFString)
        return ["method": action, "ack": ack.rawValue]
    }

    func verifyClosed() throws -> Map {
        let limit = ProcessInfo.processInfo.systemUptime + 2
        var consecutive = 0
        repeat {
            let dirs = try directories(), open = try menus(item())
            consecutive = dirs.isEmpty && open.isEmpty ? consecutive + 1 : 0
            if consecutive == 2 {
                try gate()
                return ["closedReadbacks": 2, "hid": hid, "topology": try object(binding.topology)]
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < limit && hardware() == hid
        throw Refusal("closeNotIndependentlyObserved")
    }
}

do {
    guard CommandLine.arguments.count == 1, let line = readLine() else { throw Refusal("missingScope") }
    let session = try DirectorySession(JSONDecoder().decode(DirectoryBinding.self, from: Data(line.utf8)))
    emit(["phase": "bind", "ok": true, "hid": session.hid])
    while let verb = readLine() {
        do {
            try session.gate()
            let proof: Map
            switch verb {
            case "status": proof = try session.openStatus()
            case "directory": proof = try session.openDirectory()
            case "read": proof = try session.readDirectory()
            case "close": proof = try session.close()
            case "verify": proof = try session.verifyClosed()
            default: throw Refusal("unsupportedPhase")
            }
            emit(proof.merging(["phase": verb, "ok": true, "statusAttempted": session.statusAttempted, "directoryAttempted": session.directoryAttempted]) { _, new in new })
        } catch {
            emit(["phase": verb, "ok": false, "reason": (error as? Refusal)?.reason ?? "unavailable",
                  "statusAttempted": session.statusAttempted, "directoryAttempted": session.directoryAttempted])
        }
    }
} catch {
    emit(["phase": "bind", "ok": false, "reason": (error as? Refusal)?.reason ?? "invalidScope"])
    exit(2)
}
