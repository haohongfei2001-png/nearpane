import AppKit
import ApplicationServices
import Darwin
import NearpaneCore
import WindowLab

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
