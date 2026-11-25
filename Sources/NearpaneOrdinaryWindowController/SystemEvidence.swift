import AppKit
import ApplicationServices
import CReadOnlySpaces
import Darwin
import NearpaneCore

package typealias Refusal = WindowIdentityFailure
package func require(_ test: Bool, _ reason: String) throws { if !test { throw Refusal(reason) } }

func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}

package func number(_ e: AXUIElement) -> UInt32? {
    if let result = attribute(e, "AXWindowNumber") as? NSNumber,
       let n = UInt32(exactly: result.int64Value), n > 0 { return n }
    let n = NPReadAXWindowNumber(e)
    return n > 0 ? n : nil
}

package func checkOwner(_ owner: OrdinaryOwnerIdentity, pid: Int32, launch: UInt64, bundle: String) throws {
    try require(AXIsProcessTrusted(), "窗口助手没有现有辅助功能权限。")
    let console = CGSessionCopyCurrentDictionary() as? [String: Any]
    try require(console?[kCGSessionOnConsoleKey as String] as? Bool == true &&
                console?["CGSSessionScreenIsLocked"] as? Bool != true, "当前图形会话不可用。")
    try require(pid > 1 && pid != getpid() && pid != getppid(), "所选进程不在普通窗口管理范围。")
    try require(!bundle.hasPrefix("com.holdsnow.nearpane") && !bundle.hasPrefix("org.nearpane."),
                "Nearpane 自身窗口不能加入管理。")
    try owner.verify(pid, launch: launch, bundle: bundle)
}

package func windows(_ pid: Int32) throws -> [AXUIElement] {
    let application = AXUIElementCreateApplication(pid)
    try require(AXUIElementSetMessagingTimeout(application, 0.18) == .success, "无法限制辅助功能读取时限。")
    guard let result = AXWindowList.read(application, limit: 64).windows else { throw Refusal("无法核对完整窗口清单。") }
    for item in result {
        var owner: pid_t = 0
        try require(AXUIElementGetPid(item, &owner) == .success && owner == pid &&
                    AXUIElementSetMessagingTimeout(item, 0.18) == .success, "窗口对象进程不符。")
    }
    return result
}

func sizeValue(_ element: AXUIElement, _ key: String) -> CGSize? {
    guard let v = attribute(element, key), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &size), size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return nil }
    return size
}

func axRect(_ element: AXUIElement) throws -> SurfaceRect {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let size = sizeValue(element, kAXSizeAttribute) else { throw Refusal("缺少当前 AX 窗口几何。") }
    var point = CGPoint.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite
    else { throw Refusal("未知 AX 窗口位置。") }
    return .init(x: point.x, y: point.y, width: size.width, height: size.height)
}

func displayID(_ f: SurfaceRect) throws -> String {
    let rect = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    guard f.geometry.isValid, CGGetActiveDisplayList(32, &ids, &count) == .success, count > 0, count < 32 else {
        throw Refusal("无法完整核对活动显示器。")
    }
    let matches = ids.prefix(Int(count)).filter { !CGDisplayBounds($0).intersection(rect).isEmpty }
    guard matches.count == 1, let display = matches.first, CGDisplayBounds(display).contains(rect),
          CGDisplayIsInMirrorSet(display) == 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
        throw Refusal("窗口无法完整对应到唯一显示器。")
    }
    return CFUUIDCreateString(nil, uuid) as String
}

struct BoundaryDisplayWitness: Equatable {
    let id: String
    let bounds: SurfaceRect
}

func boundaryDisplayWitness(_ id: String) throws -> BoundaryDisplayWitness {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    try require(CGGetActiveDisplayList(32, &ids, &count) == .success && count < 32,
                "无法完整核对显示器范围。")
    let matches = ids.prefix(Int(count)).filter { display in
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return false }
        return CFUUIDCreateString(nil, uuid) as String == id
    }
    guard matches.count == 1, let display = matches.first, CGDisplayIsInMirrorSet(display) == 0 else {
        throw Refusal("原显示器身份无法唯一核对。")
    }
    let b = CGDisplayBounds(display)
    return .init(id: id, bounds: .init(x: b.minX, y: b.minY, width: b.width, height: b.height))
}

/// Partial overflow is observable only against the already enrolled, unchanged display.
/// This cannot authorize a first selection, a target write, a cross-display move or an offscreen window.
func boundaryGeometryPermitted(_ frame: SurfaceRect, enrolled: BoundaryDisplayWitness,
                               current: BoundaryDisplayWitness, intersecting: [String]) -> Bool {
    frame.geometry.isValid && enrolled == current && intersecting == [enrolled.id] &&
        frame.geometry.intersection(enrolled.bounds.geometry)?.isValid == true
}

func boundaryDisplayID(_ frame: SurfaceRect, witness: BoundaryDisplayWitness) throws -> String {
    let current = try boundaryDisplayWitness(witness.id)
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    try require(CGGetDisplaysWithRect(rect, 32, &ids, &count) == .success && count < 32,
                "无法核对越界窗口的显示器交集。")
    let intersecting: [String] = ids.prefix(Int(count)).compactMap { display in
        guard CGDisplayIsInMirrorSet(display) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    try require(intersecting.count == Int(count) &&
                boundaryGeometryPermitted(frame, enrolled: witness, current: current, intersecting: intersecting),
                "窗口已跨显示器、完全离屏或原显示器几何已变化。")
    return witness.id
}

func ordinaryRole(_ element: AXUIElement) throws {
    guard attribute(element,kAXRoleAttribute) as? String == kAXWindowRole,
          attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          attribute(element,kAXModalAttribute) as? Bool == false,
          attribute(element,kAXMinimizedAttribute) as? Bool == false,
          attribute(element,"AXFullScreen") as? Bool == false else {
        throw Refusal("窗口不是可核对的非模态、非全屏普通窗口。")
    }
    if let sheets = attribute(element,"AXSheets") as? [AXUIElement] {
        try require(sheets.isEmpty, "窗口存在附属对话框。")
    } else {
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(element,kAXChildrenAttribute as CFString,0,65,&raw) == .success,
              let children = raw as? [AXUIElement], children.count <= 64,
              children.allSatisfy({ c in
                  guard let role = attribute(c,kAXRoleAttribute) as? String else { return false }
                  return role != kAXSheetRole
              }) else { throw Refusal("无法排除附属对话框。") }
    }
    for key in [kAXSizeAttribute, kAXPositionAttribute] {
        var result = DarwinBoolean(false)
        try require(AXUIElementIsAttributeSettable(element,key as CFString,&result) == .success &&
                    result.boolValue, "窗口不支持精确调整位置及尺寸。")
    }
}

func observation(_ owner: OrdinaryOwnerIdentity, _ id: ManagedWindowID, _ bundle: String, _ e: AXUIElement,
                 boundaryDisplay: BoundaryDisplayWitness? = nil) throws -> AdmissionSample {
    try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
    let candidates = try windows(id.pid).filter { number($0) == id.number }
    try require(candidates.count == 1 && CFEqual(candidates[0], e) && number(e) == id.number, "所选 AX 窗口已重建或编号不唯一。")
    try ordinaryRole(e)
    guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.number) as? [[String: Any]],
          rows.count == 1, let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id.number,
          row[kCGWindowOwnerPID as String] as? Int32 == id.pid,
          row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
          let bounds = row[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: bounds)
    else { throw Refusal("WindowServer 无法确认所选普通窗口仍在屏。") }
    var sample = AdmissionSample(pid:id.pid, launch:id.launch, number:id.number, bundle:bundle, uptime:ProcessInfo.processInfo.systemUptime)
    let cg = SurfaceRect(x:r.minX,y:r.minY,width:r.width,height:r.height)
    sample.axFrame = try axRect(e)
    try require(sample.axFrame == cg, "AX 与 CG 的呈现几何不一致。")
    sample.cgFrame = cg
    sample.display = try boundaryDisplay.map { try boundaryDisplayID(cg, witness: $0) } ?? displayID(cg)
    sample.axNumber = id.number; sample.element = id.element
    sample.selectionContinuity = true; sample.permission = true
    sample.role = .ordinary; sample.fullscreen = false; sample.minimized = false
    sample.layer = 0; sample.onScreen = true; sample.positionSettable = true; sample.sizeSettable = true
    sample.stageManager = StageManagerPreference.read()
    if let size = sizeValue(e,"AXMinSize") { sample.minimum = .init(width:size.width,height:size.height) }
    return sample
}

package struct FrontFocus {
    package let pid: pid_t
    package let element: AXUIElement?
    private let image: OrdinaryProcessImage
    package init() throws {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw Refusal("前台身份未知。") }
        let before = try OrdinaryProcessImage.read(front)
        let app = AXUIElementCreateApplication(front)
        var value: CFTypeRef?
        try require(AXUIElementSetMessagingTimeout(app,0.2) == .success, "焦点读取时限不可用。")
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement
            var owner: pid_t = 0
            try require(AXUIElementGetPid(window, &owner) == .success && owner == front, "前台焦点窗口的应用身份不符。")
            element = window
        }
        else if error == .noValue {
            var names: CFArray?
            guard AXUIElementCopyAttributeNames(app,&names) == .success,
                  (names as? [String])?.contains(kAXFocusedWindowAttribute) == true else { throw Refusal("前台窗口焦点未知。") }
            element = nil
        } else { throw Refusal("当前前台窗口焦点不可核对。") }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == front &&
                    (try OrdinaryProcessImage.read(front)) == before, "读取焦点时前台进程已变化。")
        pid = front; image = before
    }
    package func check() throws {
        let now = try Self()
        try require(image == now.image && ((element == nil && now.element == nil) ||
                    (element != nil && now.element != nil && CFEqual(element!, now.element!))), "前台应用或窗口焦点已变化。")
    }

    /// The global AXFocusedApplication attribute can fail on a live console even
    /// when this application's exact focused window is readable. A PID alone is
    /// insufficient: bracket its AX observation with process and focus continuity.
    package static func verifiedPID() throws -> pid_t {
        let first = try Self()
        try first.check()
        return first.pid
    }
}
