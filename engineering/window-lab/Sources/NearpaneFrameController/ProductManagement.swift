import AppKit
import ApplicationServices
import Darwin
import NearpaneCore
import WindowLab

struct PresentationReceipt: Encodable {
    let session: UUID, revision: Int, beganUptime: Double
    let stageManagerEnabled: Bool?
    var confirmed = [Observation]()
    var unconfirmed = [Observation]()
    var refusal: String?
}

/// Observe only the named enrollment. A failed member may be deferred during crash
/// recovery; a layout transaction requires all its members. Neither sample can write.
@MainActor func productPresentation(_ directory: URL) throws -> PresentationReceipt {
    let adapter = try FixtureAdapter(directory, observationOnly: true)
    let request = adapter.ticket
    try require(adapter.run.productManagement == true && !request.members.isEmpty
                && request.members.count == request.frames.count, "窗口观测清单无效")
    try adapter.requireAccess()
    let began = ProcessInfo.processInfo.systemUptime
    let stageBefore = StageManagerPreference.read()
    let first = request.members.map { member in Result { try adapter.presentationSample(member) } }
    Thread.sleep(forTimeInterval: 0.08)
    var result = PresentationReceipt(session: request.session, revision: request.revision, beganUptime: began, stageManagerEnabled: stageBefore)
    for (index, member) in request.members.enumerated() {
        do {
            let before = try first[index].get()
            let after = try adapter.presentationSample(member)
            guard after.confirmsPresentation(after: before, member: member, ownerFrame: request.frames[index],
                                             usable: adapter.run.screens.usable) else {
                result.unconfirmed.append(after)
                throw Refusal(after.ax != after.cg ? "应用与屏幕报告的窗口位置或大小不一致，暂不可管理" :
                                "窗口呈现不稳定、不可见或超出管理范围，暂不可管理")
            }
            result.confirmed.append(after)
        } catch { result.refusal = result.refusal ?? String(describing: error) }
    }
    try adapter.freshness()
    try require(stageBefore == StageManagerPreference.read(), "台前调度设置发生变化，暂不可管理")
    try require(ProcessInfo.processInfo.systemUptime - began <= 3, "窗口呈现观测已过期")
    return result
}

struct ManagementGrant: Codable {
    let session: UUID, display: String, writer: ProcessBirth
    let mode: String
}

@MainActor func validateManagementGrant(_ dir: URL, session: UUID, display: String) throws {
    let grant: ManagementGrant = try readJSON(dir, "grant.json")
    let writer = try ProcessBirth.read(getppid())
    let host = try ProcessBirth.read(writer.parent)
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let expected = app.appendingPathComponent("Contents/MacOS/NearpaneHost").path
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    try require(proc_pidpath(host.pid, &path, UInt32(path.count)) > 0
        && String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) == expected
        && grant.writer == writer && grant.session == session && grant.display == display
        && ["active", "restoring"].contains(grant.mode), "管理授权、Host 或写入租约已失效")
}

/// Only accept an explicitly confirmed split whose vertical extent and outer edges are still witnessed.
@MainActor func observedPair(_ observations: [Observation], state: WorkspaceState, area: SurfaceRect) throws -> (Double, Bool) {
    try require(observations.count == 2, "需要两个当前窗口")
    let sorted = observations.sorted { $0.cg.x < $1.cg.x }
    let left = sorted[0].cg, right = sorted[1].cg
    let area = Experiment.lattice(area)
    try require(sorted.allSatisfy { $0.onScreen && $0.cg == $0.ax && $0.cg.y == area.y && $0.cg.height == area.height }
        && left.x == area.x && right.x + right.width == area.x + area.width, "手调布局需要保留双窗的外边缘")
    let edge: Double
    if left.x + left.width == right.x { edge = right.x }
    else {
        let changed = sorted.filter { o in state.windows.contains { $0.member == o.member && $0.confirmed != o.cg } }
        try require(changed.count == 1, "存在多个不同布局，无法确认分割位置")
        edge = changed[0].member == sorted[0].member ? left.x + left.width : right.x
    }
    let ratio = (edge - area.x) / area.width
    try require((0.2...0.8).contains(ratio), "分割比例超出安全范围")
    return (ratio, sorted[0].member != observations[0].member)
}

@MainActor struct ManagementFocus {
    let pid: pid_t
    let window: AXUIElement?
    init() throws {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw Refusal("前台焦点未知") }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        self.pid = pid
        if result == .noValue && value == nil {
            // A desktop with no focused window is observable. Unsupported, timeout and denied remain refusals.
            var names: CFArray?
            try require(AXUIElementCopyAttributeNames(app, &names) == .success
                && (names as? [String])?.contains(kAXFocusedWindowAttribute) == true, "焦点属性不可核对")
            window = nil
        } else {
            guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw Refusal("无法核对前台窗口焦点 (AX \(result.rawValue))")
            }
            window = (value as! AXUIElement)
        }
    }
    func verify() throws {
        let now = try Self()
        try require(pid == now.pid, "前台应用已变化")
        switch (window, now.window) {
        case (nil, nil): break
        case let (before?, after?): try require(CFEqual(before, after), "前台窗口焦点已变化")
        default: throw Refusal("前台窗口焦点出现或消失")
        }
    }
}
