// Standalone observer is read-only. Action methods compile only in the device-lab overview driver.
import AppKit
import ApplicationServices

struct Refusal: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func children(_ parent: AXUIElement, named id: String) throws -> [AXUIElement] {
  guard let children = attr(parent, kAXChildrenAttribute) as? [AXUIElement], children.count <= 256
  else {
    throw Refusal("Dock control children unavailable or unbounded")
  }
  // No descriptions, titles, documents, pixels, or descent into application windows.
  return children.filter { attr($0, kAXIdentifierAttribute) as? String == id }
}

func only(_ elements: [AXUIElement], _ label: String) throws -> AXUIElement {
  guard elements.count == 1 else { throw Refusal("missing or ambiguous " + label) }
  return elements[0]
}

struct SecondarySpacesBar {
  let dock: NSRunningApplication
  let side: CGDirectDisplayID
  let spaces: AXUIElement
  let add: AXUIElement
  let primaryContainer: Bool
}

func secondarySpacesBar(_ displayUUID: UUID) throws -> SecondarySpacesBar? {
  guard AXIsProcessTrusted(), let state = CGSessionCopyCurrentDictionary() as? [String: Any],
    state["kCGSSessionOnConsoleKey"] as? Bool == true,
    state["CGSSessionScreenIsLocked"] as? Bool != true
  else { throw Refusal("unlocked console and existing AX permission required") }
  let displays = NSScreen.screens.compactMap {
    ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
  guard displays.count == 2, Set(displays).count == 2, displays.contains(CGMainDisplayID()),
    let side = displays.first(where: { $0 != CGMainDisplayID() }),
    CGDisplayIsInMirrorSet(side) == 0,
    !CGDisplayBounds(side).intersects(CGDisplayBounds(CGMainDisplayID())),
    let raw = CGDisplayCreateUUIDFromDisplayID(side)?.takeRetainedValue(),
    UUID(uuidString: CFUUIDCreateString(nil, raw) as String) == displayUUID
  else {
    throw Refusal("secondary identity or topology changed")
  }
  let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
  guard apps.count == 1, let dock = apps.first, !dock.isTerminated,
    dock.executableURL?.resolvingSymlinksInPath().path
      == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
  else {
    throw Refusal("unique running system Dock unavailable")
  }
  let root = AXUIElementCreateApplication(dock.processIdentifier)
  AXUIElementSetMessagingTimeout(root, 1)
  let groups = try children(root, named: "mc")
  guard !groups.isEmpty else { return nil }
  let group = try only(groups, "overview")
  let containers = try children(group, named: "mc.display")
  let secondary = try only(
    containers.filter { (attr($0, "AXDisplayID") as? NSNumber)?.uint32Value == side },
    "secondary display group")
  let spaces = try only(children(secondary, named: "mc.spaces"), "secondary spaces bar")
  let button = try only(children(spaces, named: "mc.spaces.add"), "secondary add button")
  var actions: CFArray?
  guard attr(button, kAXRoleAttribute) as? String == kAXButtonRole,
    attr(button, kAXEnabledAttribute) as? Bool != false,
    AXUIElementCopyActionNames(button, &actions) == .success,
    (actions as? [String])?.contains(kAXPressAction as String) == true
  else {
    throw Refusal("enabled secondary add control not confirmed")
  }
  let primary = containers.contains {
    (attr($0, "AXDisplayID") as? NSNumber)?.uint32Value == CGMainDisplayID()
  }
  return SecondarySpacesBar(
    dock: dock, side: side, spaces: spaces, add: button, primaryContainer: primary)
}

func observe(_ displayUUID: UUID) throws -> [String: Any] {
  let bar = try secondarySpacesBar(displayUUID)
  var report: [String: Any] = [
    "state": bar == nil ? "overviewNotExposed" : "secondaryAddControlObserved",
    "display": displayUUID.uuidString, "systemInputs": 0,
    "sampledAt": ISO8601DateFormatter().string(from: Date()),
  ]
  if let bar { report["primaryOverviewContainerPresent"] = bar.primaryContainer }
  return report
}

#if !SECONDARY_OVERVIEW_DRIVER && !SECONDARY_FOCUS_OBSERVER
  @main struct ObserverMain {
    static func main() {
      do {
        guard CommandLine.arguments.count == 2,
          let display = UUID(uuidString: CommandLine.arguments[1])
        else {
          throw Refusal("expected secondary display UUID")
        }
        let data = try JSONSerialization.data(
          withJSONObject: observe(display), options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
      } catch {
        FileHandle.standardError.write(
          Data(((error as? Refusal)?.reason ?? "observation unavailable").utf8))
        exit(2)
      }
    }
  }
#endif

#if SECONDARY_OVERVIEW_DRIVER
  import CryptoKit
  import Darwin

  // Before-state A has exactly one ordinary desktop. The same two display scopes and complete
  // order must be witnessed immediately after the explicit Add press and again before removal.
  private struct ProvisionState: Codable, Equatable {
    let primaryScope: String
    let geometry: [String]
    let sideOrder: [String]
    init(_ display: UUID, source: String) throws {
      let uuid = display.uuidString
      let scopes = try scoped(uuid, source)
      let sides = scopes.filter { $0.hasPrefix(uuid + ":") }
      let main = scopes.filter { !$0.hasPrefix(uuid + ":") }
      guard sides.count == 1, main.count == 1 else { throw Refusal("ambiguous provision scopes") }
      let fields = sides[0].components(separatedBy: ":")
      guard fields.count == 3, fields[1] == source else { throw Refusal("not on source desktop") }
      let ids = try fields[2].components(separatedBy: ",").map { value -> String in
        let entry = value.components(separatedBy: "/")
        guard entry.count == 2, entry[1] == "0", let id = UInt64(entry[0]), id > 0,
          String(id) == entry[0]
        else { throw Refusal("nonordinary or malformed secondary desktop") }
        return entry[0]
      }
      guard Set(ids).count == ids.count, ids.contains(source) else {
        throw Refusal("ambiguous secondary desktop identity")
      }
      primaryScope = main[0]
      sideOrder = ids
      geometry = try NSScreen.screens.map { screen in
        guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
        else { throw Refusal("missing live display") }
        return (CFUUIDCreateString(nil, uuid) as String) + ":"
          + NSStringFromRect(CGDisplayBounds(n.uint32Value)) + ":"
          + String(CGDisplayRotation(n.uint32Value)) + ":"
          + String(Double(screen.backingScaleFactor))
      }.sorted()
    }

    func addition(to before: Self, source: String) throws -> String {
      let difference = sideOrder.filter { !before.sideOrder.contains($0) }
      guard primaryScope == before.primaryScope, geometry == before.geometry,
        before.sideOrder == [source],
        sideOrder.count == 2, difference.count == 1
      else { throw Refusal("change is not one adjacent ordinary secondary desktop") }
      return difference[0]
    }
  }

  private struct ProvisionIntent: Codable {
    let operation: UUID
    let display: UUID
    let source: String
    let initial: ProvisionState
    let sourceTileLabel: String  // Digest of the system desktop button description. Never read application titles.
    let boot: String
    let issuedUptime: Double
    let dockBirth: Date
  }

  private struct ProvisionResult: Codable {
    let intent: ProvisionIntent
    let target: String
    let after: ProvisionState
  }

  private struct TilePair: Codable {
    let operation: UUID
    let sourceLabel, targetLabel: String
  }

  private struct ReceiptFolder {
    let fd: Int32
    init(_ url: URL) throws {
      fd = open(url.path, O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      var info = stat()
      guard fd >= 0 else { throw Refusal("private desktop trial directory unavailable") }
      guard fstat(fd, &info) == 0, info.st_mode & 0o077 == 0, info.st_uid == getuid(),
        flock(fd, LOCK_EX | LOCK_NB) == 0
      else {
        close(fd)
        throw Refusal("unsafe or occupied desktop trial directory")
      }
    }
    func put<T: Encodable>(_ value: T, _ name: String) throws {
      let bytes = try JSONEncoder().encode(value)
      let temp = ".publish-" + UUID().uuidString
      let n = openat(fd, temp, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
      guard n >= 0 else { throw Refusal("cannot stage " + name) }
      defer { unlinkat(fd, temp, 0) }
      let handle = FileHandle(fileDescriptor: n, closeOnDealloc: true)
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      guard renameatx_np(fd, temp, fd, name, UInt32(RENAME_EXCL)) == 0, fsync(fd) == 0 else {
        throw Refusal("receipt already exists or could not be committed: " + name)
      }
    }
    func read<T: Decodable>(_ name: String, as: T.Type) throws -> T {
      let n = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard n >= 0 else { throw Refusal("missing " + name) }
      let h = FileHandle(fileDescriptor: n, closeOnDealloc: true)
      var i = stat()
      guard fstat(n, &i) == 0, i.st_mode & S_IFMT == S_IFREG, i.st_uid == getuid(), i.st_nlink == 1,
        i.st_mode & 0o077 == 0, i.st_size > 0, i.st_size < 16_384
      else { throw Refusal("unsafe " + name) }
      return try JSONDecoder().decode(T.self, from: h.readToEnd() ?? Data())
    }
  }

  private func currentBoot() throws -> String {
    var buffer = [CChar](repeating: 0, count: 64)
    var size = buffer.count
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0, size > 1,
      size <= buffer.count,
      let uuid = UUID(
        uuidString: String(
          decoding: buffer.prefix(size - 1).map(UInt8.init(bitPattern:)), as: UTF8.self))
    else { throw Refusal("current boot identity unavailable") }
    return uuid.uuidString
  }

  // Some AX controls publish a composite frame, others publish position and size.
  private func controlFrame(_ control: AXUIElement) -> CGRect? {
    let split = frame(control)
    guard let raw = attr(control, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID(),
      AXValueGetType(raw as! AXValue) == .cgRect
    else { return split }
    var direct = CGRect.zero
    guard AXValueGetValue(raw as! AXValue, .cgRect, &direct), split == nil || split == direct else {
      return nil
    }
    return direct
  }

  private func actionsOf(_ control: AXUIElement) throws -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(control, &raw) == .success, let actions = raw as? [String]
    else {
      throw Refusal("system control actions unavailable")
    }
    return actions
  }

  // Diagnostic only. Enumerate the Dock's immediate system containers, then descend exclusively
  // through the confirmed secondary spaces bar. Never request names, labels, descriptions or pixels.
  func overviewSkeleton(_ display: UUID) -> [String: Any] {
    var report: [String: Any] = ["display": display.uuidString, "systemInputs": 0]
    let state = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard AXIsProcessTrusted(), state?["kCGSSessionOnConsoleKey"] as? Bool == true,
          state?["CGSSessionScreenIsLocked"] as? Bool != true else { report["state"]="consoleUnavailable"; return report }
    let ids = NSScreen.screens.compactMap { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value }
    guard ids.count == 2, let side = ids.first(where: { $0 != CGMainDisplayID() }),
          let raw = CGDisplayCreateUUIDFromDisplayID(side)?.takeRetainedValue(),
          UUID(uuidString: CFUUIDCreateString(nil, raw) as String) == display else { report["state"]="displayMismatch"; return report }
    let docks = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock")
    guard docks.count == 1, let dock=docks.first, !dock.isTerminated,
          dock.executableURL?.resolvingSymlinksInPath().path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    else { report["state"]="dockUnavailable"; return report }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root,0.20)
    let safeIDs: Set<String> = ["mc","mc.display","mc.spaces","mc.spaces.list","mc.spaces.add","mc.spaces.space","mc.windows"]
    let safeRoles: Set<String> = ["AXGroup","AXRadioGroup","AXList","AXButton","AXRadioButton","AXScrollArea","AXWindow"]
    let sideBounds=CGDisplayBounds(side)
    var remaining=60
    func walk(_ parent:AXUIElement, depth:Int, isSecondary:Bool) -> [String:Any] {
      var values:CFTypeRef?
      let status=AXUIElementCopyAttributeValue(parent,kAXChildrenAttribute as CFString,&values)
      guard status == .success, let elements=values as? [AXUIElement], elements.count<=256 else {
        return ["childrenAXStatus":status.rawValue, "childrenUnavailable":true]
      }
      var rows:[[String:Any]]=[]
      for el in elements {
        guard remaining>0 else { break }
        remaining -= 1
        guard let id=attr(el,kAXIdentifierAttribute) as? String, id=="mc" || id.hasPrefix("mc.") else { continue }
        let role=attr(el,kAXRoleAttribute) as? String ?? ""
        var entry:[String:Any]=["id":safeIDs.contains(id) ? id : "mc.other", "role": safeRoles.contains(role) ? role : "other"]
        let screen=(attr(el,"AXDisplayID") as? NSNumber)?.uint32Value
        if let screen {entry["displayID"]=screen}
        let branchOnSide=id=="mc.display" ? screen==side : isSecondary
        if branchOnSide && safeIDs.contains(id) && id != "mc.windows" {
          if let r=controlFrame(el), !r.isEmpty, sideBounds.contains(r) {entry["sideBounds"]=[r.minX,r.minY,r.width,r.height]}
          else {entry["sideBoundsConfirmed"]=false}
          if let actions=try? actionsOf(el) {
            entry["actions"]=actions.filter{["AXPress","AXRemoveDesktop","AXCancel","AXShowMenu"].contains($0)}
          }
        }
        if (depth==0 && id=="mc") || (depth==1 && id=="mc.display" && branchOnSide) ||
             (branchOnSide && depth<4 && ["mc.spaces","mc.spaces.list"].contains(id)) {
          entry["children"]=walk(el,depth:depth+1,isSecondary:branchOnSide)
        }
        rows.append(entry)
      }
      return ["childCount":elements.count, "mcNodes":rows]
    }
    report["state"]="observed"; report["sideDisplayID"]=side
    report["dock"]=walk(root,depth:0,isSecondary:false)
    report["limited"]=remaining==0
    return report
  }

  private struct ProvisionControls {
    let bar: SecondarySpacesBar
    let tiles: [AXUIElement]
    let labels: [String]
    init(display: UUID, count: Int) throws {
      guard let observed = try secondarySpacesBar(display), !observed.dock.isTerminated,
        let addFrame = controlFrame(observed.add), !addFrame.isEmpty,
        CGDisplayBounds(observed.side).contains(addFrame)
      else { throw Refusal("secondary add button frame or Dock identity unavailable") }
      let list = try only(
        children(observed.spaces, named: "mc.spaces.list"), "secondary desktop list")
      guard let items = attr(list, kAXChildrenAttribute) as? [AXUIElement], items.count == count
      else {
        throw Refusal("secondary system desktop buttons differ from ordinary inventory")
      }
      let secondary = CGDisplayBounds(observed.side)
      let bounds = try items.map { tile -> CGRect in
        guard let r = controlFrame(tile), !r.isEmpty, secondary.contains(r),
          attr(tile, kAXEnabledAttribute) as? Bool != false,
          (try actionsOf(tile)).contains(kAXPressAction as String)
        else {
          throw Refusal("secondary desktop tile not enabled or outside display")
        }
        return r
      }
      guard zip(bounds, bounds.dropFirst()).allSatisfy({ $0.maxX <= $1.minX }) else {
        throw Refusal("desktop buttons overlap or visual order is ambiguous")
      }
      let values = try items.map { tile -> String in
        guard let text = attr(tile, kAXDescriptionAttribute) as? String, !text.isEmpty else {
          throw Refusal("system desktop tile has no identity across openings")
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
      }
      guard Set(values).count == count else {
        throw Refusal("indistinguishable system desktop tiles")
      }
      bar = observed
      tiles = items
      labels = values
    }
  }

  // This function is entered only by the timed secondary fixture while its own overview is visible.
  // The caller authenticates the user's current loan (including original focus) immediately before
  // each irreversible AX action. The occupancy callback runs live for the named target.
  func provisionSecondaryDesktop(
    _ action: String, directory: URL, display: UUID, source: String,
    requireAuthorizedAction: () throws -> Void,
    requireSafeOccupancy: (_ target: String?) throws -> Void
  ) throws -> String {
    guard ["create", "remove"].contains(action) else {
      throw Refusal("unknown desktop preparation action")
    }
    let folder = try ReceiptFolder(directory)
    defer { close(folder.fd) }
    let state = { try ProvisionState(display, source: source) }
    let boot = try currentBoot()
    func observeChange<T: Equatable>(
      from origin: ProvisionState, _ project: (ProvisionState) throws -> T
    ) throws -> (ProvisionState, T) {
      let end = ProcessInfo.processInfo.systemUptime + 3
      var first: (ProvisionState, T)?
      repeat {
        let current = try state()
        if current != origin {
          let result = try project(current)
          if let previous = first, previous.0 == current, previous.1 == result {
            return (current, result)
          }
          first = (current, result)
        } else if first != nil {
          throw Refusal("desktop change rebounded; do not replay action")
        }
        spin(0.12)
      } while ProcessInfo.processInfo.systemUptime < end
      throw Refusal("no stable result for spent desktop action")
    }

    let original = try state()
    if action == "create" {
      guard original.sideOrder == [source] else {
        throw Refusal("additional desktop already exists; creation refused")
      }
      let initialUI = try ProvisionControls(display: display, count: 1)
      guard let birth = initialUI.bar.dock.launchDate else {
        throw Refusal("missing Dock generation")
      }
      try requireSafeOccupancy(nil)
      let intent = ProvisionIntent(
        operation: UUID(), display: display, source: source, initial: original,
        sourceTileLabel: initialUI.labels[0], boot: boot,
        issuedUptime: ProcessInfo.processInfo.systemUptime, dockBirth: birth)
      let ui = try ProvisionControls(display: display, count: 1)
      guard CFEqual(initialUI.bar.add, ui.bar.add), initialUI.labels == ui.labels,
        (try state()) == original
      else { throw Refusal("secondary add control changed") }
      try folder.put(intent, "create-intent.json")
      try requireAuthorizedAction()
      guard AXUIElementPerformAction(ui.bar.add, kAXPressAction as CFString) == .success else {
        throw Refusal("secondary Add returned no acknowledgement; intent remains spent")
      }
      let (after, target) = try observeChange(from: original) {
        try $0.addition(to: original, source: source)
      }
      try folder.put(ProvisionResult(intent: intent, target: target, after: after), "created.json")
      // A retained element can survive the Add even if its displayed ordinal changes. Preserve its
      // identity and the unique new sibling if they are still visible in this same overview.
      if let pair = try? ProvisionControls(display: display, count: 2),
        let a = after.sideOrder.firstIndex(of: source),
        let b = after.sideOrder.firstIndex(of: target),
        pair.bar.dock.launchDate == birth, CFEqual(ui.tiles[0], pair.tiles[a]),
        !CFEqual(ui.tiles[0], pair.tiles[b])
      {
        try folder.put(
          TilePair(
            operation: intent.operation, sourceLabel: pair.labels[a], targetLabel: pair.labels[b]),
          "created-tiles.json")
      }
      return target
    }

    let created = try folder.read("created.json", as: ProvisionResult.self)
    let intent = try folder.read("create-intent.json", as: ProvisionIntent.self)
    let elapsed = ProcessInfo.processInfo.systemUptime - intent.issuedUptime
    guard created.intent.operation == intent.operation, created.intent.display == display,
      intent.display == display,
      intent.source == source, intent.boot == boot, elapsed >= 0, elapsed <= 900,
      original == created.after,
      (try original.addition(to: intent.initial, source: source)) == created.target,
      let a = original.sideOrder.firstIndex(of: source),
      let b = original.sideOrder.firstIndex(of: created.target), a != b
    else {
      throw Refusal(
        "created desktop receipt no longer matches original display, boot, order or source")
    }
    let first = try ProvisionControls(display: display, count: 2)
    guard first.bar.dock.launchDate == intent.dockBirth else {
      throw Refusal("original system Dock restarted")
    }
    // Match A across the two overviews, using either its unchanged unique label or the
    // labels tied to the retained A object and its new sibling at creation time.
    if let pair = try? folder.read("created-tiles.json", as: TilePair.self) {
      try need(
        pair.operation == intent.operation && pair.sourceLabel == first.labels[a]
          && pair.targetLabel == first.labels[b], "system desktop buttons changed after creation")
    } else {
      try need(
        first.labels[a] == intent.sourceTileLabel,
        "cannot identify the original A tile after reopening overview")
    }
    try requireSafeOccupancy(created.target)
    let ui = try ProvisionControls(display: display, count: 2)
    var actions: CFArray?
    let remove = "AXRemoveDesktop"
    guard ui.bar.dock.launchDate == intent.dockBirth, ui.labels == first.labels,
      CFEqual(first.tiles[b], ui.tiles[b]), (try state()) == original,
      AXUIElementCopyActionNames(ui.tiles[b], &actions) == .success,
      (actions as? [String])?.contains(remove) == true
    else { throw Refusal("exact inactive B tile or Remove Desktop action unavailable") }
    try folder.put(created, "remove-intent.json")
    try requireAuthorizedAction()
    guard AXUIElementPerformAction(ui.tiles[b], remove as CFString) == .success else {
      throw Refusal("removal outcome unknown; do not replay")
    }
    _ = try observeChange(from: original) { current in
      guard current == intent.initial else {
        throw Refusal("result differs from original two-display inventory")
      }
      return true
    }
    try folder.put(created, "removed.json")
    return created.target
  }
#endif
