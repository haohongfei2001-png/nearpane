// Standalone observer is read-only. Action methods compile only in the device-lab overview driver.
import AppKit
import ApplicationServices
import Security

// Background macOS agents can omit NSRunningApplication.launchDate. Take the
// kernel start time for the signed live PID in that case; ambiguity refuses input.
extension NSRunningApplication {
  var verifiedSystemBirth: Date? {
    guard !isTerminated else { return nil }
    return launchDate ?? kernelBirth
  }

  var kernelBirth: Date? {
    guard !isTerminated else { return nil }
    return Self.kernelBirth(pid: processIdentifier)
  }

  static func kernelBirth(pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
          info.pbi_start_tvusec < 1_000_000 else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
  }
}

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

// Lock the live Apple process generation once for this operation. A launch-services proxy is unnecessary for AX.
enum OverviewAgent: String, CaseIterable {
  case dock="com.apple.dock", manager="com.apple.WindowManager", launcher="com.apple.exposelauncher"
  var executable:String {
    switch self {
    case .dock:return "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    case .manager:return "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
    case .launcher:return "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
    }
  }
}
struct OverviewProcess:Equatable {
  let agent:OverviewAgent,pid:pid_t,birth:UInt64
  var identifier:String {agent.rawValue}
  private static var enrolled=[OverviewAgent:Self]()
  private static func path(_ pid:pid_t)->String? {
    var bytes=[CChar](repeating:0,count:4096)
    return proc_pidpath(pid,&bytes,UInt32(bytes.count))>0 ? String(cString:bytes):nil
  }
  static func kernelBirth(_ pid:pid_t)->UInt64? {
    var info=proc_bsdinfo()
    let size=Int32(MemoryLayout.size(ofValue:info))
    guard pid>1,proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size,info.pbi_pid==UInt32(pid),
          info.pbi_uid==getuid(),info.pbi_start_tvsec>0,info.pbi_start_tvusec<1_000_000 else {return nil}
    return info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec
  }
  static func current(_ agent:OverviewAgent) throws -> Self? {
    if let held=enrolled[agent] {try held.verify();return held}
    let bytes=proc_listpids(UInt32(PROC_UID_ONLY),getuid(),nil,0)
    guard bytes>0,bytes<1_000_000 else {throw Refusal("kernel process inventory unavailable for "+agent.rawValue)}
    var ids=[pid_t](repeating:0,count:Int(bytes)/MemoryLayout<pid_t>.size+64)
    let capacity=Int32(ids.count*MemoryLayout<pid_t>.size)
    let used=proc_listpids(UInt32(PROC_UID_ONLY),getuid(),&ids,capacity)
    guard used>0,used<capacity,Int(used)%MemoryLayout<pid_t>.size==0 else {throw Refusal("kernel process inventory changed for "+agent.rawValue)}
    let matches=ids.prefix(Int(used)/MemoryLayout<pid_t>.size).filter{$0>1 && path($0)==agent.executable}
    guard matches.count<=1 else {throw Refusal("ambiguous current user's "+agent.rawValue)}
    guard let pid=matches.first else {return nil}
    guard let birth=kernelBirth(pid) else {throw Refusal("kernel process generation unavailable for "+agent.rawValue)}
    let identity=Self(agent:agent,pid:pid,birth:birth)
    try identity.verify();enrolled[agent]=identity;return identity
  }
  func verify() throws {
    guard let session=CGSessionCopyCurrentDictionary() as? [String:Any],session[kCGSessionOnConsoleKey as String] as? Bool==true,
          session[kCGSessionUserIDKey as String] as? NSNumber==NSNumber(value:getuid()),
          session["CGSSessionScreenIsLocked"] as? Bool != true else {throw Refusal("unlocked current-user console unavailable")}
    guard Self.path(pid)==agent.executable,Self.kernelBirth(pid)==birth else {throw Refusal("enrolled kernel path or generation changed for "+identifier)}
    var code:SecCode?,req:SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess,let code,
          SecRequirementCreateWithString(("anchor apple and identifier \""+identifier+"\"") as CFString,[],&req)==errSecSuccess,let req,
          SecCodeCheckValidity(code,[],req)==errSecSuccess,Self.kernelBirth(pid)==birth,Self.path(pid)==agent.executable else {
      throw Refusal("running Apple signature or kernel generation changed for "+identifier)
    }
  }
  func owns(_ element:AXUIElement)->Bool {
    var owner:pid_t=0
    return AXUIElementGetPid(element,&owner) == .success && owner==pid
  }
  var verifiedBirthDate:Date? {
    guard (try? verify()) != nil else {return nil}
    return Date(timeIntervalSince1970:Double(birth/1_000_000)+Double(birth%1_000_000)/1_000_000)
  }
  #if SECONDARY_OVERVIEW_DRIVER
  // Only older, short-lived standalone recovery receipts could contain a Launch Services date.
  // Discovery, new receipts and the installed acceptance path always use the authenticated kernel generation.
  func matchesRecordedBirth(_ saved:Date)->Bool {
    guard let kernelDate=verifiedBirthDate else {return false}
    if kernelDate==saved {return true}
    guard let legacy=NSRunningApplication(processIdentifier:pid),!legacy.isTerminated,legacy.kernelBirth==kernelDate,
          legacy.launchDate==saved else {return false}
    return (try? verify()) != nil
  }
  #endif
  static func owners(dock:Self) throws -> [Self] {
    try dock.verify()
    guard dock.agent == .dock else {throw Refusal("AX root was not the enrolled Dock")}
    return [dock]+(try current(.manager).map{[$0]} ?? [])
  }
  static func name(of pid:pid_t)->String? {
    guard let actual=path(pid),let agent=OverviewAgent.allCases.first(where:{$0.executable==actual}),
          let identity=try? current(agent),identity.pid==pid else {return nil}
    return identity.identifier
  }
}
enum SystemDock {
  static let executable=OverviewAgent.dock.executable
  static func identity() throws -> OverviewProcess {
    guard let dock=try OverviewProcess.current(.dock) else {throw Refusal("signed-in user's kernel Dock unavailable")}
    return dock
  }
}
func overviewHost(_ pid:pid_t)->String? {OverviewProcess.name(of:pid)}

func only(_ elements: [AXUIElement], _ label: String) throws -> AXUIElement {
  guard elements.count == 1 else { throw Refusal("missing or ambiguous " + label) }
  return elements[0]
}

struct SecondarySpacesBar {
  let dock: OverviewProcess
  let owner: OverviewProcess
  let side: CGDirectDisplayID
  let spaces: AXUIElement
  let add: AXUIElement
  let container: AXUIElement
  fileprivate let addProof: AddProof
  let primaryContainer: Bool
  func verify(_ element:AXUIElement?=nil) throws {
    try dock.verify()
    if dock != owner {try owner.verify()}
    let controls=[container,spaces,add]+(element.map{[$0]} ?? [])
    guard controls.allSatisfy(owner.owns) else {throw Refusal("enrolled system AX control changed owner")}
  }
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

// A semantic press addresses the retained accessibility object. The physical point
// here witnesses the owning strip only and is never a click coordinate.
fileprivate struct PrimaryControls {
  let container, strip, add: AXUIElement
  func matches(_ other: PrimaryControls) -> Bool {
    CFEqual(container,other.container) && CFEqual(strip,other.strip) && CFEqual(add,other.add)
  }
}

private func pairedDisplays(_ ids: [CGDirectDisplayID?], main: CGDirectDisplayID, side: CGDirectDisplayID) -> Bool {
  main != side && ids.count == 2 && ids.contains(main) && ids.contains(side)
}

private func primaryControls(_ containers: [AXUIElement], scope: AXUIElement, side: CGDirectDisplayID,
                             sideContainer: AXUIElement, sideStrip: AXUIElement, sideAdd: AXUIElement,
                             owner: pid_t) throws -> PrimaryControls {
  let main = CGMainDisplayID()
  let ids = containers.map { (attr($0,"AXDisplayID") as? NSNumber)?.uint32Value }
  guard pairedDisplays(ids,main:main,side:side), let i = ids.firstIndex(of: main),
        childOf(sideContainer,scope) else { throw Refusal("expected distinct primary and secondary display groups") }
  let container = containers[i]
  let strip = try only(children(container,named:"mc.spaces"),"primary desktop strip")
  let add = try only(children(strip,named:"mc.spaces.add"),"primary Add sibling")
  guard [container,strip,add].allSatisfy({ node in
    var pid: pid_t=0
    return AXUIElementGetPid(node,&pid) == .success && pid == owner
  }), childOf(container,scope), childOf(strip,container), childOf(add,strip),
      !CFEqual(container,sideContainer), !CFEqual(strip,sideStrip), !CFEqual(add,sideAdd),
      systemControlFrame(container) == CGDisplayBounds(main),
      let frame = systemControlFrame(strip), !frame.isEmpty, CGDisplayBounds(main).contains(frame),
      attr(add,kAXRoleAttribute) as? String == kAXButtonRole
  else { throw Refusal("primary Add sibling ownership or display geometry is ambiguous") }
  return PrimaryControls(container:container,strip:strip,add:add)
}

fileprivate enum AddProof {
  case located(ControlLocation)
  case semantic(stripPoint: CGPoint, ownerBirth: Date, primary: PrimaryControls?)

  var method: String {
    switch self {
    case .located(.frame): return "containedFrame"
    case .located(.hit): return "repeatedExactPhysicalHit"
    case .semantic(_,_,nil): return "soleDisplaySemanticAXPress"
    case .semantic: return "distinctDisplaySemanticAXPress"
    }
  }
}

private func optionalAttribute(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
  switch status {
  case .success:
    guard let value else { throw Refusal("missing reported system control attribute") }
    return value
  case .attributeUnsupported: return nil
  default: throw Refusal("cannot read \(key) on the system control (AX \(status.rawValue))")
  }
}

private func semanticVisible(hidden: Bool?, visibleMatches: Int?) -> Bool {
  hidden != true && (visibleMatches == nil || visibleMatches == 1)
}

private func requireVisibleWhenExposed(_ add: AXUIElement, in spaces: AXUIElement) throws {
  let h = try optionalAttribute(add,"AXHidden"), v = try optionalAttribute(spaces,kAXVisibleChildrenAttribute)
  var count: Int?
  if let v {
    guard let list = v as? [AXUIElement], list.count <= 256 else {
      throw Refusal("desktop strip visible children have an unsupported representation")
    }
    count = list.filter { CFEqual($0,add) }.count
  }
  if let h, CFGetTypeID(h) != CFBooleanGetTypeID() {
    throw Refusal("Add hidden state is not a boolean")
  }
  let hidden = h as? Bool
  guard semanticVisible(hidden:hidden,visibleMatches:count) else {
    if hidden == true { throw Refusal("system reports Add is hidden") }
    throw Refusal("desktop strip lists \(count ?? 0) visible matches for the retained Add")
  }
}

private func hitsSpacesStrip(_ point: CGPoint, spaces: AXUIElement, container: AXUIElement, owner: pid_t) -> Bool {
  var hit: AXUIElement?
  let system = AXUIElementCreateSystemWide()
  AXUIElementSetMessagingTimeout(system,0.20)
  guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success,
        var node = hit else { return false }
  for _ in 0..<8 {
    var pid: pid_t = 0
    guard AXUIElementGetPid(node,&pid) == .success, pid == owner else { return false }
    if CFEqual(node,spaces) { return childOf(spaces,container) }
    guard let parent = attr(node,kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
    node = parent as! AXUIElement
  }
  return false
}

private func semanticStripPoint(in area: CGRect, hit: (CGPoint) -> Bool) -> CGPoint? {
  guard area.width >= 4, area.height >= 4 else { return nil }
  for fx: CGFloat in [0.5,0.25,0.75] {
    let point = CGPoint(x:area.minX + area.width * fx, y:area.midY)
    if hit(point) && hit(point) { return point }
  }
  return nil
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

// The child order does not partition the entire strip into equally wide buttons.
// WindowManager can move A towards the centre and expose the button below the AX list.
// Probe only within the observed display, never issue pointer input at a probe point.
private func pairedSourceProbes(list: CGRect, display: CGRect, location: ControlLocation,
                        reportedFrame: CGRect?, activation: CGPoint?) -> [CGPoint] {
  guard display.contains(list), !list.isEmpty else { return [] }
  let strip = CGRect(x:list.minX, y:list.minY, width:list.width, height:list.height + 8).intersection(display)
  var result = [CGPoint]()
  func add(_ point: CGPoint) {
    if strip.contains(point), !result.contains(point) { result.append(point) }
  }
  if let activation { add(activation) }
  var positions = [CGFloat]()
  switch location {
  case .hit(let point): add(point); positions.append(point.x)
  case .frame(let rect): positions.append(rect.midX)
  }
  if let rect = reportedFrame, display.contains(rect) {
    add(CGPoint(x: rect.midX, y: rect.midY))
    positions += [rect.midX, rect.minX + rect.width * 0.25, rect.minX + rect.width * 0.75]
  }
  // Centre and the real child bounds precede the limited strip search. A sibling hit can never match.
  for step in [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7] {
    positions.append(list.midX + CGFloat(step) * list.width / 16)
  }
  for y in [list.maxY + 4, list.midY] {
    for x in positions { add(CGPoint(x:x, y:y)) }
  }
  return result
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

// Constrain both hovers to the observed system strip, including its collapsed height.
func overviewHoverPoint(in strip: CGRect, edge: Bool) -> CGPoint? {
  guard !strip.isNull, strip.width >= 20, strip.height >= 4,
        strip.minX.isFinite, strip.minY.isFinite, strip.width.isFinite, strip.height.isFinite else { return nil }
  let x = edge ? strip.maxX - 10 : strip.midX
  let y = min(strip.minY + (edge ? 74 : 12), strip.maxY - 2)
  return CGPoint(x:x, y:y)
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

private func provisionDisplay(_ uuid: UUID, currentDisplay: Bool) -> CGDirectDisplayID? {
  let ids = NSScreen.screens.compactMap {
    ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
  let main = CGMainDisplayID()
  guard ids.count == NSScreen.screens.count, Set(ids).count == ids.count,
        ids.contains(main), ids.allSatisfy({ CGDisplayIsInMirrorSet($0) == 0 }) else { return nil }
  let target: CGDirectDisplayID
  if currentDisplay {
    guard ids == [main] else { return nil }
    target = main
  } else {
    guard ids.count == 2, let side = ids.first(where: { $0 != main }),
          !CGDisplayBounds(side).intersects(CGDisplayBounds(main)) else { return nil }
    target = side
  }
  guard let raw = CGDisplayCreateUUIDFromDisplayID(target)?.takeRetainedValue(),
        UUID(uuidString: CFUUIDCreateString(nil, raw) as String) == uuid else { return nil }
  return target
}

// Cross-check the complete inventory, including fullscreen records. Only ordinary
// Spaces can be the source or the single appended target of provisioning.
private func provisionRecords(_ description: String, source: String, live: [[String: Any]]) throws
  -> (order: [String], identities: [String: UUID], fullscreen: Set<String>?) {
  let entries = description.components(separatedBy: ",")
  guard entries.count == live.count, !live.isEmpty else { throw Refusal("incomplete desktop inventory") }
  var order = [String](), identities = [String: UUID](), fullscreen = Set<String>()
  for (entry, record) in zip(entries, live) {
    let fields = entry.components(separatedBy: "/")
    guard fields.count == 2, let id = UInt64(fields[0]), id > 0, String(id) == fields[0],
          let kind = record["type"] as? Int, (kind == 0 || kind == 4), String(kind) == fields[1],
          (record["id64"] as? NSNumber)?.stringValue == fields[0], identities[fields[0]] == nil,
          let raw = record["uuid"] as? String, let uid = UUID(uuidString: raw), !identities.values.contains(uid)
    else { throw Refusal("desktop type, number, order or UUID is ambiguous") }
    order.append(fields[0])
    identities[fields[0]] = uid
    if kind == 4 { fullscreen.insert(fields[0]) }
  }
  guard identities[source] != nil, !fullscreen.contains(source) else { throw Refusal("source is not ordinary") }
  return (order, identities, fullscreen.isEmpty ? nil : fullscreen)
}

private func newlyAddedDesktop(before: [String], after: [String], source: String, currentDisplay: Bool) throws -> String {
  guard before.last == source, Set(before).count == before.count, Set(after).count == after.count,
        after.count == before.count + 1 else { throw Refusal("original desktop order or size changed") }
  if currentDisplay {
    guard after.dropLast().elementsEqual(before), let target = after.last, !before.contains(target)
    else { throw Refusal("expected exactly one new ordinary desktop appended after the source") }
    return target
  }
  guard before == [source], after.contains(source), let target = after.first(where: { $0 != source })
  else { throw Refusal("change is not one adjacent ordinary secondary desktop") }
  return target
}

func secondarySpacesBar(_ displayUUID: UUID, currentDisplay: Bool = false, enrolledDock:OverviewProcess? = nil) throws -> SecondarySpacesBar? {
  guard AXIsProcessTrusted(), let state = CGSessionCopyCurrentDictionary() as? [String: Any],
    state["kCGSSessionOnConsoleKey"] as? Bool == true,
    state["CGSSessionScreenIsLocked"] as? Bool != true
  else { throw Refusal("unlocked console and existing AX permission required") }
  guard let side = provisionDisplay(displayUUID, currentDisplay: currentDisplay) else {
    throw Refusal("authorized display identity or topology changed")
  }
  let dock=try enrolledDock ?? SystemDock.identity()
  let owners=try OverviewProcess.owners(dock:dock)
  let root=AXUIElementCreateApplication(dock.pid)
  AXUIElementSetMessagingTimeout(root,1)
  guard dock.owns(root) else {throw Refusal("Dock AX application owner changed")}
  let groups=try children(root,named:"mc")
  guard !groups.isEmpty else {return nil}
  let group=try only(groups,"overview")
  guard dock.owns(group) else {throw Refusal("Dock AX overview owner changed")}
  var roots:[(OverviewProcess,AXUIElement)]=[(dock,group)]
  for host in owners where host.agent == .manager {
    let hostRoot=AXUIElementCreateApplication(host.pid)
    AXUIElementSetMessagingTimeout(hostRoot,0.3)
    guard host.owns(hostRoot) else {throw Refusal("WindowManager AX application owner changed")}
    roots.append((host,hostRoot))
    let mc=try children(hostRoot,named:"mc")
    if mc.count==1,host.owns(mc[0]) {roots.append((host,mc[0]))}
  }
  var bars:[SecondarySpacesBar]=[]
  var displayContainers: [AXUIElement] = []
  for (owner,scope) in roots {
    let containers=try children(scope,named:"mc.display")
    for c in containers where !displayContainers.contains(where:{ CFEqual($0,c) }) { displayContainers.append(c) }
    guard displayContainers.count <= (currentDisplay ? 1 : 2) else { throw Refusal("conflicting overview display containers") }
    for container in containers where owner.owns(container) && (attr(container,"AXDisplayID") as? NSNumber)?.uint32Value==side {
      let spaces=try only(children(container,named:"mc.spaces"),"secondary spaces bar")
      let add=try only(children(spaces,named:"mc.spaces.add"),"secondary add button")
      guard owner.owns(spaces),owner.owns(add) else {throw Refusal("Space strip or Add AX owner changed")}
      let nodes=[container,spaces,add]
      guard nodes.allSatisfy({element in
        var pid:pid_t=0
        return AXUIElementGetPid(element,&pid) == .success && pid==owner.pid
      }), let strip=systemControlFrame(spaces), !strip.isEmpty, CGDisplayBounds(side).contains(strip),
          systemControlFrame(container)==CGDisplayBounds(side),
          childOf(add,spaces), childOf(spaces,container),
          attr(add,kAXRoleAttribute) as? String == kAXButtonRole,
          attr(add,kAXEnabledAttribute) as? Bool == true
        else {throw Refusal("secondary control geometry, physical hit or owner unconfirmed")}
      var actions:CFArray?
      guard AXUIElementCopyActionNames(add,&actions) == .success,
            (actions as? [String])?.contains(kAXPressAction as String)==true else {throw Refusal("no affirmative add action")}
      let proof: AddProof
      if let location = locate(add,owner:owner.pid,in:strip,add:true) {
        proof = .located(location)
      } else {
        let frames = reportedFrames(add)
        let primary: PrimaryControls?
        if currentDisplay {
          guard displayContainers.count == 1 else { throw Refusal("Add is not bound to a unique display") }
          primary = nil
        } else {
          primary = try primaryControls(containers,scope:scope,side:side,sideContainer:container,
                                        sideStrip:spaces,sideAdd:add,owner:owner.pid)
        }
        guard let birth = owner.verifiedBirthDate else { throw Refusal("Add owner has no process start time") }
        if let direct = frames.direct, let split = frames.split, direct != split {
          throw Refusal("system Add frame readings disagree")
        }
        try requireVisibleWhenExposed(add,in:spaces)
        guard let point = semanticStripPoint(in:strip,hit:{hitsSpacesStrip($0,spaces:spaces,container:container,owner:owner.pid)})
        else { throw Refusal("same system desktop strip was not hit twice") }
        proof = .semantic(stripPoint:point,ownerBirth:birth,primary:primary)
      }
      if !bars.contains(where:{CFEqual($0.add,add)}) {
        bars.append(SecondarySpacesBar(dock:dock,owner:owner,side:side,spaces:spaces,add:add,container:container,addProof:proof,
          primaryContainer:containers.contains{ (attr($0,"AXDisplayID") as? NSNumber)?.uint32Value==CGMainDisplayID() }))
      }
    }
  }
  guard bars.count==1 else {throw Refusal("missing or ambiguous secondary display group")}
  let bar=bars[0];try bar.verify()
  return bar
}

func observe(_ displayUUID: UUID, currentDisplay: Bool = false) throws -> [String: Any] {
  let bar = try secondarySpacesBar(displayUUID, currentDisplay: currentDisplay)
  var report: [String: Any] = [
    "state": bar == nil ? "overviewNotExposed" : "secondaryAddControlObserved",
    "display": displayUUID.uuidString, "systemInputs": 0,
    "sampledAt": ISO8601DateFormatter().string(from: Date()),
  ]
  if let bar {
    report["primaryOverviewContainerPresent"]=bar.primaryContainer
    report["systemControlOwner"]=bar.owner.identifier
    report["secondaryCommandProof"]=bar.addProof.method
    switch bar.addProof {
    case .located(.frame): break
    case .located(.hit(let p)): report["confirmedSecondaryPoint"]=[p.x,p.y]
    case .semantic(let p,_,_): report["confirmedStripPoint"]=[p.x,p.y]
    }
  }
  return report
}

#if !SECONDARY_OVERVIEW_DRIVER && !SECONDARY_FOCUS_OBSERVER
  @main struct ObserverMain {
    static func main() {
      do {
        if CommandLine.arguments.dropFirst().elementsEqual(["--check-system-owners"]) {
          for kind in [OverviewAgent.manager,.dock] {
            guard let held=try OverviewProcess.current(kind),try OverviewProcess.current(kind)==held,held.verifiedBirthDate != nil else {
              throw Refusal("system process generation unavailable: "+kind.rawValue)
            }
            print(kind.rawValue+" process identity and start time confirmed")
          }
          return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-overview-owner-generation"]) {
          let dock=try SystemDock.identity()
          let cases=[OverviewProcess(agent:.dock,pid:dock.pid,birth:dock.birth &+ 1),
                     OverviewProcess(agent:.manager,pid:dock.pid,birth:dock.birth),
                     OverviewProcess(agent:.dock,pid:getpid(),birth:OverviewProcess.kernelBirth(getpid()) ?? 0)]
          guard cases.allSatisfy({(try? $0.verify())==nil}),try SystemDock.identity()==dock else {throw Refusal("stale or substituted system identity admitted")}
          print("kernel Dock retained; wrong PID, birth and Apple executable rejected; zero system inputs");return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-provision-record-types"]) {
          let ids = [UUID(), UUID(), UUID()]
          func records(_ kinds: [Int]) -> [[String:Any]] {
            kinds.enumerated().map { ["id64": $0.offset + 1, "type": $0.element, "uuid": ids[$0.offset].uuidString] }
          }
          let mixed = records([4, 0, 0]), ordinary = records([0, 0, 0])
          var duplicate = mixed
          duplicate[2]["uuid"] = ids[1].uuidString
          let valid = try provisionRecords("1/4,2/0,3/0", source:"3", live:mixed)
          let cases = [
            valid.order == ["1","2","3"], valid.fullscreen == ["1"], valid.identities["1"] == ids[0],
            (try provisionRecords("1/0,2/0,3/0", source:"3", live:ordinary)).fullscreen == nil,
            (try? provisionRecords("1/4,2/0,3/0", source:"1", live:mixed)) == nil,
            (try? provisionRecords("1/0,2/0,3/0", source:"3", live:mixed)) == nil,
            (try? provisionRecords("1/4,2/0,3/0", source:"3", live:duplicate)) == nil,
            (try? provisionRecords("1/4,2/0,3/1", source:"2", live:records([4,0,1]))) == nil
          ]
          guard cases.allSatisfy({$0}) else { exit(2) }
          print("8 ordinary/fullscreen inventory identity and refusal cases passed")
          return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-append-order"]) {
          let cases: [([String], [String], Bool, String?)] = [
            (["a"], ["b","a"], false, "b"), (["p","a"], ["p","a","b"], false, nil),
            (["a"], ["a","b"], true, "b"), (["p","a"], ["p","a","b"], true, "b"),
            (["p","a"], ["p","b","a"], true, nil), (["p","a"], ["q","a","b"], true, nil),
            (["p","q","a"], ["q","p","a","b"], true, nil), (["a","p"], ["a","p","b"], true, nil),
            (["p","a"], ["p","a","p"], true, nil), (["p","a"], ["p","a"], true, nil)
          ]
          guard cases.allSatisfy({ (try? newlyAddedDesktop(before: $0.0, after: $0.1, source: "a", currentDisplay: $0.2)) == $0.3 })
          else { exit(2) }
          print("\(cases.count) existing inventory and append-only creation cases passed")
          return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--test-semantic-add"]) {
          let strip = CGRect(x:0,y:0,width:1470,height:72)
          let center = CGPoint(x:735,y:36)
          var hits = 0
          let cases = [
            pairedDisplays([2,3],main:2,side:3), pairedDisplays([3,2],main:2,side:3),
            !pairedDisplays([2,2],main:2,side:3), !pairedDisplays([2,nil],main:2,side:3),
            !pairedDisplays([2,3,3],main:2,side:3), !pairedDisplays([3,3],main:3,side:3),
            semanticVisible(hidden:nil,visibleMatches:nil), semanticVisible(hidden:false,visibleMatches:1),
            !semanticVisible(hidden:true,visibleMatches:nil), !semanticVisible(hidden:false,visibleMatches:0),
            !semanticVisible(hidden:nil,visibleMatches:2),
            semanticStripPoint(in:strip,hit:{ $0 == center }) == center,
            semanticStripPoint(in:strip,hit:{ _ in false }) == nil,
            semanticStripPoint(in:strip,hit:{ p in hits += 1; return hits == 1 && p == center }) == nil,
            semanticStripPoint(in:.zero,hit:{ _ in true }) == nil
          ]
          guard cases.allSatisfy({$0}) else { exit(2) }
          print("\(cases.count) Add visibility, paired display ownership and strip witness cases passed")
          return
        }
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
          let observedSide = CGRect(x:-800,y:0,width:800,height:1280)
          let aFrame = CGRect(x:-499,y:2,width:62,height:34), aHit = CGPoint(x:-468,y:44)
          let bHit = CGPoint(x:-400,y:44)
          let paired = pairedSourceProbes(list:compact,display:observedSide,location:.frame(aFrame),
                                          reportedFrame:aFrame,activation:CGPoint(x:60,y:40))
          let exactA = confirmedHit(paired, until:deadline, matches: { $0 == aHit }, settle:{})
          let currentStrip = CGRect(x:0,y:0,width:1470,height:72)
          let checks = [
            overviewHoverPoint(in:currentStrip, edge:true) == CGPoint(x:1460,y:70),
            overviewHoverPoint(in:compact, edge:true) == CGPoint(x:-10,y:38),
            overviewHoverPoint(in:expanded, edge:true) == CGPoint(x:-10,y:74),
            overviewHoverPoint(in:.zero, edge:true) == nil,
            candidates.allSatisfy { expanded.contains($0) }, compactPoints.allSatisfy { compact.contains($0) },
            compactPoints.contains(CGPoint(x:-2,y:20)), stable == .hit(edge), changed == nil,
            expired == nil && calls == 0, confirmedHit(candidates,until:deadline,matches:{_ in false},settle:{}) == nil,
            tilePoints.contains(a) && tilePoints.contains(b), inTileOrder([.hit(a),.hit(b)]),
            !inTileOrder([.hit(b),.hit(a)]), !inTileOrder([.hit(b),.hit(b)]),
            !inTileOrder([.frame(CGRect(x:-500,y:0,width:225,height:80)),.hit(b)]),
            paired.contains(bHit) && exactA == .hit(aHit),
            paired.allSatisfy(observedSide.contains),
            confirmedHit(paired, until:deadline, matches:{ _ in false }, settle:{}) == nil,
            pairedSourceProbes(list:compact,display:currentStrip,location:.hit(bHit),reportedFrame:nil,activation:nil).isEmpty
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

  // Preserve every original desktop, every peer scope and the complete display geometry.
  // A sole-display session may append one desktop at the rightmost ordinary source.
  private struct ProvisionState: Codable, Equatable {
    let primaryScope: String?
    let geometry: [String]
    let sideOrder: [String]
    let spaceUUIDs: [String: UUID]
    let fullscreenIDs: Set<String>?  // nil also decodes earlier all-ordinary creation journals
    init(_ display: UUID, source: String, currentDisplay: Bool) throws {
      let uuid = display.uuidString
      let scopes = try scoped(uuid, source, currentDisplay: currentDisplay)
      let sides = scopes.filter { $0.hasPrefix(uuid + ":") }
      let main = scopes.filter { !$0.hasPrefix(uuid + ":") }
      guard sides.count == 1, main.count == (currentDisplay ? 0 : 1) else { throw Refusal("ambiguous provision scopes") }
      let fields = sides[0].components(separatedBy: ":")
      guard fields.count == 3, fields[1] == source else { throw Refusal("not on source desktop") }
      guard let inventory = NPReadInventory() as? [[String: Any]],
            let row = inventory.first(where: { $0["Display Identifier"] as? String == uuid }),
            let active = row["Current Space"] as? [String: Any],
            (active["id64"] as? NSNumber)?.stringValue == source,
            let records = row["Spaces"] as? [[String: Any]] else {
        throw Refusal("cannot independently bind Space UUIDs to the observed order")
      }
      let proven = try provisionRecords(fields[2], source: source, live: records)
      spaceUUIDs = proven.identities
      fullscreenIDs = proven.fullscreen
      primaryScope = main.first
      sideOrder = proven.order
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
      guard primaryScope == before.primaryScope, geometry == before.geometry, fullscreenIDs == before.fullscreenIDs,
            before.spaceUUIDs.allSatisfy({ spaceUUIDs[$0.key] == $0.value })
      else { throw Refusal("unrelated display or geometry changed") }
      return try newlyAddedDesktop(before: before.sideOrder, after: sideOrder, source: source,
                                   currentDisplay: primaryScope == nil)
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

  // AXWindow describes a control's containing window. Only an explicit
  // AXLinkedUIElements relationship can identify the window represented by a tile.
  func linksOnlyToFixture(_ value: CFTypeRef?, fixture: AXUIElement) -> Bool {
    guard let links = value as? [AnyObject], links.count == 1,
          CFGetTypeID(links[0]) == AXUIElementGetTypeID() else { return false }
    return CFEqual(links[0], fixture)
  }

  struct FixtureDismissalTile {
    let pid: pid_t
    let birth: Date
    let container: AXUIElement
    let button: AXUIElement

    func matches(_ other: Self) -> Bool {
      pid == other.pid && birth == other.birth &&
        CFEqual(container, other.container) && CFEqual(button, other.button)
    }
  }

  func fixtureDismissalTile(on display: CGDirectDisplayID, fixture: AXUIElement,
                            number: UInt32, run: String) -> FixtureDismissalTile? {
    var fixturePID: pid_t = 0
    guard AXUIElementGetPid(fixture, &fixturePID) == .success, fixturePID == getpid(),
          attr(fixture, kAXRoleAttribute) as? String == kAXWindowRole,
          attr(fixture, kAXIdentifierAttribute) as? String == run,
          number > 0, NPReadAXWindowNumber(fixture) == number else { return nil }
    let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
    guard hosts.count == 1, let host = hosts.first,
          overviewHost(host.processIdentifier) == "com.apple.WindowManager",
          let birth = host.verifiedSystemBirth else { return nil }
    let pid = host.processIdentifier
    func owned(_ node: AXUIElement, role: String) -> Bool {
      var owner: pid_t = 0
      return AXUIElementGetPid(node, &owner) == .success && owner == pid &&
        attr(node, kAXRoleAttribute) as? String == role
    }
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, 0.2)
    guard let displays = try? children(root, named: "mc.display"),
          let container = try? only(displays.filter {
            (attr($0, "AXDisplayID") as? NSNumber)?.uint32Value == display
          }, "fixture display"), owned(container, role: kAXGroupRole), childOf(container, root),
          systemControlFrame(container) == CGDisplayBounds(display),
          let controls = attr(container, kAXChildrenAttribute) as? [AXUIElement],
          controls.count <= 64 else { return nil }
    let buttons = controls.filter { node in
      owned(node, role: kAXButtonRole) && childOf(node, container) &&
        linksOnlyToFixture(attr(node, kAXLinkedUIElementsAttribute), fixture: fixture)
    }
    guard buttons.count == 1, let button = buttons.first,
          attr(button, kAXEnabledAttribute) as? Bool == true,
          (try? actionsOf(button))?.contains(kAXPressAction) == true,
          host.verifiedSystemBirth == birth else { return nil }
    return FixtureDismissalTile(pid: pid, birth: birth, container: container, button: button)
  }

  // Diagnostic only. Enumerate the Dock's immediate system containers, then descend exclusively
  // through the confirmed secondary spaces bar. Never request names, labels, descriptions or pixels.
  func overviewSkeleton(_ display: UUID, currentDisplay: Bool = false) -> [String: Any] {
    var report: [String: Any] = ["display": display.uuidString, "systemInputs": 0]
    let state = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard AXIsProcessTrusted(), state?["kCGSSessionOnConsoleKey"] as? Bool == true,
          state?["CGSSessionScreenIsLocked"] as? Bool != true else { report["state"]="consoleUnavailable"; return report }
    guard let side = provisionDisplay(display, currentDisplay: currentDisplay)
    else { report["state"]="displayMismatch"; return report }
    guard let dock=try? SystemDock.identity() else {report["state"]="dockUnavailable";return report}
    let root=AXUIElementCreateApplication(dock.pid)
    guard dock.owns(root) else {report["state"]="dockAXOwnerChanged";return report}
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
        guard AXUIElementGetPid(el,&owner) == .success, owner == dock.pid else { continue }
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
      for scope in overviewRoots where !currentDisplay {
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
            guard AXUIElementGetPid(el,&owner) == .success, owner==dock.pid else {break}
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
    let display: UUID
    let identifiedAt: TimeInterval
    init(display: UUID, count: Int, currentDisplay: Bool) throws {
      identifiedAt = ProcessInfo.processInfo.systemUptime
      self.display = display
      guard let observed = try secondarySpacesBar(display, currentDisplay: currentDisplay), (try? observed.dock.verify()) != nil, (try? observed.owner.verify()) != nil
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
              pid==observed.owner.pid,
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
      let owner = bar.owner.pid
      guard (try? bar.owner.verify()) != nil, (try? bar.dock.verify()) != nil,
            overviewHost(owner) == bar.owner.identifier,
            (attr(bar.container,"AXDisplayID") as? NSNumber)?.uint32Value == bar.side,
            systemControlFrame(bar.container) == CGDisplayBounds(bar.side),
            let strip = systemControlFrame(bar.spaces), !strip.isEmpty, CGDisplayBounds(bar.side).contains(strip),
            childOf(bar.spaces,bar.container), childOf(bar.add,bar.spaces), childOf(list,bar.spaces),
            let listFrame = systemControlFrame(list), !listFrame.isEmpty, strip.contains(listFrame),
            let current = attr(list,kAXChildrenAttribute) as? [AXUIElement], current.count == tiles.count,
            attr(bar.add,kAXEnabledAttribute) as? Bool == true,
            tiles.indices.allSatisfy({ i in
              CFEqual(current[i], tiles[i]) && childOf(tiles[i],list) &&
                attr(tiles[i],kAXEnabledAttribute) as? Bool == true &&
                locations[i].recheck(tiles[i],owner:owner,in:listFrame)
            }) else { throw Refusal("secondary command or desktop tiles lost their physical proof") }
      switch bar.addProof {
      case .located(let location):
        guard location.recheck(bar.add,owner:owner,in:strip) else { throw Refusal("add lost its physical proof") }
      case .semantic(let p,let birth,let primary):
        guard let current = try secondarySpacesBar(display,currentDisplay:primary == nil),
              current.owner.pid == owner, current.owner.verifiedBirthDate == birth,
              current.dock == bar.dock, CFEqual(current.container,bar.container), CFEqual(current.spaces,bar.spaces),
              CFEqual(current.add,bar.add),
              strip.contains(p), hitsSpacesStrip(p,spaces:bar.spaces,container:bar.container,owner:owner)
        else { throw Refusal("semantic Add lost its strip, identity or generation") }
        if let primary {
          guard case .semantic(_,_,let fresh?) = current.addProof, primary.matches(fresh)
          else { throw Refusal("primary Add sibling changed before secondary dispatch") }
        }
        try requireVisibleWhenExposed(bar.add,in:bar.spaces)
        let elapsed = ProcessInfo.processInfo.systemUptime - identifiedAt
        let types: [CGEventType] = [.keyDown,.keyUp,.flagsChanged,.mouseMoved,.leftMouseDown,.rightMouseDown,
          .otherMouseDown,.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,
          .otherMouseDragged,.scrollWheel]
        guard elapsed >= 0, NSEvent.pressedMouseButtons == 0, types.allSatisfy({
          CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) >= elapsed
        }) else { throw Refusal("physical input intervened during semantic Add proof") }
      }
    }
  }

  // A tile retained while A is the only ordinary desktop remains eligible after
  // this trial's confirmed creation only if A stays current and first in [A,B].
  func admitsCurrentTileOrder(_ order: [String], source: String, created: String?) -> Bool {
    if let created { return created != source && order == [source, created] }
    return order == [source]
  }

  // On the witnessed 40 pt bar, WindowManager hit-tests the desktop tile 4 pt
  // below the list's reported frame. Only the retained tile can satisfy a hit.
  func currentTileHitPoints(list: CGRect, display: CGRect, count: Int) -> [CGPoint] {
    guard (1...2).contains(count), list.width >= 4, list.height >= 4, display.contains(list) else { return [] }
    let x = list.minX + list.width / (2 * CGFloat(count))
    return [list.midY, list.maxY + 4].map { CGPoint(x: x, y: $0) }.filter(display.contains)
  }


  struct CurrentDesktopDismissal {
    private let state: ProvisionState
    private let boot: String
    private let ownerBirth, dockBirth: Date
    private let bar: SecondarySpacesBar
    private let list, tile: AXUIElement
    private let point: CGPoint

    init(display: UUID, source: String, created: String? = nil) throws {
      state = try ProvisionState(display, source: source, currentDisplay: false)
      boot = try currentBoot()
      guard admitsCurrentTileOrder(state.sideOrder, source: source, created: created),
            let bar = try secondarySpacesBar(display), bar.primaryContainer,
            let ownerBirth = bar.owner.verifiedBirthDate, let dockBirth = bar.dock.verifiedBirthDate else {
        throw Refusal("current secondary desktop or overview generation unavailable")
      }
      self.bar = bar
      self.ownerBirth = ownerBirth
      self.dockBirth = dockBirth
      let list = try only(children(bar.spaces, named: "mc.spaces.list"), "secondary desktop list")
      var pid: pid_t = 0
      guard childOf(list, bar.spaces), AXUIElementGetPid(list, &pid) == .success,
            pid == bar.owner.pid, attr(list, kAXRoleAttribute) as? String == kAXListRole,
            let listFrame = systemControlFrame(list), let strip = systemControlFrame(bar.spaces),
            strip.contains(listFrame), let items = attr(list, kAXChildrenAttribute) as? [AXUIElement],
            items.count == state.sideOrder.count, let tile = items.first,
            !items.dropFirst().contains(where: { CFEqual($0, tile) }), !CFEqual(tile, bar.add),
            childOf(tile, list), AXUIElementGetPid(tile, &pid) == .success, pid == bar.owner.pid,
            attr(tile, kAXRoleAttribute) as? String == kAXButtonRole,
            attr(tile, kAXEnabledAttribute) as? Bool == true, try actionsOf(tile).contains(kAXPressAction as String)
      else { throw Refusal("current secondary desktop has no unique actionable tile") }
      self.list = list
      self.tile = tile
      let bounds = CGDisplayBounds(bar.side)
      let points: [CGPoint]
      if items.count == 2 {
        let pair = try ProvisionControls(display: display, count: 2, currentDisplay: false)
        guard pair.bar.owner.pid == pid, pair.bar.side == bar.side,
              CFEqual(list, pair.list), items.indices.allSatisfy({ CFEqual(items[$0], pair.tiles[$0]) })
        else { throw Refusal("secondary source tile or its ordered sibling changed") }
        points = pairedSourceProbes(list:listFrame, display:bounds, location:pair.locations[0],
                                    reportedFrame:systemControlFrame(tile), activation:activationPoint(tile))
      } else {
        points = currentTileHitPoints(list:listFrame, display:bounds, count:items.count)
      }
      guard case .hit(let point) = confirmedHit(points, until: ProcessInfo.processInfo.systemUptime + 0.5,
           matches: exactHit(tile, owner: pid), settle: { Thread.sleep(forTimeInterval: 0.045) }) else {
        throw Refusal("current desktop tile did not receive two exact hit tests")
      }
      self.point = point
    }

    func dismiss(display: UUID, source: String, created: String?, confirmGrant: () throws -> Void) throws {
      let current = try Self(display: display, source: source, created: created)
      guard state.sideOrder == [source], current.state.primaryScope == state.primaryScope,
            current.state.geometry == state.geometry, current.boot == boot,
            bar.owner.pid == current.bar.owner.pid, current.ownerBirth == ownerBirth,
            bar.dock.pid == current.bar.dock.pid, current.dockBirth == dockBirth,
            bar.side == current.bar.side, CFEqual(bar.container, current.bar.container),
            CFEqual(bar.spaces, current.bar.spaces), CFEqual(list, current.list), CFEqual(tile, current.tile),
            created != nil || point == current.point else {
        throw Refusal("current desktop tile or its display changed before overview dismissal")
      }
      try confirmGrant()
      guard exactHit(tile, owner: current.bar.owner.pid)(current.point),
            try ProvisionState(display, source:source, currentDisplay:false) == current.state
      else { throw Refusal("source desktop lost its final AX hit or membership") }
      let status = AXUIElementPerformAction(tile, kAXPressAction as CFString)
      emit(["event":"overviewDismissal", "route":"currentSecondaryDesktopTile", "source":source,
            "ordinaryOrder":current.state.sideOrder, "display":display.uuidString,
            "hit":[current.point.x,current.point.y], "axResult":status.rawValue])
    }
  }

  // This function is entered only by the timed secondary fixture while its own overview is visible.
  // The caller authenticates the user's current loan (including original focus) immediately before
  // each irreversible AX action. The occupancy callback runs live for the named target.
  func provisionSecondaryDesktop(
    _ action: String, directory: URL, display: UUID, source: String, currentDisplay: Bool = false,
    requireAuthorizedAction: () throws -> Void,
    requireSafeOccupancy: (_ target: String?) throws -> Void
  ) throws -> String {
    guard ["create", "remove"].contains(action) else {
      throw Refusal("unknown desktop preparation action")
    }
    let folder = try ReceiptFolder(directory)
    defer { close(folder.fd) }
    let state = { try ProvisionState(display, source: source, currentDisplay: currentDisplay) }
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
      guard original.sideOrder.last == source, currentDisplay || original.sideOrder == [source],
            let sourceIndex = original.sideOrder.firstIndex(of: source) else {
        throw Refusal("source must be the last ordinary desktop in the authorized original inventory")
      }
      let initialUI = try ProvisionControls(display: display, count: original.sideOrder.count, currentDisplay: currentDisplay)
      guard let birth = initialUI.bar.dock.verifiedBirthDate, let ownerBirth = initialUI.bar.owner.verifiedBirthDate else {
        throw Refusal("missing Dock generation")
      }
      try requireSafeOccupancy(nil)
      let intent = ProvisionIntent(
        operation: UUID(), display: display, source: source, initial: original,
        sourceTileLabel: initialUI.labels[sourceIndex], boot: boot,
        issuedUptime: ProcessInfo.processInfo.systemUptime, dockBirth: birth, ownerID:initialUI.bar.owner.identifier, ownerBirth:ownerBirth)
      let ui = try ProvisionControls(display: display, count: original.sideOrder.count, currentDisplay: currentDisplay)
      guard CFEqual(initialUI.bar.add, ui.bar.add), initialUI.labels == ui.labels,
        (try state()) == original
      else { throw Refusal("secondary add control changed") }
      emit(["event":"preparedAddMethod","method":ui.bar.addProof.method,"retainedButton":true])
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
      if let pair = try? ProvisionControls(display: display, count: after.sideOrder.count, currentDisplay: currentDisplay),
        let a = after.sideOrder.firstIndex(of: source),
        let b = after.sideOrder.firstIndex(of: target),
        pair.bar.dock.verifiedBirthDate == birth, CFEqual(ui.tiles[sourceIndex], pair.tiles[a]),
        !CFEqual(ui.tiles[sourceIndex], pair.tiles[b])
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
    let first = try ProvisionControls(display: display, count: original.sideOrder.count, currentDisplay: currentDisplay)
    guard first.bar.dock.matchesRecordedBirth(intent.dockBirth), first.bar.owner.matchesRecordedBirth(intent.ownerBirth),
          first.bar.owner.identifier==intent.ownerID else {
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
    let ui = try ProvisionControls(display: display, count: original.sideOrder.count, currentDisplay: currentDisplay)
    var actions: CFArray?
    let remove = "AXRemoveDesktop"
    guard ui.bar.dock.matchesRecordedBirth(intent.dockBirth), ui.bar.owner.matchesRecordedBirth(intent.ownerBirth),
          ui.bar.owner.identifier==intent.ownerID, ui.labels == first.labels,
      CFEqual(first.tiles[b], ui.tiles[b]), (try state()) == original,
      AXUIElementCopyActionNames(ui.tiles[b], &actions) == .success,
      (actions as? [String])?.contains(remove) == true
    else { throw Refusal("exact inactive B tile or Remove Desktop action unavailable") }
    try folder.put(created, "remove-intent.json")
    try requireSafeOccupancy(created.target)
    try ui.recheckBeforeInput()
    try need(try state() == original, "Space identity or display changed before deletion")
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
