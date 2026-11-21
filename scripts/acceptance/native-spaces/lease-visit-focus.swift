// Retain the original AX object and the two windows of the enrolled Lifecycle fixture.
// This helper only reports numeric metadata; the existing focus keeper performs any restoration.
import AppKit
import ApplicationServices

private let anchorID = "org.nearpane.acceptance.LifecycleWindow"

private struct Held {
    let pid: pid_t, born: UInt64, number: UInt32, id: String, hash: String, element: AXUIElement

    init(_ window: AXUIElement) throws {
        let p = owner(window), n = NPReadAXWindowNumber(window)
        guard n > 0, let b = birth(p), let s = signature(p), exactWindowOwner(n)?.0 == p else {
            throw Refusal("windowOwnerOrGenerationUnavailable")
        }
        pid = p; born = b; number = n; id = s.0; hash = s.1; element = window
    }

    func verify(_ space: UInt64, isAnchor: Bool, remote: Bool = false) throws {
        let signing = signature(pid), currentNumber = NPReadAXWindowNumber(element)
        // The AX bridge may omit a number for an off-Space retained object. Its live standard role,
        // exact independently enrolled CG number and exclusive membership still have to agree.
        let liveNumber = currentNumber == number || (isAnchor && remote && currentNumber == 0)
        try need(owner(element) == pid && liveNumber &&
                 exactWindowOwner(number)?.0 == pid && birth(pid) == born && signing?.0 == id && signing?.1 == hash &&
                 NPReadWindowSpaces(number) as? [UInt64] == [space] &&
                 (NPReadCatalogSpaceWindowNumbers(space) as? [UInt32])?.contains(number) == true,
                 "retainedEntityOrExclusiveMembershipChanged")
        if isAnchor {
            try need(exactWindowOwner(number)?.1 == 0 && prop(element,kAXRoleAttribute) as? String == kAXWindowRole &&
                     prop(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
                     prop(element,kAXMinimizedAttribute) as? Bool == false && prop(element,"AXFullScreen") as? Bool == false,
                     "anchorOrdinaryWindowUnavailable")
        }
    }
    func matches(_ f: ActualFocus) -> Bool {
        f.pid == pid && f.processBirth == born && f.number == number && f.element.map { CFEqual($0,element) } == true
    }
}

private func appleSigned(_ pid: pid_t) -> Bool {
    var code: SecCode?, rule: SecRequirement?
    return SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code) == errSecSuccess &&
        SecRequirementCreateWithString("anchor apple" as CFString,[],&rule) == errSecSuccess &&
        code.map { SecCodeCheckValidity($0,[],rule) == errSecSuccess } == true
}

private func inputs() -> [UInt32] {
    let types: [CGEventType] = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.keyUp,
        .flagsChanged,.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
    return types.map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
}

@main private struct VisitFocus {
    static func main() {
        do {
            let initial = try topology(), hid = inputs()
            guard initial.records.first(where:{$0.id == initial.current})?.type == 0, AXIsProcessTrusted(),
                  let f = actualFocus(), let element = f.element else { throw Refusal("originalOrdinaryFocusUnavailable") }
            let original = try Held(element)
            try original.verify(initial.current,isAnchor:false)
            try need(original.matches(f),"initialFocusUnstable")
            var anchor = [Held]()
            emit(["ready":true,"topology":try object(initial),"hid":hid,"pid":original.pid,"birth":original.born,"number":original.number])
            while let line = readLine(), line.utf8.count < 8192 {
                do {
                    guard let request = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? Map,
                          let op = request["command"] as? String else { throw Refusal("invalidRequest") }
                    if op == "release" { return }
                    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.015))
                    let t = try topology()
                    try need(t.display == initial.display && t.records == initial.records,"physicalSpaceInventoryChanged")
                    try need(inputs() == hid && NSEvent.pressedMouseButtons == 0,"newHumanInput")
                    let originalBound = (try? original.verify(initial.current,isAnchor:false)) != nil
                    guard let focused = actualFocus(), NSWorkspace.shared.frontmostApplication?.processIdentifier == focused.pid,
                          let focusedBirth = focused.processBirth else { throw Refusal("systemForegroundUnconfirmed") }
                    if op == "enroll" {
                        guard anchor.isEmpty, t.current == initial.current, let pid = request["pid"] as? pid_t,
                              let born = request["birth"] as? UInt64, let hash = request["hash"] as? String,
                              let executable = request["executable"] as? String, let numbers = request["numbers"] as? [UInt32],
                              numbers.count == 2, Set(numbers).count == 2, numbers.allSatisfy({$0 > 0}),
                              path(pid) == executable, birth(pid) == born, signature(pid)?.0 == anchorID,
                              signature(pid)?.1 == hash, focused.pid == pid, focused.number == numbers.first else {
                            throw Refusal("registeredAnchorGenerationUnavailable")
                        }
                        let app = AXUIElementCreateApplication(pid)
                        _ = AXUIElementSetMessagingTimeout(app,0.3)
                        guard let list = prop(app,kAXWindowsAttribute) as? [AXUIElement],
                              list.count == 2, Set(list.map { NPReadAXWindowNumber($0) }) == Set(numbers) else {
                            throw Refusal("registeredAnchorAXListUnavailable")
                        }
                        let bound = try numbers.map { n -> Held in
                            guard let w = list.first(where:{NPReadAXWindowNumber($0) == n && owner($0) == pid}) else {
                                throw Refusal("registeredAnchorWindowMismatch")
                            }
                            let h = try Held(w)
                            try h.verify(initial.current,isAnchor:true)
                            return h
                        }
                        try need(bound[0].matches(focused),"anchorDidNotOwnExactSystemFocus")
                        anchor = bound
                    } else { try need(op == "sample" || op == "retire","unknownReadCommand") }
                    for h in anchor { try h.verify(initial.current,isAnchor:true,remote:t.current != initial.current) }
                    let systemPaths = ["com.apple.finder":"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                        "com.apple.dock":"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                        "com.apple.WindowManager":"/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"]
                    var idleApple = false
                    if focused.number == nil, let sign = signature(focused.pid), let expected = systemPaths[sign.0],
                       path(focused.pid) == expected && appleSigned(focused.pid) {
                        let app = AXUIElementCreateApplication(focused.pid)
                        _ = AXUIElementSetMessagingTimeout(app,0.3)
                        var value: CFTypeRef?
                        idleApple = AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value) == .noValue
                    }
                    let isOriginal = originalBound && original.matches(focused), isAnchor = anchor.contains { $0.matches(focused) }
                    if op == "retire" {
                        try need(t.current == initial.current && isOriginal,"unableToRetireAwayFromOriginalFocus")
                        anchor.removeAll()
                    }
                    try need(inputs() == hid && (try? topology()) == t,"inputOrSpaceChangedDuringSample")
                    emit(["ready":true,"current":t.current,"uptime":ProcessInfo.processInfo.systemUptime,
                          "originExact":isOriginal,"originBound":originalBound,"anchorExact":isAnchor,"primaryAnchorExact":anchor.first?.matches(focused) == true,
                          "systemFocus":["pid":focused.pid,"birth":focusedBirth,"number":focused.number as Any? ?? NSNull()],
                          "appleIdle":idleApple,"anchors":anchor.count])
                } catch { emit(["ready":false,"reason":(error as? Refusal)?.reason ?? "readUnavailable"]) }
            }
        } catch { emit(["ready":false,"reason":(error as? Refusal)?.reason ?? "originalUnavailable"]) }
    }
}
