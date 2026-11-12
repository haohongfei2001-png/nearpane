// Standalone observer is read-only. Action methods compile only in the device-lab overview driver.
import AppKit
import ApplicationServices
import Security

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

// Verify the live hit-test owner's Apple code requirement before examining its AX metadata.
func overviewHost(_ pid:pid_t) -> String? {
  guard let app=NSRunningApplication(processIdentifier:pid), !app.isTerminated,
        let id=app.bundleIdentifier, let actual=app.executableURL?.resolvingSymlinksInPath().path else {return nil}
  let hosts=["com.apple.dock":"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
             "com.apple.WindowManager":"/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager",
             "com.apple.exposelauncher":"/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"]
  guard hosts[id]==actual else {return nil}
  var code:SecCode?, requirement:SecRequirement?
  guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid: NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess,
        let code, SecRequirementCreateWithString(("anchor apple and identifier \""+id+"\"") as CFString,[],&requirement)==errSecSuccess,
        let requirement, SecCodeCheckValidity(code,[],requirement)==errSecSuccess else {return nil}
  return id
}

func only(_ elements: [AXUIElement], _ label: String) throws -> AXUIElement {
  guard elements.count == 1 else { throw Refusal("missing or ambiguous " + label) }
  return elements[0]
}

struct SecondarySpacesBar {
  let dock: NSRunningApplication
  let owner: NSRunningApplication
  let side: CGDirectDisplayID
  let spaces: AXUIElement
  let add: AXUIElement
  let container: AXUIElement
  fileprivate let addLocation: ControlLocation
  let primaryContainer: Bool
}

private func reportedFrames(_ el:AXUIElement) -> (direct:CGRect?,split:CGRect?) {
  var direct:CGRect?, split:CGRect?
  if let p=attr(el,kAXPositionAttribute), let sz=attr(el,kAXSizeAttribute),
     CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(sz)==AXValueGetTypeID() {
    var pos=CGPoint.zero, size=CGSize.zero
    if AXValueGetValue(p as! AXValue,.cgPoint,&pos), AXValueGetValue(sz as! AXValue,.cgSize,&size) {
      split=CGRect(origin:pos,size:size)
    }
  }
  if let raw=attr(el,"AXFrame"), CFGetTypeID(raw)==AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .cgRect {
    var rect=CGRect.zero
    if AXValueGetValue(raw as! AXValue,.cgRect,&rect) {direct=rect}
  }
  return (direct,split)
}
private func systemControlFrame(_ el:AXUIElement) -> CGRect? {
  let f=reportedFrames(el)
  if let direct=f.direct, let split=f.split, direct != split {return nil}
  return f.direct ?? f.split
}
private func childOf(_ el:AXUIElement,_ parent:AXUIElement) -> Bool {
  guard let actual=attr(el,kAXParentAttribute), CFGetTypeID(actual)==AXUIElementGetTypeID() else {return false}
  return CFEqual(actual,parent)
}
// A hit witness is about the owner and the exact accessibility object under a point.
// Probe coordinates are never used to issue mouse input.
fileprivate enum ControlLocation: Equatable {
  case frame(CGRect)
  case hit(CGPoint)

  var left: CGFloat {
    switch self { case .frame(let r): return r.minX; case .hit(let p): return p.x }
  }
  var right: CGFloat {
    switch self { case .frame(let r): return r.maxX; case .hit(let p): return p.x }
  }

  func recheck(_ element: AXUIElement, owner: pid_t, in area: CGRect) -> Bool {
    switch self {
    case .frame(let expected):
      let f = reportedFrames(element)
      return compatibleFrames(f.direct, f.split, inside: area) && (f.direct ?? f.split) == expected
    case .hit(let point):
      return area.contains(point) && exactHit(element, owner: owner)(point)
    }
  }
}

private func exactHit(_ element: AXUIElement, owner: pid_t) -> (CGPoint) -> Bool {
  let root = AXUIElementCreateSystemWide()
  AXUIElementSetMessagingTimeout(root, 0.10)
  return { point in
    var result: AXUIElement?, pid: pid_t = 0
    return AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &result) == .success &&
      result.map { AXUIElementGetPid($0, &pid) == .success && pid == owner && CFEqual(element, $0) } == true
  }
}

private func probePoints(in area: CGRect, add: Bool) -> [CGPoint] {
  guard area.minX.isFinite, area.minY.isFinite, area.width.isFinite, area.height.isFinite,
        area.width >= 4, area.height >= 4 else { return [] }
  // Sample the right edge before the rest of the system strip. Include its final 20 pt
  // and separate rows so a compact bar and a fully expanded bar are both covered.
  let xs: [CGFloat] = add ? [2, 7, 15, 24, 36, 52, 72, 96].map { area.maxX - $0 } :
    [0.5, 0.375, 0.625, 0.25, 0.75, 0.125, 0.875, 0.4375, 0.5625].map { area.minX + area.width * $0 }
  return [0.5, 0.25, 0.75, 0.125, 0.875].flatMap { fraction in
    xs.map { CGPoint(x: $0, y: area.minY + area.height * fraction) }
  }.filter { area.contains($0) }
}

private func confirmedHit(_ points: [CGPoint], until deadline: TimeInterval, matches: (CGPoint) -> Bool,
                          settle: () -> Void) -> ControlLocation? {
  for point in points {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
    if matches(point) {
      settle()
      guard ProcessInfo.processInfo.systemUptime < deadline, matches(point) else { return nil }
      return .hit(point)
    }
  }
  return nil
}

private func activationPoint(_ element: AXUIElement) -> CGPoint? {
  guard let value = attr(element, "AXActivationPoint"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  let ax = value as! AXValue
  var point = CGPoint.zero
  guard AXValueGetType(ax) == .cgPoint, AXValueGetValue(ax, .cgPoint, &point),
        point.x.isFinite, point.y.isFinite else { return nil }
  return point
}

private func locate(_ element: AXUIElement, owner: pid_t, in area: CGRect, add: Bool) -> ControlLocation? {
  let frames = reportedFrames(element)
  if compatibleFrames(frames.direct, frames.split, inside: area), let rect = frames.direct ?? frames.split {
    return .frame(rect)
  }
  var candidates = probePoints(in: area, add: add)
  if let point = activationPoint(element), area.contains(point) { candidates.insert(point, at: 0) }
  return confirmedHit(candidates, until: ProcessInfo.processInfo.systemUptime + 0.45,
                      matches: exactHit(element, owner: owner), settle: { Thread.sleep(forTimeInterval: 0.045) })
}

private func inTileOrder(_ locations: [ControlLocation]) -> Bool {
  zip(locations, locations.dropFirst()).allSatisfy { a, b in
    if case .frame = a, case .frame = b { return a.right <= b.left }
    return a.right < b.left
  }
}
private func compatibleFrames(_ direct:CGRect?,_ split:CGRect?,inside bounds:CGRect) -> Bool {
  if let a=direct, let b=split, a != b {return false}
  // A command is allowed only with affirmative geometry on the display named by its AX ancestors.
  guard let rect = direct ?? split else { return false }
  return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    && rect.width > 0 && rect.height > 0 && bounds.contains(rect)
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
  guard overviewHost(dock.processIdentifier)=="com.apple.dock" else { throw Refusal("system Dock identity changed") }
  var roots:[(NSRunningApplication,AXUIElement)]=[(dock,group)]
  let wm=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.WindowManager")
  if wm.count==1, let host=wm.first, overviewHost(host.processIdentifier)=="com.apple.WindowManager" {
    let hostRoot=AXUIElementCreateApplication(host.processIdentifier)
    AXUIElementSetMessagingTimeout(hostRoot,0.3)
    roots.append((host,hostRoot))
    let mc=try children(hostRoot,named:"mc")
    if mc.count==1 {roots.append((host,mc[0]))}
  }
  var bars:[SecondarySpacesBar]=[]
  for (owner,scope) in roots {
    let containers=try children(scope,named:"mc.display")
    for container in containers where (attr(container,"AXDisplayID") as? NSNumber)?.uint32Value==side {
      let spaces=try only(children(container,named:"mc.spaces"),"secondary spaces bar")
      let add=try only(children(spaces,named:"mc.spaces.add"),"secondary add button")
      let nodes=[container,spaces,add]
      guard nodes.allSatisfy({element in
        var pid:pid_t=0
        return AXUIElementGetPid(element,&pid) == .success && pid==owner.processIdentifier
      }), let strip=systemControlFrame(spaces), !strip.isEmpty, CGDisplayBounds(side).contains(strip),
          systemControlFrame(container)==CGDisplayBounds(side),
          childOf(add,spaces), childOf(spaces,container),
          attr(add,kAXRoleAttribute) as? String == kAXButtonRole,
          attr(add,kAXEnabledAttribute) as? Bool == true,
          let location=locate(add,owner:owner.processIdentifier,in:strip,add:true)
        else {throw Refusal("secondary control geometry, physical hit or owner unconfirmed")}
      var actions:CFArray?
      guard AXUIElementCopyActionNames(add,&actions) == .success,
            (actions as? [String])?.contains(kAXPressAction as String)==true else {throw Refusal("no affirmative add action")}
      if !bars.contains(where:{CFEqual($0.add,add)}) {
        bars.append(SecondarySpacesBar(dock:dock,owner:owner,side:side,spaces:spaces,add:add,container:container,addLocation:location,
          primaryContainer:containers.contains{ (attr($0,"AXDisplayID") as? NSNumber)?.uint32Value==CGMainDisplayID() }))
      }
    }
  }
  guard bars.count==1 else {throw Refusal("missing or ambiguous secondary display group")}
  return bars[0]
}

func observe(_ displayUUID: UUID) throws -> [String: Any] {
  let bar = try secondarySpacesBar(displayUUID)
  var report: [String: Any] = [
    "state": bar == nil ? "overviewNotExposed" : "secondaryAddControlObserved",
    "display": displayUUID.uuidString, "systemInputs": 0,
    "sampledAt": ISO8601DateFormatter().string(from: Date()),
  ]
  if let bar {
    report["primaryOverviewContainerPresent"]=bar.primaryContainer
    report["systemControlOwner"]=bar.owner.bundleIdentifier
    switch bar.addLocation {
    case .frame: report["secondaryCommandProof"]="containedFrame"
    case .hit(let p): report["secondaryCommandProof"]="repeatedExactPhysicalHit"; report["confirmedSecondaryPoint"]=[p.x,p.y]
    }
  }
  return report
}

#if !SECONDARY_OVERVIEW_DRIVER && !SECONDARY_FOCUS_OBSERVER
  @main struct ObserverMain {
    static func main() {
      do {
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-command-geometry"]) {
          let side=CGRect(x:-800,y:0,width:800,height:1280)
          let tile=CGRect(x:-120,y:20,width:60,height:44)
          let main=CGRect(x:100,y:20,width:60,height:44)
          let observedAdd=CGRect(x:828.125,y:-32.5,width:56.25,height:90)
          let cases:[(CGRect?,CGRect?,Bool)]=[(nil,nil,false),(.zero,nil,false),(nil,tile,true),
            (tile,tile,true),(main,main,false),(main,tile,false),(tile,.zero,false),
            (observedAdd,observedAdd,false),
            (CGRect(x:-5,y:0,width:10,height:10),nil,false)]
          guard cases.allSatisfy({compatibleFrames($0.0,$0.1,inside:side)==$0.2}) else {exit(2)}
          print("\(cases.count) semantic command geometry cases passed")
          return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-command-hit"]) {
          let compact = CGRect(x:-800, y:0, width:800, height:40)
          let expanded = CGRect(x:-800, y:0, width:800, height:170)
          let candidates = probePoints(in:expanded,add:true), compactPoints = probePoints(in:compact,add:true)
          let edge = CGPoint(x:-7,y:85), deadline = ProcessInfo.processInfo.systemUptime + 5
          var readCount = 0, calls = 0
          let stable = confirmedHit(candidates, until:deadline, matches:{ $0 == edge }, settle:{})
          let changed = confirmedHit([edge], until:deadline, matches:{ _ in readCount += 1; return readCount == 1 },settle:{})
          let expired = confirmedHit([edge], until:0, matches:{ _ in calls += 1; return true },settle:{})
          let tilePoints = probePoints(in:expanded,add:false)
          let a = CGPoint(x:-500,y:85), b = CGPoint(x:-300,y:85)
          let checks = [
            candidates.allSatisfy { expanded.contains($0) }, compactPoints.allSatisfy { compact.contains($0) },
            compactPoints.contains(CGPoint(x:-2,y:20)), stable == .hit(edge), changed == nil,
            expired == nil && calls == 0, confirmedHit(candidates,until:deadline,matches:{_ in false},settle:{}) == nil,
            tilePoints.contains(a) && tilePoints.contains(b), inTileOrder([.hit(a),.hit(b)]),
            !inTileOrder([.hit(b),.hit(a)]), !inTileOrder([.hit(b),.hit(b)]),
            !inTileOrder([.frame(CGRect(x:-500,y:0,width:225,height:80)),.hit(b)])
          ]
          guard checks.allSatisfy({$0}) else { exit(2) }
          print("\(checks.count) secondary physical command hit cases passed")
          return
        }
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
    let ownerID: String
    let ownerBirth: Date
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
        let id=attr(el,kAXIdentifierAttribute) as? String ?? ""
        guard depth > 0 || id=="mc" else { continue }
        var owner:pid_t=0
        guard AXUIElementGetPid(el,&owner) == .success, owner == dock.processIdentifier else { continue }
        let role=attr(el,kAXRoleAttribute) as? String ?? ""
        var entry:[String:Any]=["id":safeIDs.contains(id) ? id : "unrecognized", "role": safeRoles.contains(role) ? role : "other"]
        let screen=(attr(el,"AXDisplayID") as? NSNumber)?.uint32Value
        if let screen {entry["displayID"]=screen}
        else if let unknown=attr(el,"AXDisplayID") { entry["displayIDType"]=CFGetTypeID(unknown) }
        if depth==1, role=="AXGroup", let rect=systemControlFrame(el) {
          entry["exactSecondaryDisplayFrame"]=rect==sideBounds
          entry["exactMainDisplayFrame"]=rect==CGDisplayBounds(CGMainDisplayID())
        }
        let branchOnSide=id=="mc.display" ? screen==side : isSecondary
        if branchOnSide && safeIDs.contains(id) && id != "mc.windows" {
          if let r=systemControlFrame(el), !r.isEmpty, sideBounds.contains(r) {entry["sideBounds"]=[r.minX,r.minY,r.width,r.height]}
          else {entry["sideBoundsConfirmed"]=false}
          if let actions=try? actionsOf(el) {
            entry["actions"]=actions.filter{["AXPress","AXRemoveDesktop","AXCancel","AXShowMenu"].contains($0)}
          }
        }
        if (depth==0 && id=="mc") || (depth==1 && role=="AXGroup" && (branchOnSide || id=="mc.display" || screen==side || systemControlFrame(el)==sideBounds)) ||
             (branchOnSide && depth<4 && ["mc.spaces","mc.spaces.list"].contains(id)) {
          entry["children"]=walk(el,depth:depth+1,isSecondary:branchOnSide)
        }
        rows.append(entry)
      }
      return ["childCount":elements.count, "mcNodes":rows]
    }
    report["state"]="observed"; report["sideDisplayID"]=side
    report["dock"]=walk(root,depth:0,isSecondary:false)
    let wm=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.WindowManager")
    if wm.count==1, let host=wm.first, overviewHost(host.processIdentifier)=="com.apple.WindowManager" {
      let wmRoot=AXUIElementCreateApplication(host.processIdentifier)
      AXUIElementSetMessagingTimeout(wmRoot,0.20)
      func summarize(_ el:AXUIElement,_ depth:Int)->[String:Any] {
        guard let rows=attr(el,kAXChildrenAttribute) as? [AXUIElement],rows.count<=256 else{return ["childrenUnavailable":true]}
        var children:[[String:Any]]=[]
        for node in rows.prefix(24) {
          var pid:pid_t=0
          guard AXUIElementGetPid(node,&pid) == .success,pid==host.processIdentifier else{continue}
          let id=attr(node,kAXIdentifierAttribute) as? String ?? "", role=attr(node,kAXRoleAttribute) as? String ?? ""
          var child:[String:Any]=["id":safeIDs.contains(id) ? id : "unrecognized","role":safeRoles.contains(role) ? role : "other"]
          let sid=(attr(node,"AXDisplayID") as? NSNumber)?.uint32Value
          if let sid {child["displayID"]=sid}
          if safeIDs.contains(id), let r=systemControlFrame(node), !r.isEmpty,sideBounds.contains(r){child["sideBounds"]=[r.minX,r.minY,r.width,r.height]}
          if id=="mc.spaces.add" {
            let f=reportedFrames(node)
            if let r=f.direct {child["directFrame"]=[r.origin.x,r.origin.y,r.width,r.height]}
            if let r=f.split {child["splitFrame"]=[r.origin.x,r.origin.y,r.width,r.height]}
            if let p=activationPoint(node) {child["activationPoint"]=[p.x,p.y]}
            child["enabled"]=attr(node,kAXEnabledAttribute) as? Bool
            child["actions"]=(try? actionsOf(node))?.filter{$0=="AXPress"}
            child["parentConfirmed"]=childOf(node,el)
          }
          if depth<3 && (id=="mc" || (id=="mc.display" && sid==side) || id=="mc.spaces") {
            child["children"]=summarize(node,depth+1)
          }
          children.append(child)
        }
        return ["childCount":rows.count,"nodes":children]
      }
      report["windowManager"]=summarize(wmRoot,0)
      // Only the named system commands: compare both display-specific identities
      // without walking the primary window list, reading labels, or using its point as input.
      func addCommand(_ scope: AXUIElement, _ screen: CGDirectDisplayID) -> AXUIElement? {
        guard let groups = try? children(scope,named:"mc.display"),
              let container = try? only(groups.filter{ (attr($0,"AXDisplayID") as? NSNumber)?.uint32Value == screen }, "display"),
              systemControlFrame(container) == CGDisplayBounds(screen),
              let strip = try? only(children(container,named:"mc.spaces"),"bar"), childOf(strip,container),
              let add = try? only(children(strip,named:"mc.spaces.add"),"add"), childOf(add,strip),
              attr(add,kAXRoleAttribute) as? String == kAXButtonRole else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(add,&pid) == .success && pid == host.processIdentifier else { return nil }
        return add
      }
      let overviewRoots = [wmRoot] + ((try? children(wmRoot,named:"mc")) ?? [])
      for scope in overviewRoots {
        guard let a = addCommand(scope,side), let b = addCommand(scope,CGMainDisplayID()) else { continue }
        var comparison: [String:Any] = ["distinct": !CFEqual(a,b), "primaryDisplay":CGMainDisplayID(),"secondaryDisplay":side]
        for (key, command) in [("secondary",a),("primary",b)] {
          let frames=reportedFrames(command)
          var info: [String:Any] = [:]
          if let f=frames.direct {info["directFrame"]=[f.origin.x,f.origin.y,f.width,f.height]}
          if let f=frames.split {info["splitFrame"]=[f.origin.x,f.origin.y,f.width,f.height]}
          if let p=activationPoint(command) {info["activationPoint"]=[p.x,p.y]}
          comparison[key]=info
        }
        report["systemAddComparison"]=comparison
        break
      }
    }
    // Read through the system Dock only. Sampling a point never moves the cursor or presses
    // a control. Results outside this exact Dock process yield no element metadata.
    if let groups=try? children(root,named:"mc"), groups.count==1 {
      let group=groups[0]
      var alternate:[String:Int]=[:]
      for key in ["AXChildren","AXVisibleChildren","AXContents","AXChildrenInNavigationOrder"] {
        if let rows=attr(group,key) as? [AXUIElement] {alternate[key]=rows.count}
      }
      report["overviewCollections"]=alternate
      var probes:[[String:Any]]=[]
      for p in [CGPoint(x:sideBounds.maxX-22,y:sideBounds.minY+24),
                CGPoint(x:sideBounds.midX,y:sideBounds.minY+28),
                CGPoint(x:sideBounds.maxX-32,y:sideBounds.minY+62)] {
        var hit: AXUIElement?
        let code=AXUIElementCopyElementAtPosition(root,Float(p.x),Float(p.y),&hit)
        var entry:[String:Any]=["axStatus":code.rawValue]
        if code == .success, var el=hit {
          var chain:[[String:Any]]=[]
          for _ in 0..<8 {
            var owner:pid_t=0
            guard AXUIElementGetPid(el,&owner) == .success, owner==dock.processIdentifier else {break}
            let id=attr(el,kAXIdentifierAttribute) as? String ?? ""
            let role=attr(el,kAXRoleAttribute) as? String ?? ""
            var node:[String:Any]=["id":safeIDs.contains(id) ? id : "unrecognized",
                                   "role":safeRoles.contains(role) ? role : "other"]
            if let sid=attr(el,"AXDisplayID") as? NSNumber {node["displayID"]=sid}
            if safeIDs.contains(id), let rect=systemControlFrame(el), !rect.isEmpty, sideBounds.contains(rect) {
              node["sideBounds"]=[rect.minX,rect.minY,rect.width,rect.height]
            }
            chain.append(node)
            if CFEqual(el,group) {entry["matchedOverview"]=true;break}
            if CFEqual(el,root) {break}
            guard let parent=attr(el,kAXParentAttribute), CFGetTypeID(parent)==AXUIElementGetTypeID() else {break}
            el=parent as! AXUIElement
          }
          entry["ancestors"]=chain
        }
        probes.append(entry)
      }
      report["secondaryDockHitTests"]=probes
      let systemRoot=AXUIElementCreateSystemWide()
      AXUIElementSetMessagingTimeout(systemRoot,0.20)
      var publicHits:[[String:Any]]=[]
      for offset in [(22,40),(32,65),(25,92),(40,112),(100,60),(64,18),(25,18),(240,52),(400,44),(775,40)] {
        let x=sideBounds.maxX-CGFloat(offset.0), y=sideBounds.minY+CGFloat(offset.1)
        guard sideBounds.contains(CGPoint(x:x,y:y)) else {continue}
        var hit:AXUIElement?
        let status=AXUIElementCopyElementAtPosition(systemRoot,Float(x),Float(y),&hit)
        var entry:[String:Any]=["point":[x,y],"status":status.rawValue]
        if status == .success, var el=hit {
          var owner:pid_t=0
          if AXUIElementGetPid(el,&owner) == .success, let host=overviewHost(owner) {
            entry["host"]=host
            var chain:[[String:Any]]=[]
            for _ in 0..<9 {
              var current:pid_t=0
              guard AXUIElementGetPid(el,&current) == .success, current==owner else {break}
              let id=attr(el,kAXIdentifierAttribute) as? String ?? "", role=attr(el,kAXRoleAttribute) as? String ?? ""
              var row:[String:Any]=["id":safeIDs.contains(id) ? id : "unrecognized",
                                    "role":safeRoles.contains(role) || role=="AXApplication" ? role : "other"]
              if let sid=attr(el,"AXDisplayID") as? NSNumber {row["displayID"]=sid}
              if safeIDs.contains(id), let rect=systemControlFrame(el), !rect.isEmpty, sideBounds.contains(rect) {
                row["sideBounds"]=[rect.minX,rect.minY,rect.width,rect.height]
              }
              if let actions=try? actionsOf(el) {
                row["actions"]=actions.filter{["AXPress","AXRemoveDesktop","AXCancel"].contains($0)}
              }
              chain.append(row)
              if role=="AXApplication" {break}
              guard let parent=attr(el,kAXParentAttribute), CFGetTypeID(parent)==AXUIElementGetTypeID() else {break}
              el=parent as! AXUIElement
            }
            entry["ancestors"]=chain
          } else {entry["host"]="outsideSystemAllowlist"}
        }
        publicHits.append(entry)
      }
      report["secondarySystemHitTests"]=publicHits

    }
    report["limited"]=remaining==0
    return report
  }

  private struct ProvisionControls {
    let bar: SecondarySpacesBar
    let list: AXUIElement
    let tiles: [AXUIElement]
    let locations: [ControlLocation]
    let labels: [String]
    init(display: UUID, count: Int) throws {
      guard let observed = try secondarySpacesBar(display), !observed.dock.isTerminated, !observed.owner.isTerminated
      else { throw Refusal("secondary add button frame or Dock identity unavailable") }
      let list = try only(
        children(observed.spaces, named: "mc.spaces.list"), "secondary desktop list")
      guard let items = attr(list, kAXChildrenAttribute) as? [AXUIElement], items.count == count
      else {
        throw Refusal("secondary system desktop buttons differ from ordinary inventory")
      }
      let secondary = CGDisplayBounds(observed.side)
      guard childOf(list,observed.spaces), let listFrame=systemControlFrame(list),
            !listFrame.isEmpty, secondary.contains(listFrame) else {throw Refusal("unverified secondary desktop list")}
      let placements = try items.map { tile -> ControlLocation in
        var pid:pid_t=0
        guard childOf(tile,list), AXUIElementGetPid(tile,&pid) == .success,
              pid==observed.owner.processIdentifier,
              attr(tile,kAXRoleAttribute) as? String == kAXButtonRole,
              attr(tile, kAXEnabledAttribute) as? Bool == true,
              (try actionsOf(tile)).contains(kAXPressAction as String),
              let placement=locate(tile,owner:pid,in:listFrame,add:false)
        else { throw Refusal("secondary desktop tile ownership, geometry or capability changed") }
        return placement
      }
      guard inTileOrder(placements) else {
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
      self.list = list
      tiles = items
      locations = placements
      labels = values
    }

    // Repeat the affirmative evidence on the same live objects after the durable
    // one-shot intent, just before dispatch. Never reselect a tile or use a fallback point.
    func recheckBeforeInput() throws {
      let owner = bar.owner.processIdentifier
      guard !bar.owner.isTerminated, !bar.dock.isTerminated,
            overviewHost(owner) == bar.owner.bundleIdentifier,
            (attr(bar.container,"AXDisplayID") as? NSNumber)?.uint32Value == bar.side,
            systemControlFrame(bar.container) == CGDisplayBounds(bar.side),
            let strip = systemControlFrame(bar.spaces), !strip.isEmpty, CGDisplayBounds(bar.side).contains(strip),
            childOf(bar.spaces,bar.container), childOf(bar.add,bar.spaces), childOf(list,bar.spaces),
            let listFrame = systemControlFrame(list), !listFrame.isEmpty, strip.contains(listFrame),
            let current = attr(list,kAXChildrenAttribute) as? [AXUIElement], current.count == tiles.count,
            attr(bar.add,kAXEnabledAttribute) as? Bool == true,
            bar.addLocation.recheck(bar.add, owner:owner, in:strip),
            tiles.indices.allSatisfy({ i in
              CFEqual(current[i], tiles[i]) && childOf(tiles[i],list) &&
                attr(tiles[i],kAXEnabledAttribute) as? Bool == true &&
                locations[i].recheck(tiles[i],owner:owner,in:listFrame)
            }) else { throw Refusal("secondary command or desktop tiles lost their physical proof") }
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
      guard let birth = initialUI.bar.dock.launchDate, let ownerBirth = initialUI.bar.owner.launchDate, let ownerID = initialUI.bar.owner.bundleIdentifier else {
        throw Refusal("missing Dock generation")
      }
      try requireSafeOccupancy(nil)
      let intent = ProvisionIntent(
        operation: UUID(), display: display, source: source, initial: original,
        sourceTileLabel: initialUI.labels[0], boot: boot,
        issuedUptime: ProcessInfo.processInfo.systemUptime, dockBirth: birth, ownerID:ownerID, ownerBirth:ownerBirth)
      let ui = try ProvisionControls(display: display, count: 1)
      guard CFEqual(initialUI.bar.add, ui.bar.add), initialUI.labels == ui.labels,
        (try state()) == original
      else { throw Refusal("secondary add control changed") }
      try folder.put(intent, "create-intent.json")
      try ui.recheckBeforeInput()
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
    guard first.bar.dock.launchDate == intent.dockBirth, first.bar.owner.launchDate==intent.ownerBirth,
          first.bar.owner.bundleIdentifier==intent.ownerID else {
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
    guard ui.bar.dock.launchDate == intent.dockBirth, ui.bar.owner.launchDate==intent.ownerBirth,
          ui.bar.owner.bundleIdentifier==intent.ownerID, ui.labels == first.labels,
      CFEqual(first.tiles[b], ui.tiles[b]), (try state()) == original,
      AXUIElementCopyActionNames(ui.tiles[b], &actions) == .success,
      (actions as? [String])?.contains(remove) == true
    else { throw Refusal("exact inactive B tile or Remove Desktop action unavailable") }
    try folder.put(created, "remove-intent.json")
    try ui.recheckBeforeInput()
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
