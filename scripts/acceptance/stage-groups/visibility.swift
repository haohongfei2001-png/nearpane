import AppKit
import NearpaneCore

@MainActor final class FixtureKeyReceiver: NSView {
    private(set) var input = ""
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { input += event.characters ?? "" }
}

struct OwnedWindowState: Codable, Equatable {
    let number: UInt32, miniature: Bool, visible: Bool, activeSpace: Bool, key: Bool
    let frame: CGRect, input: String, auxiliary: Bool, clicks: Int
    @MainActor init(_ window: NSWindow, clicks: Int) {
        self.clicks = clicks
        number = UInt32(window.windowNumber)
        miniature = window.isMiniaturized
        visible = window.isVisible
        activeSpace = window.isOnActiveSpace
        key = window.isKeyWindow
        frame = window.frame
        input = (window.firstResponder as? FixtureKeyReceiver)?.input ?? ""
        auxiliary = window is NSPanel
    }
}

struct Target {
    let id: UInt32, owner: Owner, element: AXUIElement
}

func ax(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = ax(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = ax(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func enroll(_ owner: Owner, name: String, auxiliary: Set<Int> = []) -> [Target]? {
    guard (try? birth(owner.pid)) == owner.birth,
          NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier == owner.identifier,
          let list = ax(AXUIElementCreateApplication(owner.pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    var targets = [Target]()
    for (index, n) in owner.numbers.enumerated() {
        let matches = list.filter { (ax($0, kAXIdentifierAttribute) as? String) == "nearpane.fixture." + name + "." + String(index) }
        guard matches.count == 1, let original = matches.first else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(original, &pid) == .success, pid == owner.pid, auxiliary.contains(index) || ax(original, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
        else { return nil }
        targets.append(.init(id: n, owner: owner, element: original))
    }
    return targets
}

func cgFrames(_ targets: [Target]) -> [UInt32: CGRect]? {
    guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var frames = [UInt32: CGRect]()
    for target in targets {
        let found = rows.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id }
        if found.isEmpty { continue }
        guard found.count == 1, let row = found.first, row[kCGWindowOwnerPID as String] as? Int32 == target.owner.pid,
              row[kCGWindowLayer as String] as? Int == 0, let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
        frames[target.id] = bounds
    }
    return frames
}

struct Samples {
    let owned: [UInt32: OwnedWindowState]
    let cg: [UInt32: CGRect]
    let axMiniature: [UInt32: Bool]
    let axFrames: [UInt32: CGRect]
    let frontPID: pid_t?
}

@MainActor func sample(_ targets: [Target], root: URL) async throws -> Samples? {
    let nonce = UUID().uuidString
    try nonce.write(to: root.appendingPathComponent("sample"), atomically: true, encoding: .utf8)
    let deadline = ContinuousClock.now + .seconds(1)
    let files = ["a", "b"].map { root.appendingPathComponent($0 + "-" + nonce + ".json") }
    while !files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
        guard ContinuousClock.now < deadline else { return nil }
        try await Task.sleep(for: .milliseconds(25))
    }
    let own = try files.flatMap { try JSONDecoder().decode([OwnedWindowState].self, from: Data(contentsOf: $0)) }
    guard Set(own.map(\.number)) == Set(targets.map(\.id)), own.count == targets.count, let cg = cgFrames(targets) else { return nil }
    var bits = [UInt32: Bool](), frames = [UInt32: CGRect]()
    for target in targets {
        bits[target.id] = ax(target.element, kAXMinimizedAttribute) as? Bool
        frames[target.id] = axFrame(target.element)
    }
    return .init(owned: Dictionary(uniqueKeysWithValues: own.map { ($0.number, $0) }), cg: cg, axMiniature: bits, axFrames: frames,
                 frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
}

@MainActor private func readBack(_ targets: [Target], baseline: Samples, miniature: Bool, root: URL) async throws -> [String: Any] {
    let id = targets[0].id
    var consecutive = 0
    var facts = [String: Bool](), focus = [String: Bool]()
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
        if let actual = try await sample(targets, root: root) {
            let others = targets.dropFirst().map(\.id)
            focus = ["frontProcessUnchanged": actual.frontPID == baseline.frontPID,
                     "siblingKeyUnchanged": others.allSatisfy { actual.owned[$0]?.key == baseline.owned[$0]?.key },
                     "targetKeyUnchanged": actual.owned[id]?.key == baseline.owned[id]?.key]
            facts = ["targetAX": actual.axMiniature[id] == miniature,
                     "targetAppKit": actual.owned[id]?.miniature == miniature,
                     "targetCG": miniature ? actual.cg[id] == nil : actual.cg[id] == baseline.cg[id],
                     "restoredPresentation": miniature || (actual.owned[id]?.visible == true && actual.owned[id]?.activeSpace == true &&
                                                            actual.owned[id]?.frame == baseline.owned[id]?.frame && actual.axFrames[id] == baseline.axFrames[id]),
                     "siblingAndOtherApp": others.allSatisfy { n in
                         actual.axMiniature[n] == false && actual.cg[n] == baseline.cg[n] && actual.axFrames[n] == baseline.axFrames[n] &&
                             actual.owned[n]?.visible == baseline.owned[n]?.visible &&
                             actual.owned[n]?.miniature == false && actual.owned[n]?.frame == baseline.owned[n]?.frame &&
                             actual.owned[n]?.activeSpace == baseline.owned[n]?.activeSpace
                     }]
            consecutive = facts.values.allSatisfy { $0 } ? consecutive + 1 : 0
            if consecutive == 2 { return ["status":"PASS", "independentSamples":consecutive, "observed":facts, "focusObservation":focus] }
        } else { consecutive = 0 }
        try await Task.sleep(for: .milliseconds(70))
    } while ContinuousClock.now < deadline
    return ["status":facts.isEmpty ? "UNKNOWN" : "FAIL", "independentSamples":consecutive, "observed":facts, "focusObservation":focus]
}

/// Qualification of a single public AX attribute. The shipping Host has no StageGroup parking dispatcher.
@MainActor func qualifyVisibility(root: URL) async throws {
    var receipt: [String: Any] = ["status":"BLOCKED", "scope":"one enrolled foreign window, one same-owner sibling, one other-app bystander",
        "identity":"retained AX object and owner-assigned AX identifier bound to its declared CGWindowID", "setRequests":0,
        "wholeGroupSwitch":"NOT_RUN", "nativeMembership":"UNKNOWN", "naturalKeyboardInput":"NOT_RUN", "profileChanges":0]
    func save(_ reason: String) throws {
        receipt["reason"] = reason
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: root.appendingPathComponent("visibility.json"),
                                                                                       options: .withoutOverwriting)
    }
    let owners = try ["a", "b"].map { try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent($0 + ".json"))) }
    guard AXIsProcessTrusted(), !StageManagerPreference.ownsWindowDispatch else { try save("readOnlyOwnershipOrAXPreflight"); return }
    guard let a = enroll(owners[0], name: "a"), a.count == 2, let b = enroll(owners[1], name: "b"), b.count == 1 else {
        try save("exactFixtureAXIdentifiersUnavailable"); return
    }
    let all = a + b, target = a[0]
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(target.element, kAXMinimizedAttribute as CFString, &settable) == .success, settable.boolValue,
          let before = try await sample(all, root: root), before.cg.count == 3, before.cg == before.axFrames,
          before.owned.values.allSatisfy({ !$0.miniature && $0.visible && $0.activeSpace }),
          before.axMiniature.values.allSatisfy({ !$0 }), !StageManagerPreference.ownsWindowDispatch else { try save("baselineUnavailable"); return }
    receipt["status"] = "UNKNOWN"
    receipt["setRequests"] = 1
    let parked = AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    receipt["parkSetter"] = parked.rawValue
    let park = try await readBack(all, baseline: before, miniature: true, root: root)
    receipt["park"] = park
    // An app can omit or reclassify a minimized window in AXWindows. Re-enumeration is evidence,
    // never a replacement for the exact AX object retained through this owned fixture's lifetime.
    let expectedIdentifier = "nearpane.fixture.a.0"
    let ownerAlive = (try? birth(target.owner.pid)) == target.owner.birth &&
        NSRunningApplication(processIdentifier: target.owner.pid)?.bundleIdentifier == target.owner.identifier
    let available = !StageManagerPreference.ownsWindowDispatch
    let list = ax(AXUIElementCreateApplication(target.owner.pid), kAXWindowsAttribute) as? [AXUIElement]
    let matches = list?.filter { (ax($0, kAXIdentifierAttribute) as? String) == expectedIdentifier }
    let enumerable = matches?.count == 1 && matches?.first.map { CFEqual($0, target.element) } == true
    let listingConflicts = matches.map { !$0.isEmpty && !enumerable } ?? false
    let legacyRebind = enroll(owners[0], name: "a")?.first.map { CFEqual($0.element, target.element) } ?? false
    let identifier = ax(target.element, kAXIdentifierAttribute) as? String
    var pid: pid_t = 0
    let retainedOwner = AXUIElementGetPid(target.element, &pid) == .success && pid == target.owner.pid
    let fresh = try await sample(all, root: root)
    let held = fresh?.owned[target.id]
    let actual = ax(target.element, kAXMinimizedAttribute) as? Bool
    receipt["restoreIdentity"] = ["ownerGeneration":ownerAlive, "dispatchAvailable":available,
        "windowListReadable":list != nil, "listedIdentifierMatches":matches?.count ?? -1,
        "listedSameObject":enumerable, "originalEnumerationRoute":legacyRebind, "retainedAXOwner":retainedOwner,
        "retainedIdentifierPresent":identifier != nil, "retainedIdentifierMatches":identifier == expectedIdentifier,
        "ownerConfirmedSameNumber":held?.number == target.id, "ownerAndAXAgreeOnState":actual != nil && held?.miniature == actual]
    guard ownerAlive, available, !listingConflicts, retainedOwner, let actual,
          identifier == nil || identifier == expectedIdentifier,
          fresh?.axMiniature[target.id] == actual, held?.number == target.id, held?.miniature == actual
    else { try save("retainedAXOrOwnerAttestationUnavailable"); return }
    if actual {
        receipt["setRequests"] = 2
        receipt["restoreSetter"] = AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse).rawValue
    }
    let restored = try await readBack(all, baseline: before, miniature: false, root: root)
    receipt["restore"] = restored
    if let x = park["status"] as? String, let y = restored["status"] as? String {
        receipt["status"] = x == "FAIL" || y == "FAIL" ? "FAIL" : x == "PASS" && y == "PASS" && actual ? "PASS" : "UNKNOWN"
    }
    try save("singleAttributeRoundTripObserved")
}
