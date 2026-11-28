// Observe only the signed Host's settings window. The two accepted labels are fixed fixture data.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func axWindowNumber(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

private let source = "bicycle"
private let answer = "自行车"

private func hardware() -> [UInt32] {
    let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .keyUp,
                                 .flagsChanged, .mouseMoved, .scrollWheel, .leftMouseDragged, .rightMouseDragged]
    return types.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
}

@MainActor private func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
    var pending = [root], seen = Set<AXUIElement>(), rows = [AXUIElement]()
    while let node = pending.popLast() {
        if !seen.insert(node).inserted { continue }
        guard seen.count <= 2200 else { throw ToolRefusal("Incomplete Settings accessibility tree") }
        rows.append(node)
        pending += ToolUI.value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return rows
}

@MainActor private func settings(_ pid: pid_t) throws -> (CGWindowID, CGRect, [AXUIElement])? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.45)
    var matches: [(CGWindowID, CGRect, [AXUIElement])] = []
    for window in ToolUI.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        let tree = try descendants(window)
        guard tree.contains(where: { ToolUI.value($0, kAXIdentifierAttribute) as? String == "settings-nav-modules" }) else { continue }
        var number = CGWindowID(0), owner = pid_t(0)
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid,
              axWindowNumber(window, &number) == .success, number > 0, let frame = ToolUI.frame(window),
              let surface = ToolUI.windows(pid).first(where: { $0.id == number && $0.level == 0 }),
              abs(frame.origin.x - surface.bounds.origin.x) < 2, abs(frame.origin.y - surface.bounds.origin.y) < 2,
              abs(frame.width - surface.bounds.width) < 2, abs(frame.height - surface.bounds.height) < 2 else { continue }
        matches.append((number, frame, tree))
    }
    guard matches.count <= 1 else { throw ToolRefusal("Ambiguous signed Settings window") }
    return matches.first
}

@MainActor private func allowedAction(_ node: AXUIElement, _ name: String) -> Bool {
    var actions: CFArray?
    return AXUIElementCopyActionNames(node, &actions) == .success && (actions as? [String])?.contains(name) == true
}

private func visible(_ point: CGPoint, owner: pid_t, window: CGWindowID) -> Bool {
    guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return false }
    for row in rows {
        guard let rect = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: rect),
              let alpha = row[kCGWindowAlpha as String] as? NSNumber, let number = row[kCGWindowNumber as String] as? UInt32 else { return false }
        if alpha.doubleValue <= 0 || !bounds.contains(point) { continue }
        return number == window && row[kCGWindowOwnerPID as String] as? pid_t == owner
    }
    return false
}

@MainActor private func observe(_ pid: pid_t, context: ToolContext, gate: () throws -> Void) async throws -> [String: Any] {
    try gate()
    try await ToolUI.openSettings(context.host)
    var modulesPressed = false, expanded = false, scrolled = false
    var previous: CGWindowID?, reads = 0
    for _ in 0..<32 {
        try gate()
        if let (window, frame, nodes) = try settings(pid) {
            let nav = nodes.filter { ToolUI.value($0, kAXIdentifierAttribute) as? String == "settings-nav-modules" }
            let words = nodes.filter { ToolUI.labels($0).contains("单词本") }
            var sourceFrames = [CGRect](), answerFrames = [CGRect]()
            for node in nodes {
                guard let box = ToolUI.frame(node), !box.isEmpty, frame.contains(CGPoint(x:box.midX,y:box.midY)) else { continue }
                let labels = ToolUI.labels(node).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
                let combined = labels.contains { [source+" "+answer, source+", "+answer, source+"，"+answer,
                                                   source+": "+answer, source+"："+answer, source+"\n"+answer].contains($0) }
                if combined || labels.contains(source) { sourceFrames.append(box) }
                if combined || labels.contains(answer) { answerFrames.append(box) }
            }
            let pair = sourceFrames.lazy.compactMap { lhs -> (CGRect, CGRect)? in
                guard let rhs = answerFrames.first(where: { abs($0.midY-lhs.midY) <= max(3,min(lhs.height,$0.height)/2) }),
                      visible(CGPoint(x:lhs.midX,y:lhs.midY),owner:pid,window:window),
                      visible(CGPoint(x:rhs.midX,y:rhs.midY),owner:pid,window:window) else { return nil }
                return (lhs,rhs)
            }.first
            if let pair {
                reads = previous == window ? reads + 1 : 1
                previous = window
                if reads >= 2 {
                    try gate()
                    return ["status":"PASS","settingsWindow":window,"visibleReadbacks":reads,"source":source,"answer":answer,
                            "sourceRect":NSStringFromRect(pair.0),"answerRect":NSStringFromRect(pair.1)]
                }
            } else {
                reads = 0
                if !modulesPressed, words.isEmpty, nav.count == 1, permittedPress(nav[0]) {
                    try gate()
                    modulesPressed = AXUIElementPerformAction(nav[0], kAXPressAction as CFString) == .success
                } else if !scrolled, let node = words.first(where: { allowedAction($0,"AXScrollToVisible") }) {
                    try gate()
                    scrolled = AXUIElementPerformAction(node, "AXScrollToVisible" as CFString) == .success
                } else if !expanded, let node = words.first(where: permittedPress),
                          ToolUI.value(node,kAXExpandedAttribute) as? Bool != true {
                    try gate()
                    expanded = AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
                }
            }
        }
        await ToolUI.pause(160)
    }
    return ["status":"UNKNOWN","reason":"Two unobscured, same-row Settings text readbacks were unavailable",
            "modulesPressed":modulesPressed,"disclosurePressed":expanded,"scrolled":scrolled]
}

@MainActor private func permittedPress(_ node: AXUIElement) -> Bool {
    ToolUI.value(node,kAXEnabledAttribute) as? Bool != false && allowedAction(node,kAXPressAction)
}

@main struct SeededWordView {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            if args.dropFirst() == ["--read-input"] {
                let counters = try JSONEncoder().encode(hardware())
                print(String(decoding: counters, as: UTF8.self))
                return
            }
            guard args.count == 3, let expected = pid_t(args[1]), expected > 1 else { throw ToolRefusal("Expected enrolled Host PID") }
            let ctx = try ToolContext(output: args[2])
            let hid = hardware()
            func gate() throws {
                guard ctx.host.processIdentifier == expected, !ctx.host.isTerminated, hardware() == hid,
                      let session = CGSessionCopyCurrentDictionary() as? [String:Any], session["kCGSSessionOnConsoleKey"] as? Bool == true,
                      session["CGSSessionScreenIsLocked"] as? Bool != true else { throw ToolRefusal("Host, console, lock or physical input changed") }
            }
            let result = try await observe(expected, context: ctx, gate: gate)
            print(String(decoding: try JSONSerialization.data(withJSONObject:result), as:UTF8.self))
        } catch {
            let data = try? JSONSerialization.data(withJSONObject:["status":"BLOCKED","reason":error.localizedDescription])
            print(String(decoding: data ?? Data(), as: UTF8.self))
        }
    }
}
