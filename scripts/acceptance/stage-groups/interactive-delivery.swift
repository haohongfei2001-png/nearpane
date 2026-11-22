import AppKit
import NearpaneCore

private struct DeliveryIntent: Codable {
    let nonce: UUID
    let source: Int32
    let tag: Int64
    let character: String
}

/// Only the disposable GUI owners attach this view. Each owner records its own window's actual responder events.
@MainActor final class HostedDocumentReceiver: NSView {
    let root: URL
    private var events = [String]()
    init(root: URL) { self.root = root; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func receive(_ event: NSEvent, _ phase: String) {
        guard let window, event.window === window, let cg = event.cgEvent,
              let intent = try? JSONDecoder().decode(DeliveryIntent.self, from: Data(contentsOf: root.appendingPathComponent("delivery-intent.json"))),
              cg.getIntegerValueField(.eventSourceUserData) == intent.tag,
              cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(intent.source) else { return }
        let prefix = root.appendingPathComponent("receiver-" + String(window.windowNumber))
        events.append(phase)
        do {
            if phase == "keyDown", !event.isARepeat, event.characters == intent.character,
               window.isKeyWindow, window.firstResponder === self {
                try Data(intent.nonce.uuidString.utf8).write(to: prefix.appendingPathExtension("document"), options: .withoutOverwriting)
            }
            try JSONEncoder().encode(events).write(to: prefix.appendingPathExtension("json"), options: .atomic)
        } catch {
            try? Data("writeFailed".utf8).write(to: prefix.appendingPathExtension("error"), options: .atomic)
        }
    }
    override func mouseDown(with e: NSEvent) { receive(e, "down") }
    override func mouseDragged(with e: NSEvent) { receive(e, "drag") }
    override func mouseUp(with e: NSEvent) { receive(e, "up") }
    override func keyDown(with e: NSEvent) { receive(e, "keyDown") }
    override func keyUp(with e: NSEvent) { receive(e, "keyUp") }
}

@MainActor private func exactHit(_ point: CGPoint, _ target: Target) -> Bool {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
          let element else { return false }
    if CFEqual(element, target.element) { return true }
    guard let owner = ax(element, kAXWindowAttribute), CFGetTypeID(owner) == AXUIElementGetTypeID() else { return false }
    return CFEqual(owner, target.element)
}

@MainActor func checkHostedDelivery(root: URL) async throws {
    var receipt: [String: Any] = ["status":"BLOCKED", "scope":"isolatedHostedWindowServer", "host":"NOT_RUN",
        "spacesMigration":"NOT_RUN", "cornerParking":"NOT_RUN", "systemBuild":ProcessInfo.processInfo.operatingSystemVersionString,
        "submitted":0, "productionQualified":false]
    func save(_ reason: String) throws {
        receipt["reason"] = reason
        try JSONSerialization.data(withJSONObject:receipt, options:[.sortedKeys]).write(to:root.appendingPathComponent("delivery.json"), options:.withoutOverwriting)
    }
    let owners = try ["a","b"].map { try JSONDecoder().decode(Owner.self, from:Data(contentsOf:root.appendingPathComponent($0+".json"))) }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !StageManagerPreference.ownsWindowDispatch,
          let pair = enroll(owners[0],name:"a"), pair.count == 2, let other = enroll(owners[1],name:"b"), other.count == 1,
          owners[0].pid != owners[1].pid, owners[0].identifier != owners[1].identifier else { try save("ordinaryOwnersOrInputPermissionUnavailable"); return }
    let all = pair + other, target = pair[0]
    guard let before = try await sample(all,root:root), before.cg.count == 3, before.axFrames == before.cg,
          let frame = before.cg[target.id], try await takeFocus(target), focused(target) else { try save("exactFocusOrGeometryUnavailable"); return }
    let nonce = UUID(), intent = DeliveryIntent(nonce:nonce, source:getpid(), tag:Int64.random(in:1...Int64.max), character:"v")
    try JSONEncoder().encode(intent).write(to:root.appendingPathComponent("delivery-intent.json"),options:.withoutOverwriting)
    receipt["nonce"] = nonce.uuidString
    receipt["sourcePID"] = getpid()
    receipt["owners"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(owners))
    receipt["target"] = target.id
    receipt["geometry"] = all.map { t -> [String:Any] in
        let r = before.cg[t.id]!
        return ["id":t.id,"frame":[r.minX,r.minY,r.width,r.height],"owner":t.owner.pid]
    }
    guard let source = CGEventSource(stateID:.privateState) else { try save("eventSourceUnavailable"); return }
    let p = CGPoint(x:frame.midX,y:frame.midY), q = CGPoint(x:p.x+4,y:p.y+2)
    var submitted = 0
    let types: [CGEventType] = [.leftMouseDown,.leftMouseDragged,.leftMouseUp,.keyDown,.keyUp]
    for type in types {
        let point = type == .leftMouseDown ? p : q
        guard focused(target), exactHit(point,target), CGPreflightPostEventAccess() else {
            receipt["status"] = submitted == 0 ? "BLOCKED" : "UNKNOWN"
            try save("focusOrActualSystemHitChanged"); return
        }
        let packet: CGEvent?
        if type == .keyDown || type == .keyUp {
            packet = CGEvent(keyboardEventSource:source,virtualKey:9,keyDown:type == .keyDown)
            let units = Array(intent.character.utf16)
            packet?.keyboardSetUnicodeString(stringLength:units.count, unicodeString:units)
        } else {
            packet = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
        }
        guard let packet else { receipt["status"] = "UNKNOWN"; try save("eventAllocationFailed"); return }
        packet.flags = []
        packet.setIntegerValueField(.eventSourceUserData,value:intent.tag)
        packet.post(tap:.cghidEventTap)
        submitted += 1; receipt["submitted"] = submitted
        try await Task.sleep(for:.milliseconds(50))
    }
    try await Task.sleep(for:.milliseconds(250))
    let fm = FileManager.default
    var rows = [[String:Any]]()
    let expected = ["down","drag","up","keyDown","keyUp"]
    var matches = true
    for t in all {
        let prefix = root.appendingPathComponent("receiver-" + String(t.id))
        let eventFile = prefix.appendingPathExtension("json"), document = prefix.appendingPathExtension("document")
        let sequence = fm.fileExists(atPath:eventFile.path) ? try JSONDecoder().decode([String].self,from:Data(contentsOf:eventFile)) : []
        let exists = fm.fileExists(atPath:document.path)
        let same = exists ? try Data(contentsOf:document) == Data(nonce.uuidString.utf8) : false
        let error = fm.fileExists(atPath:prefix.appendingPathExtension("error").path)
        rows.append(["window":t.id,"owner":t.owner.pid,"events":sequence,"documentExists":exists,"exactMarker":same,"writeError":error])
        matches = matches && !error && (t.id == target.id ? sequence == expected && same : sequence.isEmpty && !exists)
    }
    receipt["receivers"] = rows
    let after = try await sample(all,root:root)
    let stable = focused(target) && after?.cg == before.cg && after?.axFrames == before.axFrames &&
        all.allSatisfy { (try? birth($0.owner.pid)) == $0.owner.birth }
    receipt["sameFocusGeometryAndGenerations"] = stable
    receipt["status"] = matches && stable ? "PASS" : "FAIL"
    try save(matches && stable ? "targetConsumedGestureAndWroteUniqueDocument" : "receiverOrFinalStateDisagreed")
}
