// Retain the original AX object and the two windows of the enrolled Lifecycle fixture.
// Ordinary visits and closed-receipt inspection only read metadata. A live daily holder can consume one activation.
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

private func bootID() throws -> String {
    var field = [CChar](repeating:0,count:128), size = 128
    guard sysctlbyname("kern.bootsessionuuid",&field,&size,nil,0) == 0,
          let value = UUID(uuidString:String(cString:field)) else { throw Refusal("bootIdentityUnavailable") }
    return value.uuidString
}

private struct DailyHost: Codable {
    let pid: pid_t, birth: UInt64, cdhash: String
    func matches() -> Bool {
        let expected = "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
        guard path(pid) == expected, let live = signature(pid), live.0 == "com.holdsnow.nearpane.alpha",
              live.1 == cdhash, processBorn(pid) == birth,
              let app = NSRunningApplication(processIdentifier:pid),
              app.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app", !app.isTerminated else { return false }
        var code: SecCode?, rule: SecRequirement?
        let dr = "anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        return SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code) == errSecSuccess &&
            SecRequirementCreateWithString(dr as CFString,[],&rule) == errSecSuccess &&
            code.map {SecCodeCheckValidity($0,[],rule) == errSecSuccess} == true
    }
}

private func processBorn(_ pid:pid_t) -> UInt64? { birth(pid) }

private func rememberedWindow(_ pid:pid_t, number:UInt32) throws -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetMessagingTimeout(app,0.22)
    guard let focused = prop(app,kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
          owner(focused as! AXUIElement) == pid, NPReadAXWindowNumber(focused) == number,
          let list = prop(app,kAXWindowsAttribute) as? [AXUIElement], list.count <= 128 else {
        throw Refusal("originalApplicationRememberedWindowUnavailable")
    }
    let matches = list.filter { owner($0) == pid && NPReadAXWindowNumber($0) == number }
    guard matches.count == 1, CFEqual(matches[0],focused) else { throw Refusal("originalWindowNotUniqueInOwnerAX") }
    return focused as! AXUIElement
}

private struct ClosedReceipt: Decodable {
    let boot: String, pid: pid_t, birth: UInt64, number: UInt32, hid: [UInt32], topology: Topology
    let signer: String?, host: DailyHost
}

private func inspectClosed() {
    var report: Map = ["scope":"readOnlyClosedTransaction","issued":false,"retainedOriginalAX":false,
                       "originalWindowRead":"NOT_RUN","uptime":ProcessInfo.processInfo.systemUptime]
    do {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count < 65536 else { throw Refusal("invalidReceipt") }
        let expected = try JSONDecoder().decode(ClosedReceipt.self,from:input)
        let hid = inputs(), t = try topology(), boot = try bootID()
        try need(expected.hid.count == hid.count && expected.pid > 1 && expected.number > 0,"invalidReceipt")
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sameHID = expected.hid == hid
        report["hidCounters"] = hid.count
        report["hidDeltas"] = zip(expected.hid,hid).map { Int64($1)-Int64($0) }
        report["bootMatched"] = boot == expected.boot
        report["topologyMatched"] = t == expected.topology
        report["currentSpace"] = t.current
        report["frontIsRestoredHost"] = before == expected.host.pid
        report["frontIsOriginalOwner"] = before == expected.pid
        report["restoredHostSignatureAndBirthMatched"] = expected.host.matches()
        try need(sameHID && NSEvent.pressedMouseButtons == 0,"newHumanInputPreserved")
        try need(t == expected.topology && boot == expected.boot,"bootOrPhysicalTopologyChanged")
        try need(before == expected.host.pid && expected.host.matches(),"newForegroundPreserved")
        guard let signer = expected.signer else { throw Refusal("historicalOriginalSignerNotRecorded") }
        guard let live = signature(expected.pid), live.1 == signer, processBorn(expected.pid) == expected.birth else {
            throw Refusal("originalSignerOrGenerationChanged")
        }
        var references = [AXUIElement]()
        for _ in 0..<2 {
            try need(inputs() == expected.hid && (try? topology()) == t && NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.host.pid,
                     "inputSpaceOrForegroundChanged")
            let match = try rememberedWindow(expected.pid,number:expected.number)
            let held = try Held(match)
            try held.verify(t.current,isAnchor:false)
            references.append(match)
            if references.count == 1 { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12)) }
        }
        try need(CFEqual(references[0],references[1]) && inputs() == expected.hid,"newWindowReadDidNotRemainStable")
        report["originalWindowRead"] = "freshScopedAXMatchedTwice"
        report["reason"] = "closedOriginalReferenceReleased"
    } catch { report["reason"] = (error as? Refusal)?.reason ?? "readUnavailable" }
    emit(report)
}

private func restoreDaily(_ original: Held, app: NSRunningApplication?, geometry: Topology, hid: [UInt32],
                          boot: String, host: DailyHost) -> Map {
    var report: Map = ["ready":true,"issued":false,"anchor":"retainedOriginalAX","method":"normalApplicationActivation"]
    do {
        func verify() throws {
            try need((try? topology()) == geometry && (try? bootID()) == boot,"originalBootOrSpaceChanged")
            try need(inputs() == hid && NSEvent.pressedMouseButtons == 0,"newHumanInput")
            try need(host.pid != original.pid && host.matches() && NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid &&
                     actualFocus()?.pid == host.pid,"foregroundIsNotRestoredSignedDailyHost")
            try original.verify(geometry.current,isAnchor:false)
            let remembered = try rememberedWindow(original.pid,number:original.number)
            try need(CFEqual(original.element,remembered),"originalAppWouldActivateAnotherWindow")
        }
        try verify()
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))
        try verify()
        guard let app, app.processIdentifier == original.pid, !app.isTerminated,
              inputs() == hid, NSEvent.pressedMouseButtons == 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid else {
            throw Refusal("generationOrForegroundChangedBeforeActivation")
        }
        report["issued"] = true
        report["accepted"] = app.activate(options:[])
    } catch { report["reason"] = (error as? Refusal)?.reason ?? "dailyActivationWithheld" }
    return report
}

@main private struct VisitFocus {
    static func main() {
        if Array(CommandLine.arguments.dropFirst()) == ["--inspect-closed"] { inspectClosed(); return }
        let daily = Array(CommandLine.arguments.dropFirst()) == ["--hold-daily"]
        guard daily || CommandLine.arguments.count == 1 else { emit(["ready":false,"reason":"invalidMode"]); return }
        do {
            let initial = try topology(), hid = inputs(), startBoot = try bootID()
            guard initial.records.first(where:{$0.id == initial.current})?.type == 0, AXIsProcessTrusted(),
                  let f = actualFocus(), let element = f.element else { throw Refusal("originalOrdinaryFocusUnavailable") }
            let original = try Held(element)
            try original.verify(initial.current,isAnchor:false)
            try need(original.matches(f),"initialFocusUnstable")
            var anchor = [Held](), usedDailyRestore = false
            let app = daily ? NSRunningApplication(processIdentifier:original.pid) : nil
            emit(["ready":true,"topology":try object(initial),"hid":hid,"pid":original.pid,"birth":original.born,"number":original.number,
                  "boot":startBoot,"signingCDHash":original.hash,"liveDailyRestore":daily])
            while let line = readLine(), line.utf8.count < 8192 {
                do {
                    guard let request = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? Map,
                          let op = request["command"] as? String else { throw Refusal("invalidRequest") }
                    if op == "release" { return }
                    if op == "restoreDaily" {
                        guard daily, !usedDailyRestore else { emit(["ready":true,"issued":false,"reason":"liveDailyPermitUnavailable"]); continue }
                        usedDailyRestore = true
                        let data = try JSONSerialization.data(withJSONObject:request["host"] as Any)
                        let host = try JSONDecoder().decode(DailyHost.self,from:data)
                        emit(restoreDaily(original,app:app,geometry:initial,hid:hid,boot:startBoot,host:host))
                        continue
                    }
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
