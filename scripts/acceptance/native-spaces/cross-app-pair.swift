// Compiled with the established PairCard and PairSurface hit, cursor and AX checks.
private struct CrossAction: Decodable {
  let operation: String
  let run: FiveRun
  let originalFront: pid_t
  let originalFrontBirth: UInt64
  let hardware: [UInt32]?
  let originalPanel: UInt32?
  let initialFrames: [[Double]]?
  let deadline: Double?
}
private struct CrossRefusal: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
extension PairSurface {
  fileprivate init?(
    cross owners: [FiveOwner], host: NSRunningApplication, rows: [Object], display: String
  ) {
    let index = Sidebar(host, rows: rows)
    let keys = owners.map(\.card)
    let cards = keys.compactMap { key -> PairCard? in
      guard let hits = index.controls[key], hits.count == 1 else { return nil }
      return PairCard(hits[0], host: host.processIdentifier)
    }
    guard Set(index.controls.keys.filter { $0.hasPrefix("current-desktop-window:") }) == Set(keys),
      cards.count == 2, cards[0].panel == cards[1].panel, !cards[0].rect.intersects(cards[1].rect),
      let panel = pairBounds(rows, cards[0].panel, host.processIdentifier),
      cards.allSatisfy({ panel.contains($0.rect) }),
      NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
      let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
      id == CGMainDisplayID(),
      let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
      (CFUUIDCreateString(nil, uuid) as String).uppercased() == display.uppercased()
    else { return nil }
    let frame = CGDisplayBounds(id)
    let usable = screen.visibleFrame
    let visible = CGRect(
      x: frame.minX + usable.minX - screen.frame.minX,
      y: frame.minY + screen.frame.maxY - usable.maxY,
      width: usable.width, height: usable.height)
    guard visible.contains(panel.insetBy(dx: 1, dy: 1)) else { return nil }
    self.cards = cards
    self.pid = host.processIdentifier
    self.panel = panel
    self.panelID = cards[0].panel
    self.visible = visible
    self.displayUUID = display
    self.publishedReasons = []
  }
}
private func crossSigned(_ pid: pid_t, _ identifier: String) -> Bool {
  var code: SecCode?
  var rule: SecRequirement?
  let statement =
    "anchor apple generic and identifier \"" + identifier
    + "\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  return SecCodeCopyGuestWithAttributes(
    nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess
    && SecRequirementCreateWithString(statement as CFString, [], &rule) == errSecSuccess
    && code != nil && rule != nil && SecCodeCheckValidity(code!, [], rule) == errSecSuccess
}
private func scope(_ a: CrossAction, dragging: Bool) throws -> NSRunningApplication {
  let run = a.run
  guard run.valid, run.owners.count <= 2, let kit = PreviewCensus.kit(CommandLine.arguments[0]),
    let host, host.processIdentifier == run.hostPID,
    birthMicroseconds(run.hostPID) == run.hostBirth,
    runningCodeHash(run.hostPID) == run.hostHash,
    splitProcessPath(run.hostPID) == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
    crossSigned(run.hostPID, bundleID), AXIsProcessTrusted(),
    CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
      as? Bool == false,
    NSScreen.screens.count == 1,
    let all = inventory(requireComplete: true), all.count == 1, let s = all.first,
    s["scope"] as? String == run.display,
    s["current"] as? UInt64 == run.space, let records = s["records"] as? [Object],
    records.filter({
      $0["id"] as? UInt64 == run.space && $0["type"] as? Int == 0
        && $0["uuid"] as? String == run.spaceUUID
    }).count == 1
  else { throw CrossRefusal("installedHostOrStageDisplaySpaceChanged") }
  for owner in run.owners {
    let path = kit.appendingPathComponent("Five Notes \(owner.slot+1).app/Contents/MacOS/FiveNotes")
      .path
    guard birthMicroseconds(owner.pid) == owner.birth, runningCodeHash(owner.pid) == owner.hash,
      crossSigned(owner.pid, owner.identifier), splitProcessPath(owner.pid) == path,
      let app = NSRunningApplication(processIdentifier: owner.pid), !app.isTerminated,
      app.activationPolicy == .regular,
      app.bundleIdentifier == owner.identifier,
      let registered = app.bundleURL?.appendingPathComponent("Contents/MacOS/FiveNotes").path,
      splitRealPath(registered) == path,
      NPReadWindowSpaces(owner.number) as? [UInt64] == [run.space]
    else { throw CrossRefusal("enrolledOwnerOrWindowChangedSlot" + String(owner.slot)) }
  }
  let census = PreviewCensus.report(
    run.space, host: run.hostPID, fixture: run.owners.first?.pid ?? 0,
    expected: run.owners.map(\.number), visible: true,
    enrolledOwners: Dictionary(uniqueKeysWithValues: run.owners.map { ($0.number, $0.pid) }))
  guard census["admitted"] as? Bool == true, census["expectedProven"] as? Bool == true else {
    throw CrossRefusal("enrolledWindowCensusUnconfirmed")
  }
  if let hid = a.hardware, p2Physical() != hid { throw CrossRefusal("hardwareChanged") }
  guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
    throw CrossRefusal("foregroundUnknown")
  }
  let initial =
    !dragging && run.owners.count < 2 && front == a.originalFront
    && birthMicroseconds(front) == a.originalFrontBirth
  guard initial || front == run.hostPID || run.owners.contains(where: { $0.pid == front }) else {
    throw CrossRefusal("foregroundLeftEnrollment")
  }
  return host
}
private func windowFrames(_ owners: [FiveOwner], rows: [Object]) throws -> (
  ax: [CGRect], cg: [CGRect]
) {
  var axFrames = [CGRect]()
  var cgFrames = [CGRect]()
  for owner in owners {
    let root = AXUIElementCreateApplication(owner.pid)
    guard AXUIElementSetMessagingTimeout(root, 0.25) == .success,
      let roster = AXWindowList.read(root, limit: 16).windows
    else { throw CrossRefusal("fixtureAXRosterUnavailable") }
    let matching = roster.filter {
      pairOwner($0, owner.pid) && NPReadAXWindowNumber($0) == owner.number
    }
    guard matching.count == 1, let w = matching.first,
      value(w, kAXRoleAttribute) as? String == kAXWindowRole,
      value(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
      value(w, kAXModalAttribute) as? Bool == false,
      value(w, kAXMinimizedAttribute) as? Bool == false, value(w, "AXFullScreen") as? Bool == false,
      let ax = pairAXRect(w), let cg = pairBounds(rows, owner.number, owner.pid), pairNear(ax, cg),
      CGDisplayBounds(CGMainDisplayID()).contains(cg)
    else { throw CrossRefusal("AXAndCGOrdinaryFrameUnconfirmedSlot" + String(owner.slot)) }
    axFrames.append(ax)
    cgFrames.append(cg)
  }
  return (axFrames, cgFrames)
}
private func crossRun(_ a: CrossAction) -> Object {
  var out: Object = [
    "status": "BLOCKED", "issued": false, "events": [], "operation": a.operation, "pixels": 0,
  ]
  var events = [Object]()
  var receiver: PairPointerReceiver?
  func done(_ why: String?) -> Object {
    if let why { out["reason"] = why }
    out["events"] = events
    if let receiver {
      PairPointerReceiver.pump(0.035)
      out["hostRouting"] = receiver.receipt()
      receiver.close()
    }
    return out
  }
  do {
    guard ["read", "right"].contains(a.operation), a.originalFront > 1, a.originalFrontBirth > 0,
      pairOwnsIsolatedHome(a.run.hostPID)
    else { throw CrossRefusal("privateInstalledLeaseUnavailable") }
    let right = a.operation == "right"
    let run = a.run
    let host = try scope(a, dragging: right)
    guard let rows = pairRows() else { throw CrossRefusal("currentStackUnavailable") }
    let frames = try windowFrames(run.owners, rows: rows)
    let surface = PairSurface(cross: run.owners, host: host, rows: rows, display: run.display)
    let display = CGDisplayBounds(CGMainDisplayID())
    guard let screen = NSScreen.screens.first else {
      throw CrossRefusal("physicalScreenUnavailable")
    }
    let usable = screen.visibleFrame
    let visible = CGRect(
      x: display.minX + usable.minX - screen.frame.minX,
      y: display.minY + screen.frame.maxY - usable.maxY, width: usable.width, height: usable.height)
    let identities = run.owners.map { owner -> Object in
      [
        "slot": owner.slot, "identifier": owner.identifier, "pid": owner.pid, "birth": owner.birth,
        "number": owner.number, "hash": owner.hash,
      ]
    }
    var geometry: Object = [
      "owners": identities,
      "clock": pairClock(), "displayUUID": run.display, "members": run.owners.map(\.number),
      "visible": windowReceiptRect(visible), "ax": frames.ax.map(windowReceiptRect),
      "cg": frames.cg.map(windowReceiptRect), "leaseState": "BOUND",
    ]
    if let surface {
      geometry["panelID"] = surface.panelID
      geometry["panel"] = windowReceiptRect(surface.panel)
      geometry["cards"] = surface.cards.map { windowReceiptRect($0.rect) }
    }
    out["geometry"] = geometry
    out["hardware"] = p2Physical()
    out["foregroundPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if !right {
      out["status"] = "READ"
      return done(nil)
    }
    guard let surface, surface.panelID == a.originalPanel, run.owners.count == 2,
      let hid = a.hardware, hid.count == 13,
      let baseline = a.initialFrames, baseline.count == 2,
      zip(baseline, frames.cg).allSatisfy({ r, f in fiveRect(r).map { pairNear($0, f) } == true }),
      let until = a.deadline, until > pairClock(), until - pairClock() <= 8,
      NSEvent.pressedMouseButtons == 0,
      CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState)
    else { throw CrossRefusal("twoCardsFreshGeometryOrPostAccessUnavailable") }
    let cardA = surface.cards[0]
    let cardB = surface.cards[1]
    func issue(_ p: CGPoint, _ card: PairCard?, _ down: Bool) -> String? {
      surface.hitIssue(p, card: card, dragging: down, cursor: { _ in })
    }
    func endpoint(_ c: PairCard, _ x: CGFloat) throws -> CGPoint {
      for y: CGFloat in [0.5, 0.32, 0.68, 0.22, 0.78] {
        let p = c.point(x, y: y)
        if issue(p, c, false) == nil { return p }
      }
      throw CrossRefusal("verifiedCardPointUnavailable")
    }
    let start = try endpoint(cardA, 0.5)
    let end = try endpoint(cardB, 0.75)
    let tag = Int64.random(in: 1...Int64.max)
    receiver = PairPointerReceiver(host: run.hostPID, panel: surface.panelID, tag: tag)
    guard receiver?.receipt()["status"] as? String == "NO_TAGGED_EVENTS" else {
      throw CrossRefusal("passiveHostReceiverUnavailable")
    }
    var previous = start
    var down = false
    func post(_ kind: CGEventType, _ p: CGPoint) throws {
      guard
        let e = CGEvent(
          mouseEventSource: source, mouseType: kind, mouseCursorPosition: p, mouseButton: .left),
        let delta = PairPointerMotion.apply(e, from: previous, to: p), p2Physical() == hid
      else { throw CrossRefusal("mousePacketUnavailable") }
      e.flags = []
      e.setIntegerValueField(.eventSourceUserData, value: tag)
      e.setIntegerValueField(.mouseEventClickState, value: 1)
      let t = pairClock()
      e.timestamp = DispatchTime.now().uptimeNanoseconds
      e.post(tap: .cgSessionEventTap)
      events.append([
        "type": kind.rawValue, "point": [p.x, p.y], "quartzDelta": delta, "beforePost": t,
        "afterPost": pairClock(), "eventTimestampNS": e.timestamp,
      ])
      previous = p
      out["issued"] = true
    }
    func check(_ p: CGPoint, _ card: PairCard?) throws {
      guard pairClock() <= until, p2Physical() == hid else {
        throw CrossRefusal("expiredOrSuperseded")
      }
      _ = try scope(a, dragging: true)
      if let reason = issue(p, card, down) { throw CrossRefusal(reason) }
    }
    do {
      try check(start, cardA)
      try post(.leftMouseDown, start)
      down = true
      PairPointerReceiver.pump(0.09)
      for i in 1...9 {
        let p = PairPointerMotion.point(from: start, to: end, fraction: CGFloat(i) / 9)
        try check(p, nil)
        try post(.leftMouseDragged, p)
        PairPointerReceiver.pump(0.016)
      }
      PairPointerReceiver.pump(0.06)
      try check(end, cardB)
      try post(.leftMouseUp, end)
      down = false
    } catch {
      if down, birthMicroseconds(run.hostPID) == run.hostBirth,
        let release = CGEvent(
          mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: start,
          mouseButton: .left)
      {
        release.flags = []
        release.setIntegerValueField(.eventSourceUserData, value: tag)
        release.postToPid(run.hostPID)
        out["cancelledAtOriginalCard"] = true
      }
      throw error
    }
    out["status"] = "DISPATCHED"
    return done(nil)
  } catch let refusal as CrossRefusal { return done(refusal.reason) } catch {
    return done("unexpectedObservationError")
  }
}
let requestBytes = FileHandle.standardInput.readDataToEndOfFile()
let answer: Object
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "compare-roster",
  requestBytes.count < 16_384,
  let action = try? JSONDecoder().decode(CrossAction.self, from: requestBytes)
{
  answer = crossRun(action)
} else {
  answer = ["status": "BLOCKED", "issued": false, "reason": "invalidTwoOwnerRequest"]
}
FileHandle.standardOutput.write(
  try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]) + Data([10]))
